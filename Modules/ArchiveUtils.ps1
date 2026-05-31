# ArchiveUtils.ps1 — Archive format detection, multi-volume validation, output directory management

function Find-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($path in $Candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

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
        "[._\s-]part\d+\.rar$",
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

    foreach ($ext in $EncryptionCapableExtensions.Keys) {
        if ($name -like "*$ext" -or $name -like "*$ext.001" -or $name -like "*.part*.rar") {
            return $true
        }
    }

    return $false
}

function Test-IsCompoundTarArchive {
    # A "compound tar" is a tarball wrapped in a single outer compression layer
    # (foo.tar.zst, foo.tar.gz, foo.tgz, ...). 7-Zip and WinRAR peel these in two
    # steps: extracting the archive only removes the outer layer, leaving an
    # intermediate .tar behind that must be extracted again to reach the real
    # contents. Callers use this to drive that automatic second step.
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    return (
        $n -imatch "\.tar\.(zst|gz|bz2|xz|lzma|lz4|br)$" -or
        $n -imatch "\.(tgz|tbz2|txz|tzst)$"
    )
}

function Get-ExpectedTarResidueName {
    # The file name 7-Zip/WinRAR leave behind after peeling the outer compression
    # layer of a compound tar archive: foo.tar.zst / foo.tgz -> foo.tar. Targeting
    # this deterministic name lets the residue step pick *our* tarball even when
    # the output folder is shared and holds unrelated .tar files. Returns $null for
    # anything that is not a compound tar.
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    if ($n -imatch "^(?<base>.+\.tar)\.(zst|gz|bz2|xz|lzma|lz4|br)$") {
        return $Matches["base"]
    }
    if ($n -imatch "^(?<base>.+)\.(tgz|tbz2|txz|tzst)$") {
        return "$($Matches['base']).tar"
    }

    return $null
}

function Test-DirectoryHasExecutable {
    # True when the directory tree contains at least one executable payload file
    # (see $ExecutablePayloadExtensions). Used by the nested pass to decide that a
    # layer has yielded its final output and recursion should stop.
    param([string]$Dir)

    if ([string]::IsNullOrWhiteSpace($Dir) -or !(Test-Path -LiteralPath $Dir)) {
        return $false
    }

    $exeExts = if ($null -ne $ExecutablePayloadExtensions) { $ExecutablePayloadExtensions } else { @('.exe') }

    try {
        foreach ($file in (Get-ChildItem -LiteralPath $Dir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            if ($exeExts -contains $file.Extension.ToLowerInvariant()) {
                return $true
            }
        }
    } catch {
        Write-Log "Could not scan $Dir for executables: $($_.Exception.Message)" "WARN"
    }

    return $false
}

function Test-IsFirstVolumeOrNormalArchive {
    param([string]$Path)

    $n = [IO.Path]::GetFileName($Path)

    # Multi-part "partNN.rar" sets. The separator before "part" may be a dot
    # (WinRAR default), underscore, hyphen, or space (renamed/foreign sets).
    # Requiring a real separator means a literal name like "mypart1.rar" is
    # still treated as a normal standalone archive.
    if ($n -imatch "[._\s-]part\d+\.rar$") {
        return ($n -imatch "[._\s-]part0*1\.rar$")
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
        $globPattern = "{0}.[0-9][0-9][0-9]" -f $baseName
        $present = @{}
        try {
            Get-ChildItem -LiteralPath $dir -Filter $globPattern -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($_.Name -imatch '\.(\d{3})$') {
                        $present[[int]$Matches[1]] = $true
                    }
                }
        } catch {}

        if (-not $present.ContainsKey(2)) {
            return @{ Complete = $true; Missing = @() }
        }

        $maxVol = ($present.Keys | Measure-Object -Maximum).Maximum
        $missing = @()
        for ($vol = 2; $vol -le $maxVol; $vol++) {
            if (-not $present.ContainsKey($vol)) {
                $missing += ("{0}.{1:D3}" -f $baseName, $vol)
            }
        }
        return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
    }

    if ($name -imatch "([._\s-])part0*1\.rar$") {
        $sep = $Matches[1]
        $pattern = $name -ireplace "[._\s-]part0*1\.rar$", ""
        $globPattern = "{0}{1}part*.rar" -f $pattern, $sep
        $present = @{}
        try {
            Get-ChildItem -LiteralPath $dir -Filter $globPattern -File -ErrorAction SilentlyContinue |
                ForEach-Object {
                    if ($_.Name -imatch '[._\s-]part0*(\d+)\.rar$') {
                        $present[[int]$Matches[1]] = $true
                    }
                }
        } catch {}

        if (-not $present.ContainsKey(2)) {
            return @{ Complete = $true; Missing = @() }
        }

        $maxVol = ($present.Keys | Measure-Object -Maximum).Maximum
        $missing = @()
        for ($vol = 2; $vol -le $maxVol; $vol++) {
            if (-not $present.ContainsKey($vol)) {
                $missing += ("{0}{1}part{2:D2}.rar" -f $pattern, $sep, $vol)
            }
        }
        return @{ Complete = ($missing.Count -eq 0); Missing = $missing }
    }

    return @{ Complete = $true; Missing = @() }
}

function Resolve-OutputDir {
    param(
        [string]$BaseDir,
        [bool]$IsSharedOutput,
        [string]$BehaviorOverride = ""
    )

    if ($IsSharedOutput) {
        New-Item -ItemType Directory -Force -Path $BaseDir | Out-Null
        return $BaseDir
    }

    # Callers (e.g. nested extraction) may force a specific behavior to avoid
    # the destructive "replace" default clobbering sibling directories.
    $behavior = if ([string]::IsNullOrWhiteSpace($BehaviorOverride)) { $ExistingOutputBehavior } else { $BehaviorOverride }

    switch ($behavior.ToLowerInvariant()) {
        "replace" {
            if (Test-Path -LiteralPath $BaseDir) {
                Write-Log "Replacing existing output folder: $BaseDir" "WARN"
                Remove-Item -LiteralPath $BaseDir -Recurse -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $BaseDir) {
                    Write-Log "Existing output folder could not be fully cleared; stale files may remain: $BaseDir" "WARN"
                }
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

function Find-ArchivesFromInputs {
    param(
        [string[]]$Paths,
        [int]$Limit = 0
    )

    $archives = New-Object System.Collections.Generic.List[string]
    $skipped = New-Object System.Collections.Generic.List[string]
    $limitHit = $false

    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }

        if ($Limit -gt 0 -and $archives.Count -ge $Limit) {
            $limitHit = $true
            break
        }

        $cleanPath = $path.Trim('"')

        if (!(Test-Path -LiteralPath $cleanPath)) {
            [void]$skipped.Add($cleanPath)
            Write-Log "Missing path skipped: $cleanPath" "WARN"
            continue
        }

        $item = Get-Item -LiteralPath $cleanPath -Force

        if ($item.PSIsContainer) {
            Write-Both "" "INFO"
            Write-Both "Folder selected:" "INFO"
            Write-Both $item.FullName "INFO"

            $recursive = Read-YesNo "Scan this folder recursively for archives?" $false

            $stack = New-Object System.Collections.Generic.Stack[string]
            $stack.Push($item.FullName)

            :enumLoop while ($stack.Count -gt 0) {
                if ($Limit -gt 0 -and $archives.Count -ge $Limit) {
                    $limitHit = $true
                    break
                }

                $dir = $stack.Pop()

                $childFiles = $null
                try { $childFiles = [IO.Directory]::EnumerateFiles($dir) } catch {
                    Write-Log "Cannot enumerate files in $dir : $($_.Exception.Message)" "WARN"
                }

                if ($childFiles) {
                    foreach ($filePath in $childFiles) {
                        if ((Test-IsSupportedArchiveName $filePath) -and (Test-IsFirstVolumeOrNormalArchive $filePath)) {
                            [void]$archives.Add($filePath)
                            Write-Log "Archive detected: $filePath"
                            if ($Limit -gt 0 -and $archives.Count -ge $Limit) {
                                $limitHit = $true
                                break enumLoop
                            }
                        } elseif (Test-IsSupportedArchiveName $filePath) {
                            [void]$skipped.Add($filePath)
                            Write-Log "Non-entry split skipped: $filePath" "WARN"
                        }
                    }
                }

                if ($recursive) {
                    try {
                        foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
                            $stack.Push($sub)
                        }
                    } catch {
                        Write-Log "Cannot enumerate subdirectories in $dir : $($_.Exception.Message)" "WARN"
                    }
                }
            }

            continue
        }

        if ((Test-IsSupportedArchiveName $item.FullName) -and (Test-IsFirstVolumeOrNormalArchive $item.FullName)) {
            [void]$archives.Add($item.FullName)
            Write-Log "Archive detected: $($item.FullName)"
        } else {
            [void]$skipped.Add($item.FullName)
            Write-Log "Skipped input: $($item.FullName)" "WARN"
        }
    }

    if ($limitHit) {
        Write-Log "Archive scan limit ($Limit) reached; enumeration stopped early." "WARN"
        Write-Both "Note: scan limit of $Limit archives reached; additional files were not enumerated." "WARN" "Yellow"
    }

    $archiveArray = $archives.ToArray()
    $skippedArray = $skipped.ToArray()

    $promoted = Find-OrphanedSplitEntries -Archives $archiveArray -Skipped $skippedArray
    if ($promoted.Count -gt 0) {
        foreach ($entry in $promoted) {
            [void]$archives.Add($entry)
            $skippedArray = @($skippedArray | Where-Object { $_ -ne $entry })
            Write-Log "Promoted orphaned split entry: $entry"
        }
    }

    return @{
        Archives = @($archives.ToArray() | Sort-Object -Unique)
        Skipped = @($skippedArray | Sort-Object -Unique)
    }
}

function Find-NestedArchives {
    param([string]$Root)

    $archives = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrWhiteSpace($Root) -or !(Test-Path -LiteralPath $Root)) {
        return @()
    }

    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Root)

    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()

        $childFiles = $null
        try { $childFiles = [IO.Directory]::EnumerateFiles($dir) } catch {
            Write-Log "Cannot enumerate nested files in $dir : $($_.Exception.Message)" "WARN"
        }

        if ($childFiles) {
            foreach ($filePath in $childFiles) {
                if ((Test-IsSupportedArchiveName $filePath) -and (Test-IsFirstVolumeOrNormalArchive $filePath)) {
                    [void]$archives.Add($filePath)
                }
            }
        }

        try {
            foreach ($sub in [IO.Directory]::EnumerateDirectories($dir)) {
                $stack.Push($sub)
            }
        } catch {
            Write-Log "Cannot enumerate nested subdirectories in $dir : $($_.Exception.Message)" "WARN"
        }
    }

    return @($archives.ToArray() | Sort-Object -Unique)
}

function Find-OrphanedSplitEntries {
    param(
        [string[]]$Archives,
        [string[]]$Skipped
    )

    $promoted = @()
    $rarHave = @{}
    foreach ($a in $Archives) {
        if ($a -imatch '\.rar$' -or $a -imatch '[._\s-]part0*1\.rar$') {
            $rarHave[(Split-Path $a -Parent).ToLowerInvariant()] = $true
        }
    }

    $rGroups = @{}
    $zGroups = @{}
    $partGroups = @{}
    foreach ($s in $Skipped) {
        $name = [IO.Path]::GetFileName($s)
        $dir = Split-Path $s -Parent
        $dirKey = $dir.ToLowerInvariant()

        if ($name -imatch '^(.+)([._\s-])part0*(\d+)\.rar$') {
            if ($rarHave.ContainsKey($dirKey)) { continue }
            $base = $Matches[1]
            $sep = $Matches[2]
            $num = [int]$Matches[3]
            $key = (Join-Path $dir ($base + $sep)).ToLowerInvariant()
            if (-not $partGroups.ContainsKey($key)) { $partGroups[$key] = @() }
            $partGroups[$key] += [PSCustomObject]@{ Path = $s; Num = $num }
        } elseif ($name -imatch '^(.+)\.r(\d{2,})$') {
            if ($rarHave.ContainsKey($dirKey)) { continue }
            $base = $Matches[1]
            $num = [int]$Matches[2]
            $key = (Join-Path $dir $base).ToLowerInvariant()
            if (-not $rGroups.ContainsKey($key)) { $rGroups[$key] = @() }
            $rGroups[$key] += [PSCustomObject]@{ Path = $s; Num = $num }
        } elseif ($name -imatch '^(.+)\.z(\d+)$') {
            $base = $Matches[1]
            $num = [int]$Matches[2]
            $key = (Join-Path $dir $base).ToLowerInvariant()
            if (-not $zGroups.ContainsKey($key)) { $zGroups[$key] = @() }
            $zGroups[$key] += [PSCustomObject]@{ Path = $s; Num = $num }
        }
    }

    foreach ($key in $partGroups.Keys) {
        $entry = $partGroups[$key] | Sort-Object Num | Select-Object -First 1
        if ($entry) { $promoted += $entry.Path }
    }
    foreach ($key in $rGroups.Keys) {
        $entry = $rGroups[$key] | Sort-Object Num | Select-Object -First 1
        if ($entry) { $promoted += $entry.Path }
    }
    foreach ($key in $zGroups.Keys) {
        $entry = $zGroups[$key] | Sort-Object Num | Select-Object -First 1
        if ($entry) { $promoted += $entry.Path }
    }

    return $promoted
}

function Get-ArchiveVolumeSet {
    # Given the entry file of an archive, return every on-disk file that belongs
    # to the same (possibly multi-volume) set, including the entry itself. This is
    # the inverse of the volume-detection logic and is used to delete/move a whole
    # set together rather than just the first volume.
    param([string]$EntryArchive)

    $result = New-Object System.Collections.Generic.List[string]
    [void]$result.Add($EntryArchive)

    try {
        $name = [IO.Path]::GetFileName($EntryArchive)
        $dir = Split-Path $EntryArchive -Parent
        if ([string]::IsNullOrEmpty($dir)) { $dir = "." }

        $glob = $null
        $regex = $null

        if ($name -imatch '([._\s-])part0*\d+\.rar$') {
            $sep = $Matches[1]
            $base = $name -ireplace '[._\s-]part0*\d+\.rar$', ''
            $glob = "{0}{1}part*.rar" -f $base, $sep
            $regex = '[._\s-]part0*\d+\.rar$'
        } elseif ($name -imatch '\.\d{3}$') {
            # numeric volumes, incl. .zip.001 / .7z.001 / .rar.001
            $base = $name -ireplace '\.\d{3}$', ''
            $glob = "{0}.*" -f $base
            $regex = '\.\d{3}$'
        } elseif ($name -imatch '\.rar$') {
            # old-style .rNN set: name.rar + name.r00, name.r01, ...
            $base = $name -ireplace '\.rar$', ''
            $glob = "{0}.r*" -f $base
            $regex = '\.r\d{2,}$'
        } elseif ($name -imatch '\.zip$') {
            # old-style .zNN set: name.zip + name.z01, name.z02, ...
            $base = $name -ireplace '\.zip$', ''
            $glob = "{0}.z*" -f $base
            $regex = '\.z\d+$'
        }

        # NOTE: -Filter supports only * and ? (not [0-9] ranges) on every
        # platform, so the glob is intentionally broad and the regex below does
        # the precise volume matching.
        if ($glob) {
            Get-ChildItem -LiteralPath $dir -Filter $glob -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -imatch $regex } |
                ForEach-Object { [void]$result.Add($_.FullName) }
        }
    } catch {
        Write-Log "Could not enumerate volume set for $EntryArchive : $($_.Exception.Message)" "WARN"
    }

    return @($result.ToArray() | Sort-Object -Unique)
}

function Remove-ArchiveSet {
    # Delete every file of an archive's volume set. Returns the number removed.
    param([string]$EntryArchive)

    $removed = 0
    foreach ($file in (Get-ArchiveVolumeSet -EntryArchive $EntryArchive)) {
        try {
            if (Test-Path -LiteralPath $file) {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                Write-Log "Deleted source archive file: $file"
                $removed++
            }
        } catch {
            Write-Log "Could not delete $file : $($_.Exception.Message)" "WARN"
        }
    }
    return $removed
}

function Move-ArchiveSet {
    # Move every file of an archive's volume set into <parent>\$DestSubfolder.
    # Returns the number of files moved.
    param(
        [string]$EntryArchive,
        [string]$DestSubfolder
    )

    $moved = 0
    foreach ($file in (Get-ArchiveVolumeSet -EntryArchive $EntryArchive)) {
        try {
            if (-not (Test-Path -LiteralPath $file)) { continue }

            $parent = Split-Path $file -Parent
            # Idempotency: skip files already inside the target subfolder.
            if ((Split-Path $parent -Leaf) -ieq $DestSubfolder) { continue }

            $destDir = Join-Path $parent $DestSubfolder
            New-Item -ItemType Directory -Force -Path $destDir | Out-Null
            $destPath = Join-Path $destDir (Split-Path $file -Leaf)
            if (Test-Path -LiteralPath $destPath) {
                Remove-Item -LiteralPath $destPath -Force -ErrorAction SilentlyContinue
            }
            Move-Item -LiteralPath $file -Destination $destPath -Force -ErrorAction Stop
            Write-Log "Moved $file -> $destPath"
            $moved++
        } catch {
            Write-Log "Could not move $file : $($_.Exception.Message)" "WARN"
        }
    }
    return $moved
}

function Test-ArchiveIsEncrypted {
    param(
        [string]$Archive,
        [string]$SevenZipPath
    )

    if (-not $SevenZipPath) { return $null }

    try {
        $result = Invoke-ProcessLogged -Exe $SevenZipPath -ArgumentList @("l", "-slt", $Archive) -Operation "ENCRYPTION CHECK" -ShowOutput $false -TimeoutSeconds 30 -CondenseOutput $true
        if ($result.ExitCode -ne 0 -and $result.ExitCode -ne 2) { return $null }

        $hasEncrypted = $false
        $hasUnencrypted = $false

        foreach ($line in $result.Output) {
            $text = [string]$line
            if ($text -match '^Encrypted\s*=\s*\+') { $hasEncrypted = $true }
            if ($text -match '^Encrypted\s*=\s*-') { $hasUnencrypted = $true }
        }

        if ($hasEncrypted) { return $true }
        if ($hasUnencrypted -and -not $hasEncrypted) { return $false }
        return $null
    } catch {
        Write-Log "Encryption check failed: $($_.Exception.Message)" "WARN"
        return $null
    }
}

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
