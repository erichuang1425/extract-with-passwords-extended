# Passwords.ps1 — Password loading, caching, and deduplication

function Get-CachedPasswords {
    if (-not $UsePasswordCache) { return @() }
    if (!(Test-Path -LiteralPath $CacheFile)) { return @() }

    $list = @()
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
                    $list += $line
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
    }

    return @($list)
}

function Save-PasswordToCache {
    param([string]$Password)

    if (-not $UsePasswordCache) { return }

    try {
        if (!(Test-Path -LiteralPath $CacheFile)) {
            New-Item -ItemType File -Force -Path $CacheFile | Out-Null
        }

        $existing = Get-Content -LiteralPath $CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue

        foreach ($line in $existing) {
            if ($line -and -not $line.StartsWith("#")) {
                $parts = $line.Split("|", 2)
                $pw = if ($parts.Count -eq 2) { $parts[1] } else { $line }
                if ($pw -eq $Password) { return }
            }
        }

        $entry = "{0}|{1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Password
        Add-Content -LiteralPath $CacheFile -Value $entry -Encoding UTF8
        Write-Log "Password saved to cache."
    } catch {
        Write-Log "Could not save password to cache: $($_.Exception.Message)" "WARN"
    }
}

function Get-Passwords {
    $list = @()

    $cached = @(Get-CachedPasswords)
    if ($cached.Count -gt 0) {
        Write-Log "Cached passwords loaded: $($cached.Count)"
        $list += $cached
    }

    if ($TryNoPasswordFirst) {
        $list += ""
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
        $raw = Get-Content -LiteralPath $file -Encoding UTF8 -ErrorAction SilentlyContinue
        $fileCount = 0

        foreach ($line in $raw) {
            $pw = $line.Trim()

            if ($pw -and -not $pw.StartsWith("#")) {
                $list += $pw
                $fileCount++
            }
        }

        Write-Log "Loaded $fileCount password(s) from $file"
    }

    $seen = @{}
    $clean = @()

    foreach ($pw in $list) {
        if (-not $seen.ContainsKey($pw)) {
            $seen[$pw] = $true
            $clean += $pw
        }
    }

    Write-Log "Total unique passwords including no-password and cache slots: $($clean.Count)"

    return @($clean)
}
