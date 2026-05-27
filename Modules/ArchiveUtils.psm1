# ArchiveUtils.psm1
# Archive detection, format handling, and file utilities.

$script:EncryptionCapableExtensions = @{
    '.zip' = $true; '.zipx' = $true; '.7z' = $true; '.rar' = $true
}

# ============================================================
# Filename and display helpers
# ============================================================

function Sanitize-FileName {
    param([string]$Name)

    foreach ($c in [IO.Path]::GetInvalidFileNameChars()) {
        $Name = $Name.Replace($c, "_")
    }

    $Name = $Name.Trim().TrimEnd(".")

    $reserved = @("CON","PRN","AUX","NUL",
                   "COM1","COM2","COM3","COM4","COM5","COM6","COM7","COM8","COM9",
                   "LPT1","LPT2","LPT3","LPT4","LPT5","LPT6","LPT7","LPT8","LPT9")
    if ($reserved -contains $Name.ToUpperInvariant()) {
        $Name = "_$Name"
    }

    if ($Name.Length -gt 240) {
        $Name = $Name.Substring(0, 240)
    }

    if ([string]::IsNullOrWhiteSpace($Name)) {
        $Name = "Extracted"
    }

    return $Name
}

function Format-MaskedPassword {
    param([string]$Password)
    if ($Password.Length -le 4) { return ("*" * $Password.Length) }
    return ($Password.Substring(0, 2) + ("*" * ($Password.Length - 2)))
}

# ============================================================
# Archive name and extension helpers
# ============================================================

function Get-ArchiveBaseName {
    param([string]$Path)

    $name = [IO.Path]::GetFileName($Path)

    $patterns = @(
        "\.tar\.zst$",
        "\.tar\.gz$",
        "\.tar\.bz2$",
        "\.tar\.xz$",
        "\.tar\.lzma$",
        "\.tar\.lz4$",
        "\.tar\.br$",
        "\.tgz$",
        "\.tbz2$",
        "\.txz$",
        "\.tzst$",
        "\.zip\.001$",
        "\.7z\.001$",
        "\.rar\.001$",
        "\.part0*1\.rar$",
        "\.001$",
        "\.zipx$",
        "\.zip$",
        "\.rar$",
        "\.7z$",
        "\.tar$",
        "\.gz$",
        "\.bz2$",
        "\.xz$",
        "\.zst$",
        "\.cab$",
        "\.iso$",
        "\.wim$",
        "\.img$",
        "\.dmg$"
    )

    foreach ($pattern in $patterns) {
        if ($name -imatch $pattern) {
            return Sanitize-FileName ($name -ireplace $pattern, "")
        }
    }

    return Sanitize-FileName ([IO.Path]::GetFileNameWithoutExtension($name))
}

function Test-IsSupportedArchiveName {
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    return (
        $n -imatch "\.zip$" -or
        $n -imatch "\.zipx$" -or
        $n -imatch "\.rar$" -or
        $n -imatch "\.7z$" -or
        $n -imatch "\.tar$" -or
        $n -imatch "\.tar\.gz$" -or
        $n -imatch "\.tgz$" -or
        $n -imatch "\.tar\.bz2$" -or
        $n -imatch "\.tbz2$" -or
        $n -imatch "\.tar\.xz$" -or
        $n -imatch "\.txz$" -or
        $n -imatch "\.tar\.zst$" -or
        $n -imatch "\.tzst$" -or
        $n -imatch "\.gz$" -or
        $n -imatch "\.bz2$" -or
        $n -imatch "\.xz$" -or
        $n -imatch "\.zst$" -or
        $n -imatch "\.cab$" -or
        $n -imatch "\.iso$" -or
        $n -imatch "\.wim$" -or
        $n -imatch "\.img$" -or
        $n -imatch "\.dmg$" -or
        $n -imatch "\.7z\.001$" -or
        $n -imatch "\.zip\.001$" -or
        $n -imatch "\.rar\.001$" -or
        $n -imatch "\.part\d+\.rar$" -or
        $n -imatch "\.z\d+$" -or
        $n -imatch "\.r\d{2,}$"
    )
}

function Test-IsRarLike {
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    return (
        $n -imatch "\.rar$" -or
        $n -imatch "\.part0*1\.rar$" -or
        $n -imatch "\.rar\.001$"
    )
}

function Test-IsEncryptionCapable {
    param([string]$Path)

    $name = [IO.Path]::GetFileName($Path)

    foreach ($ext in $script:EncryptionCapableExtensions.Keys) {
        if ($name -like "*$ext" -or $name -like "*$ext.001" -or $name -like "*.part*.rar") {
            return $true
        }
    }

    return $false
}

function Test-IsFirstVolumeOrNormalArchive {
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    if ($n -imatch "\.part\d+\.rar$") {
        return ($n -imatch "\.part0*1\.rar$")
    }

    if ($n -imatch "\.r\d{2,}$") {
        return $false
    }

    if ($n -imatch "\.z\d+$") {
        return $false
    }

    if ($n -imatch "\.\d{3}$") {
        return ($n -imatch "\.001$")
    }

    return $true
}

# ============================================================
# File and volume validation
# ============================================================

function Test-FileAccessible {
    param([string]$FilePath)

    try {
        $stream = [IO.File]::Open($FilePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        $stream.Close()
        return $true
    } catch {
        return $false
    }
}

function Test-MultiVolumeComplete {
    param([string]$Archive)

    $name = [IO.Path]::GetFileName($Archive)
    $dir = Split-Path $Archive -Parent

    if ($name -imatch "\.001$") {
        $baseName = $name -ireplace "\.001$", ""
        $missing = @()
        for ($vol = 2; $vol -le 999; $vol++) {
            $volName = "{0}.{1:D3}" -f $baseName, $vol
            $volPath = Join-Path $dir $volName
            if (!(Test-Path -LiteralPath $volPath)) {
                if ($vol -eq 2 -and !(Test-Path -LiteralPath $volPath)) {
                    break
                }
                $missing += $volName
                break
            }
        }
        return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
    }

    if ($name -imatch "\.part0*1\.rar$") {
        $pattern = $name -ireplace "\.part0*1\.rar$", ""
        $missing = @()
        for ($vol = 2; $vol -le 999; $vol++) {
            $volName = "{0}.part{1:D2}.rar" -f $pattern, $vol
            $volPath = Join-Path $dir $volName
            if (!(Test-Path -LiteralPath $volPath)) {
                if ($vol -eq 2 -and !(Test-Path -LiteralPath $volPath)) {
                    break
                }
                $missing += $volName
                break
            }
        }
        return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
    }

    return @{ Complete = $true; Missing = @() }
}

# ============================================================
# Output directory management
# ============================================================

function Resolve-OutputDir {
    param(
        [string]$BaseDir,
        [bool]$IsSharedOutput
    )

    if ($IsSharedOutput) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        return $BaseDir
    }

    switch ($ExistingOutputBehavior.ToLowerInvariant()) {
        "replace" {
            if (Test-Path -LiteralPath $BaseDir) {
                Write-Log "Replacing existing output folder: $BaseDir" "WARN"
                Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
            return $BaseDir
        }

        "merge" {
            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
            return $BaseDir
        }

        "new" {
            if (!(Test-Path -LiteralPath $BaseDir)) {
                New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
                return $BaseDir
            }

            for ($i = 2; $i -lt 9999; $i++) {
                $candidate = "$BaseDir`_$i"

                if (!(Test-Path -LiteralPath $candidate)) {
                    New-Item -ItemType Directory -Force -Path $candidate | Out-Null
                    return $candidate
                }
            }

            throw "Could not create a unique output folder."
        }

        default {
            if (Test-Path -LiteralPath $BaseDir) {
                Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction SilentlyContinue
            }

            New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
            return $BaseDir
        }
    }
}

# ============================================================
# Archive discovery
# ============================================================

function Find-ArchivesFromInputs {
    param([string[]]$Paths)

    $archives = @()
    $skipped = @()

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        $cleanPath = $path.Trim('"')

        if (!(Test-Path -LiteralPath $cleanPath)) {
            $skipped += $cleanPath
            Write-Log "Missing path skipped: $cleanPath" "WARN"
            continue
        }

        $item = Get-Item -LiteralPath $cleanPath -Force

        if ($item.PSIsContainer) {
            Write-Both "" "INFO"
            Write-Both "Folder selected:" "INFO"
            Write-Both $item.FullName "INFO"

            $recursive = Read-YesNo "Scan this folder recursively for archives?" $false

            if ($recursive) {
                $files = Get-ChildItem -LiteralPath $item.FullName -File -Recurse -ErrorAction SilentlyContinue
            } else {
                $files = Get-ChildItem -LiteralPath $item.FullName -File -ErrorAction SilentlyContinue
            }

            foreach ($file in $files) {
                if ((Test-IsSupportedArchiveName $file.FullName) -and (Test-IsFirstVolumeOrNormalArchive $file.FullName)) {
                    $archives += $file.FullName
                    Write-Log "Archive detected: $($file.FullName)"
                } elseif (Test-IsSupportedArchiveName $file.FullName) {
                    $skipped += $file.FullName
                    Write-Log "Non-entry split skipped: $($file.FullName)" "WARN"
                }
            }

            continue
        }

        if ((Test-IsSupportedArchiveName $item.FullName) -and (Test-IsFirstVolumeOrNormalArchive $item.FullName)) {
            $archives += $item.FullName
            Write-Log "Archive detected: $($item.FullName)"
        } else {
            $skipped += $item.FullName
            Write-Log "Skipped input: $($item.FullName)" "WARN"
        }
    }

    return @{
        Archives = @($archives | Sort-Object -Unique)
        Skipped = @($skipped | Sort-Object -Unique)
    }
}

# ============================================================
# Directory item counting and cleanup
# ============================================================

function Get-DirectoryItemCount {
    param([string]$Dir)

    try {
        if (!(Test-Path -LiteralPath $Dir)) {
            return 0
        }

        return @(Get-ChildItem -LiteralPath $Dir -Force -Recurse -ErrorAction SilentlyContinue).Count
    } catch {
        return 0
    }
}

function Clear-AttemptOutput {
    param([string]$OutputDir)

    try {
        if (Test-Path -LiteralPath $OutputDir) {
            Get-ChildItem -LiteralPath $OutputDir -Force -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }

        New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    } catch {
        Write-Log "Failed to clear output folder $OutputDir : $($_.Exception.Message)" "WARN"
    }
}

function Remove-EmptyOutputDir {
    param(
        [string]$OutputDir,
        [bool]$SeparateFolders
    )

    try {
        if ($SeparateFolders -and (Test-Path -LiteralPath $OutputDir)) {
            if ((Get-DirectoryItemCount -Dir $OutputDir) -eq 0) {
                Remove-Item -LiteralPath $OutputDir -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "Failed to remove empty output folder $OutputDir : $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
# Encryption detection
# ============================================================

function Test-ArchiveIsEncrypted {
    param(
        [string]$Archive,
        [string]$SevenZipPath
    )

    if (-not $SevenZipPath) { return $null }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $SevenZipPath
        $psi.Arguments = "l -slt `"$Archive`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch {}

        $exited = $p.WaitForExit(30000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            return $null
        }

        $p.WaitForExit()
        $output = $stdoutTask.Result

        if ($output -match "Encrypted = \+") {
            return $true
        }

        if ($output -match "Encrypted = -") {
            return $false
        }

        return $null
    } catch {
        return $null
    }
}

# ============================================================
# Error classification
# ============================================================

function Get-ExtractionErrorType {
    param(
        [string]$Output,
        [int]$ExitCode
    )

    # Wrong password detection
    if ($ExitCode -eq 2 -and ($Output -match "Wrong password" -or $Output -match "Incorrect password")) {
        return "WrongPassword"
    }

    # Corrupt archive detection
    if ($Output -match "Unexpected end of archive" -or
        $Output -match "Headers Error" -or
        $Output -match "Is not archive" -or
        ($Output -match "CRC" -and $Output -notmatch "password")) {
        return "CorruptArchive"
    }

    # Missing volume detection
    if ($Output -match "Cannot find volume" -or $Output -match "next volume is required") {
        return "MissingVolume"
    }

    # Timeout detection
    if ($ExitCode -eq -998) {
        return "Timeout"
    }

    # Permission denied detection
    if ($Output -match "Access is denied" -or $Output -match "locked") {
        return "PermissionDenied"
    }

    return "Unknown"
}

# ============================================================
# Formatting helpers
# ============================================================

function Format-FileSize {
    param([long]$Bytes)

    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return "{0:N1} KB" -f ($Bytes / 1KB) }
    return "$Bytes B"
}

function Format-Elapsed {
    param([System.Diagnostics.Stopwatch]$Stopwatch)

    $ts = $Stopwatch.Elapsed
    if ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f [math]::Floor($ts.TotalMinutes), $ts.Seconds
    }
    return "{0:N1}s" -f $ts.TotalSeconds
}

function Format-ElapsedFromMs {
    param([long]$Ms)
    $sec = [math]::Floor($Ms / 1000)
    if ($sec -ge 60) {
        return "{0}m {1}s" -f [math]::Floor($sec / 60), ($sec % 60)
    }
    return "${sec}s"
}

# ============================================================
# Export public API
# ============================================================

Export-ModuleMember -Function `
    Sanitize-FileName,
    Format-MaskedPassword,
    Get-ArchiveBaseName,
    Test-IsSupportedArchiveName,
    Test-IsRarLike,
    Test-IsEncryptionCapable,
    Test-IsFirstVolumeOrNormalArchive,
    Test-FileAccessible,
    Test-MultiVolumeComplete,
    Resolve-OutputDir,
    Find-ArchivesFromInputs,
    Get-DirectoryItemCount,
    Clear-AttemptOutput,
    Remove-EmptyOutputDir,
    Test-ArchiveIsEncrypted,
    Format-FileSize,
    Format-Elapsed,
    Format-ElapsedFromMs,
    Get-ExtractionErrorType
