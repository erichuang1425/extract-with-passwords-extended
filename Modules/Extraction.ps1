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
    # Prefer the console executables (UnRAR.exe, then Rar.exe) over the GUI
    # WinRAR.exe. WinRAR.exe is a windowed app: running it pops up dialogs, so it
    # is only used as a last resort (and then in background mode — see below).
    $found = Find-FirstExistingPath @(
        "$env:ProgramFiles\WinRAR\UnRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\UnRAR.exe",
        "$env:LOCALAPPDATA\Programs\WinRAR\UnRAR.exe",
        "$env:ProgramFiles\WinRAR\Rar.exe",
        "${env:ProgramFiles(x86)}\WinRAR\Rar.exe",
        "$env:LOCALAPPDATA\Programs\WinRAR\Rar.exe",
        "$env:ProgramFiles\WinRAR\WinRAR.exe",
        "${env:ProgramFiles(x86)}\WinRAR\WinRAR.exe",
        "$env:LOCALAPPDATA\Programs\WinRAR\WinRAR.exe"
    )
    if ($found) { return $found }

    $cmd = Get-Command "UnRAR.exe" -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $cmd2 = Get-Command "Rar.exe" -ErrorAction SilentlyContinue
    if ($cmd2) { return $cmd2.Source }

    $cmd3 = Get-Command "WinRAR.exe" -ErrorAction SilentlyContinue
    if ($cmd3) { return $cmd3.Source }

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

    if ($leaf -eq "rar.exe") {
        return "Rar"
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

    # WinRAR.exe is a GUI application; launching it with no arguments opens its
    # file-manager window (showing the current/source folder). Never probe it
    # that way — trust its presence instead. Console engines (UnRAR/Rar/7z) are
    # safe to smoke-test with empty args.
    if ([IO.Path]::GetFileName($EnginePath).ToLowerInvariant() -eq "winrar.exe") {
        return (Test-Path -LiteralPath $EnginePath)
    }

    $p = $null
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
    } finally {
        # Release the process handle and the redirected stdin/stdout/stderr pipes
        # rather than waiting on the finalizer (see Invoke-ProcessLogged).
        if ($p) {
            try { $p.Dispose() } catch {}
        }
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
        [int]$Timeout = 0,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    $argumentList = @("t", "-y", "-bd")
    if ($OmitPasswordIfEmpty) {
        $argumentList += @(New-7zPasswordArgs -Password $Password -OmitIfEmpty)
    } else {
        $argumentList += @(New-7zPasswordArgs -Password $Password)
    }
    $argumentList += $Archive

    $result = Invoke-ProcessLogged -Exe $SevenZip -ArgumentList $argumentList -Operation "7Z TEST" -ShowOutput $false -TimeoutSeconds $Timeout -CondenseOutput $true -CancelToken $CancelToken
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
        [int]$Timeout = 0,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
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

    $result = Invoke-ProcessLogged -Exe $SevenZip -ArgumentList $argumentList -Operation "7Z EXTRACT" -ShowOutput $false -TimeoutSeconds $Timeout -CancelToken $CancelToken
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
        [int]$Timeout = 0,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    $argumentList = @("t", "-idq", "-y")
    if ([IO.Path]::GetFileName($RarExe).ToLowerInvariant() -eq "winrar.exe") {
        $argumentList += "-ibck"   # run the GUI WinRAR minimized in the background
    }
    $argumentList += @(New-RarPasswordArgs -Password $Password)
    $argumentList += $Archive

    $result = Invoke-ProcessLogged -Exe $RarExe -ArgumentList $argumentList -Operation "WINRAR/UNRAR TEST" -ShowOutput $false -TimeoutSeconds $Timeout -CondenseOutput $true -CancelToken $CancelToken
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
        [int]$Timeout = 0,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    $before = Get-DirectoryItemCount -Dir $OutputDir

    $dest = $OutputDir.TrimEnd('\') + '\'

    $argumentList = @("x", "-y", "-idq", $WinRarOverwriteMode)
    if ([IO.Path]::GetFileName($RarExe).ToLowerInvariant() -eq "winrar.exe") {
        $argumentList += "-ibck"   # run the GUI WinRAR minimized in the background
    }
    $argumentList += @(New-RarPasswordArgs -Password $Password)
    $argumentList += $Archive
    $argumentList += $dest

    $result = Invoke-ProcessLogged -Exe $RarExe -ArgumentList $argumentList -Operation "WINRAR/UNRAR EXTRACT" -ShowOutput $false -TimeoutSeconds $Timeout -CancelToken $CancelToken
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

function Expand-CompoundTarResidue {
    # 7-Zip and WinRAR only peel the outer compression layer of a compound tar
    # archive (foo.tar.zst -> foo.tar), leaving the intermediate tarball in the
    # output folder. Extract that tarball *in place* so its contents land directly
    # in $OutputDir (rather than a redundant foo\foo subfolder), then delete it.
    #
    # Returns $true when the archive is fully extracted: the residue tarball was
    # expanded, or there was nothing recognizable to expand (the engine already
    # produced the final contents). Returns $false only when a residue tarball was
    # located but could not be extracted, so the caller can report the compound
    # archive as not-fully-extracted instead of a false success.
    param(
        [string]$EngineName,
        [string]$EnginePath,
        [string]$OutputDir,
        [string]$SourceArchive,
        [int]$Timeout = 0,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    if (-not (Test-Path -LiteralPath $OutputDir)) { return $true }

    # Prefer the deterministic name the engine derives from the source archive
    # (foo.tar.zst -> foo.tar): this targets *our* tarball even when $OutputDir is
    # shared and already holds unrelated .tar files. Fall back to a lone top-level
    # .tar only when that exact name is absent (engine naming variance).
    $tar = $null
    $expected = Get-ExpectedTarResidueName $SourceArchive
    if ($expected) {
        $candidate = Join-Path $OutputDir $expected
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $tar = $candidate }
    }

    if (-not $tar) {
        # -Filter "*.tar" can over-match via 8.3 short names (e.g. data.tarball),
        # so narrow to an exact extension match and only act on an unambiguous
        # single tarball.
        $tarFiles = @(Get-ChildItem -LiteralPath $OutputDir -Filter "*.tar" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ieq ".tar" })
        if ($tarFiles.Count -eq 1) {
            $tar = $tarFiles[0].FullName
        } elseif ($tarFiles.Count -gt 1) {
            Write-Log "Multiple .tar files in $OutputDir and none match the expected residue name; not auto-expanding." "WARN"
        }
    }

    # Nothing recognizable to expand: treat the outer extraction as complete.
    if (-not $tar) { return $true }

    Write-Log "Compound-tar residue detected; extracting in place: $tar"

    $ok = $false
    if ($EngineName -eq "7-Zip" -or $EngineName -eq "PeaZip bundled 7z") {
        $ok = Extract-With7z -SevenZip $EnginePath -Archive $tar -Password "" -OutputDir $OutputDir -OmitPasswordIfEmpty $true -Timeout $Timeout -CancelToken $CancelToken
    } elseif ($EngineName -eq "WinRAR") {
        # The console UnRAR/Rar binaries cannot read a plain .tar; only the
        # universal WinRAR.exe can. (A real .tar.zst would never have been opened
        # by UnRAR/Rar in the first place, so they never reach this path.)
        $ok = Extract-WithWinRar -RarExe $EnginePath -Archive $tar -Password "" -OutputDir $OutputDir -Timeout $Timeout -CancelToken $CancelToken
    } else {
        Write-Log "Engine $EngineName cannot extract the intermediate tarball; leaving $tar in place." "WARN"
        return $false
    }

    if (-not $ok) {
        Write-Log "Failed to extract intermediate tarball $tar; leaving it in place." "WARN"
        return $false
    }

    try {
        Remove-Item -LiteralPath $tar -Force -ErrorAction Stop
        Write-Log "Removed intermediate tarball after extraction: $tar"
    } catch {
        Write-Log "Could not remove intermediate tarball $tar : $($_.Exception.Message)" "WARN"
    }

    return $true
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
        [bool]$TestOnly = $false,
        [System.Threading.CancellationToken]$CancelToken = [System.Threading.CancellationToken]::None
    )

    Write-Log "Trying engine $EngineName on archive $Archive"

    $testOk = $false
    $extractOk = $false

    if ($EngineName -eq "7-Zip" -or $EngineName -eq "PeaZip bundled 7z") {
        $testOk = Test-With7z -SevenZip $EnginePath -Archive $Archive -Password $Password -OmitPasswordIfEmpty $OmitPasswordArg -Timeout $Timeout -CancelToken $CancelToken

        # If the test was cancelled (Skip Current/Cancel), don't launch a fallback
        # extraction with an already-canceled token: that would start a second
        # engine process after the user asked to stop, delaying the skip and
        # possibly leaving partial files where failed-attempt cleanup is disabled.
        if (-not $TestOnly -and -not $CancelToken.IsCancellationRequested) {
            if ($testOk -or $TryExtractEvenIfTestFails) {
                if (-not $testOk) {
                    Write-Log "$EngineName test failed; trying extraction fallback anyway." "WARN"
                }

                $extractOk = Extract-With7z -SevenZip $EnginePath -Archive $Archive -Password $Password -OutputDir $OutputDir -OmitPasswordIfEmpty $OmitPasswordArg -Timeout $Timeout -CancelToken $CancelToken
            }
        }
    } elseif ($EngineName -in @("WinRAR", "UnRAR", "Rar")) {
        $testOk = Test-WithWinRar -RarExe $EnginePath -Archive $Archive -Password $Password -Timeout $Timeout -CancelToken $CancelToken

        if (-not $TestOnly -and -not $CancelToken.IsCancellationRequested) {
            if ($testOk -or $TryExtractEvenIfTestFails) {
                if (-not $testOk) {
                    Write-Log "$EngineName test failed; trying extraction fallback anyway." "WARN"
                }

                $extractOk = Extract-WithWinRar -RarExe $EnginePath -Archive $Archive -Password $Password -OutputDir $OutputDir -Timeout $Timeout -CancelToken $CancelToken
            }
        }
    }

    if ($TestOnly) {
        return $testOk
    }

    if ($extractOk) {
        # Compound tar formats (foo.tar.zst, foo.tgz, ...) come out in two layers:
        # the engine peels the outer compression to an intermediate .tar, which we
        # now extract in place so the user gets the real contents (and no redundant
        # foo\foo nesting) regardless of the nested-extraction setting. If that
        # intermediate tarball is located but cannot be expanded, the archive is
        # only partially extracted: report failure so callers don't treat the
        # source as fully done (and delete/sort it), while leaving the recovered
        # outer layer in place rather than clearing it.
        if ((Test-IsCompoundTarArchive $Archive) -and
            -not (Expand-CompoundTarResidue -EngineName $EngineName -EnginePath $EnginePath -OutputDir $OutputDir -SourceArchive $Archive -Timeout $Timeout -CancelToken $CancelToken)) {
            if ($CancelToken.IsCancellationRequested) {
                # Skip/Cancel interrupted the intermediate-tarball expansion. Treat
                # this like any other cancelled attempt: fall through to the normal
                # failed-attempt cleanup so the outer .tar and partial files are
                # cleared, instead of leaving a half-extracted result behind.
                Write-Log "Compound-tar extraction cancelled before the intermediate tarball was expanded: $Archive" "WARN"
                $extractOk = $false
            } else {
                # Genuine partial extraction: report not-fully-extracted but keep
                # the recovered outer layer in place rather than clearing it.
                Write-Log "Compound-tar archive only partially extracted (intermediate tarball not expanded): $Archive" "WARN"
                return $false
            }
        } else {
            return $true
        }
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
        } elseif (-not ($UseSevenZip -and $SevenZip) -and -not ($UsePeaZipBundled7zFallback -and $PeaZip7z)) {
            # Non-RAR archive whose resolved RAR engine is console-only
            # (UnRAR/Rar) and no universal 7-Zip/PeaZip engine is available.
            # Preferring the console binary must not lose WinRAR's ability to
            # handle ZIP/7z/etc., so fall back to a sibling WinRAR.exe (which
            # runs minimized via -ibck during extraction).
            $guiPath = Join-Path (Split-Path $WinRar -Parent) "WinRAR.exe"
            if ((Test-Path -LiteralPath $guiPath) -and -not $seen[$guiPath]) {
                $plan += @{ Name = "WinRAR"; Path = $guiPath }
                $seen[$guiPath] = $true
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

    if ($ExitCode -eq -997) {
        return [PSCustomObject]@{ Type = "Cancelled"; Confidence = "High" }
    }
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
