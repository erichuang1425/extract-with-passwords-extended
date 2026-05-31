# Passwords.ps1 — Password loading, caching, and deduplication

function Get-FileEncoding {
    param([string]$Path)

    try {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $bom = New-Object byte[] 4
            $read = $stream.Read($bom, 0, 4)

            if ($read -ge 3 -and $bom[0] -eq 0xEF -and $bom[1] -eq 0xBB -and $bom[2] -eq 0xBF) {
                return [Text.Encoding]::UTF8
            }
            if ($read -ge 4 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE -and $bom[2] -eq 0 -and $bom[3] -eq 0) {
                return [Text.Encoding]::UTF32
            }
            if ($read -ge 4 -and $bom[0] -eq 0 -and $bom[1] -eq 0 -and $bom[2] -eq 0xFE -and $bom[3] -eq 0xFF) {
                return New-Object System.Text.UTF32Encoding($true, $true)
            }
            if ($read -ge 2 -and $bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) {
                return [Text.Encoding]::Unicode
            }
            if ($read -ge 2 -and $bom[0] -eq 0xFE -and $bom[1] -eq 0xFF) {
                return [Text.Encoding]::BigEndianUnicode
            }
        } finally {
            $stream.Dispose()
        }
    } catch {}

    return [Text.Encoding]::UTF8
}

function Get-CacheMutexName {
    # Stable, per-cache-file mutex name. Reduce the path to a deterministic,
    # mutex-name-safe token (alphanumerics kept, everything else -> '_') without
    # a crypto-hash dependency. Distinct cache files get distinct names; the
    # worst case (two paths sharing the trailing token) is a shared lock, which
    # is merely conservative, never incorrect. "Local\" scopes it to the session.
    $key = if ($CacheFile) { ([string]$CacheFile).ToLowerInvariant() } else { "default" }
    $safe = $key -replace '[^a-z0-9]', '_'
    if ($safe.Length -gt 200) { $safe = $safe.Substring($safe.Length - 200) }
    return "Local\TryPwExtract_PwCache_$safe"
}

function Enter-CacheLock {
    # Acquire the named cache mutex (serializes cache read/modify/write across
    # runspaces in the same process). Never throws. If the mutex cannot be
    # created or acquired within the timeout, returns an unacquired lock so the
    # caller proceeds unguarded (graceful degradation) instead of blocking.
    $mutex = $null
    try {
        $mutex = New-Object System.Threading.Mutex($false, (Get-CacheMutexName))
    } catch {
        return [PSCustomObject]@{ Mutex = $null; Acquired = $false }
    }

    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(5000)
    } catch [System.Threading.AbandonedMutexException] {
        # A previous owner died holding the mutex; we now own it.
        $acquired = $true
    } catch {
        $acquired = $false
    }

    return [PSCustomObject]@{ Mutex = $mutex; Acquired = $acquired }
}

function Exit-CacheLock {
    param($Lock)

    if ($Lock -and $Lock.Mutex) {
        if ($Lock.Acquired) {
            try { $Lock.Mutex.ReleaseMutex() } catch {}
        }
        try { $Lock.Mutex.Dispose() } catch {}
    }
}

function Get-CachedPasswords {
    if (-not $UsePasswordCache) { return @() }
    if (!(Test-Path -LiteralPath $CacheFile)) { return @() }

    $list = @()
    $lock = Enter-CacheLock
    try {
        $raw = Get-Content -LiteralPath $CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
        $cutoff = (Get-Date).AddDays(-$PasswordCacheRetentionDays)
        $kept = @()

        foreach ($line in $raw) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith("#")) {
                $kept += $line
                continue
            }
            $parts = $line.Split("|", 2)
            if ($parts.Count -eq 2) {
                try {
                    $ts = [datetime]::ParseExact($parts[0].Trim(), "yyyy-MM-dd HH:mm:ss", $null)
                    if ($ts -ge $cutoff) {
                        $list += $parts[1]
                        $kept += $line
                    }
                } catch {
                    # Malformed timestamp: keep the line on disk, but only surface
                    # the password portion as a candidate (not the raw "ts|pw").
                    $list += $parts[1]
                    $kept += $line
                }
            } else {
                $list += $line
                $kept += $line
            }
        }

        if ($kept.Count -lt @($raw).Count) {
            $kept | Set-Content -LiteralPath $CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue
        }
    } catch {
        Write-Log "Could not read password cache: $($_.Exception.Message)" "WARN"
    } finally {
        Exit-CacheLock $lock
    }

    return @($list)
}

function Save-PasswordToCache {
    param([string]$Password)

    if (-not $UsePasswordCache) { return }

    $lock = Enter-CacheLock
    $saved = $false
    try {
        if (!(Test-Path -LiteralPath $CacheFile)) {
            New-Item -ItemType File -Force -Path $CacheFile | Out-Null
        }

        $existing = Get-Content -LiteralPath $CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue

        $alreadyPresent = $false
        foreach ($line in $existing) {
            if ($line -and -not $line.StartsWith("#")) {
                $parts = $line.Split("|", 2)
                $pw = if ($parts.Count -eq 2) { $parts[1] } else { $line }
                if ($pw -eq $Password) { $alreadyPresent = $true; break }
            }
        }

        if (-not $alreadyPresent) {
            $entry = "{0}|{1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Password
            Add-Content -LiteralPath $CacheFile -Value $entry -Encoding UTF8
            $saved = $true
        }
    } catch {
        Write-Log "Could not save password to cache: $($_.Exception.Message)" "WARN"
    } finally {
        Exit-CacheLock $lock
    }

    if ($saved) {
        Write-Log "Password saved to cache."
    }
}

function Get-PasswordTryOrder {
    # Order the candidate passwords so the one most likely to work is tried first.
    # Archives processed back-to-back — and successive layers of a multilayer
    # archive — frequently share a password, so the last password that succeeded
    # is promoted to the front. When layers use *different* passwords this still
    # works: the promoted guess simply fails and the remaining candidates are
    # tried in order. Pure and side-effect free so it is unit-testable.
    param(
        [string[]]$Passwords,
        [string]$PreferredFirst
    )

    $all = @($Passwords)

    # A successful password is never the empty (no-password) sentinel, so an
    # empty/absent preference means "no reordering".
    if ([string]::IsNullOrEmpty($PreferredFirst)) {
        return $all
    }

    $ordered = New-Object System.Collections.Generic.List[string]
    [void]$ordered.Add($PreferredFirst)
    foreach ($pw in $all) {
        if ($pw -ne $PreferredFirst) { [void]$ordered.Add($pw) }
    }

    return @($ordered.ToArray())
}

function Get-Passwords {
    $seen = @{}
    $clean = New-Object System.Collections.Generic.List[string]

    $cached = @(Get-CachedPasswords)
    if ($cached.Count -gt 0) {
        Write-Log "Cached passwords loaded: $($cached.Count)"
        foreach ($pw in $cached) {
            if (-not $seen.ContainsKey($pw)) {
                $seen[$pw] = $true
                [void]$clean.Add($pw)
            }
        }
    }

    if ($TryNoPasswordFirst -and -not $seen.ContainsKey("")) {
        $seen[""] = $true
        [void]$clean.Add("")
    }

    if (!(Test-Path -LiteralPath $PwFile)) {
        New-Item -ItemType File -Force -Path $PwFile | Out-Null
    }

    $filesToLoad = @($PwFile)

    if ($LoadAllPasswordFiles) {
        $extras = Get-ChildItem -LiteralPath $PwDir -Filter "*.txt" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $PwFile } |
            ForEach-Object { $_.FullName }
        if ($extras) {
            $filesToLoad += $extras
            Write-Log "Additional password files found: $($extras.Count)"
        }
    }

    foreach ($file in $filesToLoad) {
        $encoding = Get-FileEncoding -Path $file
        $fileCount = 0

        try {
            foreach ($line in [IO.File]::ReadLines($file, $encoding)) {
                $pw = $line.Trim()
                if ([string]::IsNullOrEmpty($pw)) { continue }
                if ($pw.StartsWith("#")) { continue }
                if ($seen.ContainsKey($pw)) { continue }

                $seen[$pw] = $true
                [void]$clean.Add($pw)
                $fileCount++
            }
        } catch {
            Write-Log "Failed to read password file $file : $($_.Exception.Message)" "WARN"
        }

        Write-Log "Loaded $fileCount unique password(s) from $file"
    }

    Write-Log "Total unique passwords including no-password and cache slots: $($clean.Count)"

    return @($clean)
}
