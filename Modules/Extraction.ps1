# Extraction.ps1 — Engine detection, password argument building, test and extract functions

# Holds the most recent engine process result (ExitCode + Output) so the caller
# can classify *why* an attempt failed (timeout / corrupt / wrong password / ...)
# via Get-LastEngineFailureType. Set per-runspace, so parallel workers don't
# clobber each other.
$script:LastEngineResult = $null

function Get-NormalSevenZipPath {
    $found = Find-FirstExistingPath @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe",
        "C:\ProgramData\chocolatey\bin\7z.exe"
    )
    if ($found) { return $found }

    $cmd = Get-Command "7z.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    return $null
}

function Get-PeaZipBundledSevenZipPath {
    return Find-FirstExistingPath @(
        "$env:ProgramFiles\PeaZip\res\bin\7z\7z.exe",
        "${env:ProgramFiles(x86)}\PeaZip\res\bin\7z\7z.exe",
        "$env:ProgramFiles\PeaZip\res\7z\7z.exe",
        "${env:ProgramFiles(x86)}\PeaZip\res\7z\7z.exe",
        "$env:LOCALAPPDATA\Programs\PeaZip\res\bin\7z\7z.exe",
        "$env:LOCALAPPDATA\Programs\PeaZip\res\7z\7z.exe"
    )
}

function Get-WinRarOrUnRarPath {
    $found = Find-FirstExistingPath @(
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe",
        "$env:LOCALAPPDATA\Programs\WinRAR\WinRAR.exe",
        "$env:ProgramFiles\WinRAR\UnRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\UnRAR.exe",
        "$env:LOCALAPPDATA\Programs\WinRAR\UnRAR.exe"
    )
    if ($found) { return $found }

    $cmd = Get-Command "WinRAR.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cmd2 = Get-Command "UnRAR.exe" -ErrorAction SilentlyContinue
    if ($cmd2) { return $cmd2.Source }

    return $null
}

function Get-EngineName {
    param([string]$Path)

    if (-not $Path) {
        return "None"
    }

    $leaf = [IO.Path]::GetFileName($Path).ToLowerInvariant()

    if ($leaf -eq "unrar.exe") {
        return "UnRAR"
    }

    if ($leaf -eq "winrar.exe") {
        return "WinRAR"
    }

    if ($leaf -eq "7z.exe") {
        if ($Path -match "PeaZip") {
            return "PeaZip bundled 7z"
        }

        return "7-Zip"
    }

    return $leaf
}

function Test-EngineWorks {
    param([string]$EnginePath)

    if (-not $EnginePath) { return $false }

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $EnginePath
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $psi.Arguments = ""

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi
        [void]$p.Start()

        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()
        try { $p.StandardInput.Close() } catch {}

        $exited = $p.WaitForExit(10000)
        if (-not $exited) {
            try { $p.Kill() } catch {}
            return $false
        }

        $p.WaitForExit()
        return ($p.ExitCode -ne -999)
    } catch {
        return $false
    }
}

function New-7zPasswordArgs {
    param(
        [string]$Password,
        [switch]$OmitIfEmpty
    )

    if ($Password -eq "") {
        if ($OmitIfEmpty) { return @() }
        return @("-p")
    }

    return @("-p$Password")
}

function Test-With7z {
    param(
        [string]$SevenZip,
        [string]$Archive,
        [string]$Password,
        [bool]$OmitPasswordIfEmpty = $false,
        [int]$Timeout = 0
    )

    $argumentList = @("t", "-y", "-bd")
    if ($OmitPasswordIfEmpty) {
        $argumentList += @(New-7zPasswordArgs -Password $Password -OmitIfEmpty)
    } else {
        $argumentList += @(New-7zPasswordArgs -Password $Password)
    }
    $argumentList += $Archive

    $result = Invoke-ProcessLogged -Exe $SevenZip -ArgumentList $argumentList -Operation "7Z TEST" -ShowOutput $false -TimeoutSeconds $Timeout -CondenseOutput $true
    $script:LastEngineResult = $result
    $code = [int]$result.ExitCode

    return ($code -eq 0)
}

function Extract-With7z {
    param(
        [string]$SevenZip,
        [string]$Archive,
        [string]$Password,
        [string]$OutputDir,
        [bool]$OmitPasswordIfEmpty = $false,
        [int]$Timeout = 0
    )

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $before = Get-DirectoryItemCount -Dir $OutputDir

    $argumentList = @("x", "-y", "-bd", "-mmt=on", "-$SevenZipOverwriteMode", "-o$OutputDir")
    if ($OmitPasswordIfEmpty) {
        $argumentList += @(New-7zPasswordArgs -Password $Password -OmitIfEmpty)
    } else {
        $argumentList += @(New-7zPasswordArgs -Password $Password)
    }
    $argumentList += $Archive

    $result = Invoke-ProcessLogged -Exe $SevenZip -ArgumentList $argumentList -Operation "7Z EXTRACT" -ShowOutput $false -TimeoutSeconds $Timeout
    $script:LastEngineResult = $result
    $code = [int]$result.ExitCode

    $after = Get-DirectoryItemCount -Dir $OutputDir

    Write-Log "Output item count before: $before"
    Write-Log "Output item count after: $after"

    if ($code -eq 0) {
        return $true
    }

    if ($code -eq 1 -and $after -gt $before) {
        Write-Log "7z warning exit code 1 accepted because new output appeared." "WARN"
        return $true
    }

    return $false
}

function New-RarPasswordArgs {
    param([string]$Password)

    if ($Password -eq "") {
        return @("-p-")
    }

    return @("-p$Password")
}

function Test-WithWinRar {
    param(
        [string]$RarExe,
        [string]$Archive,
        [string]$Password,
        [int]$Timeout = 0
    )

    $argumentList = @("t", "-idq", "-y")
    $argumentList += @(New-RarPasswordArgs -Password $Password)
    $argumentList += $Archive

    $result = Invoke-ProcessLogged -Exe $RarExe -ArgumentList $argumentList -Operation "WINRAR/UNRAR TEST" -ShowOutput $false -TimeoutSeconds $Timeout -CondenseOutput $true
    $script:LastEngineResult = $result
    $code = [int]$result.ExitCode

    return ($code -eq 0)
}

function Extract-WithWinRar {
    param(
        [string]$RarExe,
        [string]$Archive,
        [string]$Password,
        [string]$OutputDir,
        [int]$Timeout = 0
    )

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $before = Get-DirectoryItemCount -Dir $OutputDir

    $dest = $OutputDir.TrimEnd('\') + '\'

    $argumentList = @("x", "-y", "-idq", $WinRarOverwriteMode)
    $argumentList += @(New-RarPasswordArgs -Password $Password)
    $argumentList += $Archive
    $argumentList += $dest

    $result = Invoke-ProcessLogged -Exe $RarExe -ArgumentList $argumentList -Operation "WINRAR/UNRAR EXTRACT" -ShowOutput $false -TimeoutSeconds $Timeout
    $script:LastEngineResult = $result
    $code = [int]$result.ExitCode

    $after = Get-DirectoryItemCount -Dir $OutputDir

    Write-Log "Output item count before: $before"
    Write-Log "Output item count after: $after"

    if ($code -eq 0) {
        return $true
    }

    if ($code -eq 1 -and $after -gt $before) {
        Write-Log "WinRAR/UnRAR warning exit code 1 accepted because new output appeared." "WARN"
        return $true
    }

    return $false
}

function Try-EnginePassword {
    param(
        [string]$EngineName,
        [string]$EnginePath,
        [string]$Archive,
        [string]$Password,
        [string]$OutputDir,
        [bool]$CanClearFailedOutput = $true,
        [bool]$OmitPasswordArg = $false,
        [int]$Timeout = 0,
        [bool]$TestOnly = $false
    )

    Write-Log "Trying engine $EngineName on archive $Archive"

    $testOk = $false
    $extractOk = $false

    if ($EngineName -eq "7-Zip" -or $EngineName -eq "PeaZip bundled 7z") {
        $testOk = Test-With7z -SevenZip $EnginePath -Archive $Archive -Password $Password -OmitPasswordIfEmpty $OmitPasswordArg -Timeout $Timeout

        if (-not $TestOnly) {
            if ($testOk -or $TryExtractEvenIfTestFails) {
                if (-not $testOk) {
                    Write-Log "$EngineName test failed; trying extraction fallback anyway." "WARN"
                }

                $extractOk = Extract-With7z -SevenZip $EnginePath -Archive $Archive -Password $Password -OutputDir $OutputDir -OmitPasswordIfEmpty $OmitPasswordArg -Timeout $Timeout
            }
        }
    } elseif ($EngineName -eq "WinRAR" -or $EngineName -eq "UnRAR") {
        $testOk = Test-WithWinRar -RarExe $EnginePath -Archive $Archive -Password $Password -Timeout $Timeout

        if (-not $TestOnly) {
            if ($testOk -or $TryExtractEvenIfTestFails) {
                if (-not $testOk) {
                    Write-Log "$EngineName test failed; trying extraction fallback anyway." "WARN"
                }

                $extractOk = Extract-WithWinRar -RarExe $EnginePath -Archive $Archive -Password $Password -OutputDir $OutputDir -Timeout $Timeout
            }
        }
    }

    if ($TestOnly) {
        return $testOk
    }

    if ($extractOk) {
        return $true
    }

    if ($CleanFailedAttemptOutput -and $CanClearFailedOutput) {
        Clear-AttemptOutput -OutputDir $OutputDir
    } elseif ($CleanFailedAttemptOutput -and -not $CanClearFailedOutput) {
        Write-Log "Skipped failed-attempt cleanup because output folder is shared with earlier archive results." "WARN"
    }

    return $false
}

function Get-EnginePlanForArchive {
    param(
        [string]$Archive,
        [string]$SevenZip,
        [string]$PeaZip7z,
        [string]$WinRar
    )

    $plan = @()
    $seen = @{}
    $isRar = Test-IsRarLike $Archive
    $winRarName = Get-EngineName $WinRar
    $winRarIsUniversal = ($winRarName -eq "WinRAR")

    if ($UseSevenZip -and $SevenZip) {
        $plan += @{ Name = "7-Zip"; Path = $SevenZip }
        $seen[$SevenZip] = $true
    }

    if ($UseWinRarFallback -and $WinRar) {
        if ($isRar -or $winRarIsUniversal) {
            if (-not $seen[$WinRar]) {
                $plan += @{ Name = $winRarName; Path = $WinRar }
                $seen[$WinRar] = $true
            }
        }
    }

    if ($UsePeaZipBundled7zFallback -and $PeaZip7z) {
        if (-not $seen[$PeaZip7z]) {
            $plan += @{ Name = "PeaZip bundled 7z"; Path = $PeaZip7z }
            $seen[$PeaZip7z] = $true
        }
    }

    return @($plan)
}

function Get-ExtractionErrorType {
    param(
        [int]$ExitCode,
        [object[]]$Output,
        [bool]$ArchiveKnownEncrypted = $false
    )

    if ($ExitCode -eq -998) {
        return [PSCustomObject]@{ Type = "Timeout"; Confidence = "High" }
    }
    if ($ExitCode -eq 0) {
        return [PSCustomObject]@{ Type = "Success"; Confidence = "High" }
    }

    $text = ($Output | ForEach-Object { [string]$_ }) -join "`n"

    if ($ExitCode -eq -999) {
        if ($text -match "cannot find the file specified|The system cannot find the path|No such file") {
            return [PSCustomObject]@{ Type = "MissingEngine"; Confidence = "High" }
        }
        return [PSCustomObject]@{ Type = "ProcessError"; Confidence = "High" }
    }

    if ($text -match "Wrong password|Incorrect password|password is incorrect|Enter password") {
        return [PSCustomObject]@{ Type = "WrongPassword"; Confidence = "High" }
    }
    if ($text -match "Cannot find volume|next volume is required|Missing volume") {
        return [PSCustomObject]@{ Type = "MissingVolume"; Confidence = "High" }
    }
    if ($text -match "Access is denied|locked by another process") {
        return [PSCustomObject]@{ Type = "PermissionDenied"; Confidence = "High" }
    }
    if ($text -match "Unexpected end of archive|Headers Error|Unexpected end of data|is not supported archive") {
        return [PSCustomObject]@{ Type = "CorruptArchive"; Confidence = "High" }
    }

    if ($text -match "CRC Failed|Data Error|Checksum error") {
        if ($ArchiveKnownEncrypted) {
            return [PSCustomObject]@{ Type = "WrongPassword"; Confidence = "Low" }
        }
        return [PSCustomObject]@{ Type = "CorruptArchive"; Confidence = "Low" }
    }

    return [PSCustomObject]@{ Type = "Unknown"; Confidence = "Low" }
}

function Get-LastEngineFailureType {
    param([bool]$ArchiveKnownEncrypted = $false)

    if ($null -eq $script:LastEngineResult) {
        return $null
    }

    $cls = Get-ExtractionErrorType `
        -ExitCode ([int]$script:LastEngineResult.ExitCode) `
        -Output @($script:LastEngineResult.Output) `
        -ArchiveKnownEncrypted $ArchiveKnownEncrypted

    return $cls.Type
}
