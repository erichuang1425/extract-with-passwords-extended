param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$InputPaths
)

$ErrorActionPreference = "Continue"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host "PowerShell 3.0 or later is required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$_docs = [Environment]::GetFolderPath("MyDocuments")
if ([string]::IsNullOrEmpty($_docs)) { $_docs = Join-Path $env:USERPROFILE "Documents" }
$PwDir = Join-Path $_docs "ArchivePwExtract"
$PwFile = Join-Path $PwDir "passwords.txt"
$ToolDir = Join-Path $env:LOCALAPPDATA "ArchivePwExtract"
$LogDir = Join-Path $ToolDir "Logs"
$ConfigFile = Join-Path $ToolDir "config.json"
$CacheFile = Join-Path $ToolDir "password-cache.txt"
$ModulesDir = Join-Path $ToolDir "Modules"

# ============================================================
# Load modules (dot-sourced for shared scope)
# ============================================================

. "$ModulesDir\Config.ps1"

Read-Config

New-Item -ItemType Directory -Force -Path $PwDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
$RunLogPath = Join-Path $LogDir "ArchivePwExtract_$RunStamp.log"

if ($LogRetentionDays -gt 0) {
    $cutoff = (Get-Date).AddDays(-$LogRetentionDays)
    Get-ChildItem -LiteralPath $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

. "$ModulesDir\Logging.ps1"
. "$ModulesDir\ConsoleUI.ps1"
. "$ModulesDir\ArchiveUtils.ps1"
. "$ModulesDir\Extraction.ps1"
. "$ModulesDir\Passwords.ps1"
. "$ModulesDir\Parallel.ps1"
. "$ModulesDir\WpfGui.ps1"

# ============================================================
# Main
# ============================================================

try {
    Clear-Host
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    Write-Log "============================================================"
    Write-Log "ArchivePwExtract multi-engine run started"
    Write-Log "PowerShell version: $($PSVersionTable.PSVersion)"
    Write-Log "OS: $([Environment]::OSVersion.VersionString)"
    Write-Log "User: $env:USERNAME"
    Write-Log "Computer: $env:COMPUTERNAME"
    Write-Log "Password file: $PwFile"
    Write-Log "Log file: $RunLogPath"
    Write-Log "Config file: $ConfigFile"
    Write-Log "ExistingOutputBehavior: $ExistingOutputBehavior"
    Write-Log "SevenZipOverwriteMode: $SevenZipOverwriteMode"
    Write-Log "TryExtractEvenIfTestFails: $TryExtractEvenIfTestFails"
    Write-Log "ExtractionTimeoutSeconds: $ExtractionTimeoutSeconds"
    Write-Log "LogRetentionDays: $LogRetentionDays"
    Write-Log "UsePasswordCache: $UsePasswordCache"
    Write-Log "TestOnlyFirst: $TestOnlyFirst"
    Write-Log "CheckEncryptionBeforeCycling: $CheckEncryptionBeforeCycling"
    Write-Log "LargeArchiveThresholdMB: $LargeArchiveThresholdMB"
    Write-Log "MaxParallelArchives: $MaxParallelArchives"
    Write-Log "MaxParallelPasswords: $MaxParallelPasswords"
    Write-Log "PreferGui: $PreferGui"

    foreach ($p in $InputPaths) {
        Write-Log "Input: $p"
    }

    Write-Log "============================================================"

    # GUI mode check
    $launchGui = $false
    if ($PreferGui -and $PSVersionTable.PSVersion.Major -ge 5) {
        $launchGui = $true
    }

    # Interactive browse menu when launched without arguments
    if (-not $launchGui -and (!$InputPaths -or $InputPaths.Count -eq 0)) {
        $selectedPaths = Show-InteractiveMenu
        if ($selectedPaths -and $selectedPaths.Count -gt 0) {
            if ($selectedPaths[0] -eq "__GUI_MODE__") {
                $launchGui = $true
                $InputPaths = $null
            } else {
                $InputPaths = $selectedPaths
            }
        } else {
            exit 0
        }
    }

    if ($launchGui) {
        Show-ExtractionGui -ModulesDir $ModulesDir
        exit 0
    }

    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "     Archive Password-List Extractor" -ForegroundColor White -NoNewline
    Write-Host "               |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "         Multi-Engine  |  v4.0" -ForegroundColor DarkGray -NoNewline
    Write-Host "                      |" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Log "Archive password-list extractor - multi engine v4.0"
    Write-Both "" "INFO"
    Write-Status "Log: $RunLogPath" "dim"
    Write-Both "" "INFO"

    $SevenZip = Get-NormalSevenZipPath
    $PeaZip7z = Get-PeaZipBundledSevenZipPath
    $WinRar = Get-WinRarOrUnRarPath

    # Validate engines actually work
    if ($SevenZip -and -not (Test-EngineWorks $SevenZip)) {
        Write-Log "7-Zip at $SevenZip failed smoke test; disabling." "WARN"
        $SevenZip = $null
    }
    if ($PeaZip7z -and -not (Test-EngineWorks $PeaZip7z)) {
        Write-Log "PeaZip 7z at $PeaZip7z failed smoke test; disabling." "WARN"
        $PeaZip7z = $null
    }
    if ($WinRar -and -not (Test-EngineWorks $WinRar)) {
        Write-Log "WinRAR/UnRAR at $WinRar failed smoke test; disabling." "WARN"
        $WinRar = $null
    }

    Write-Status "Detected engines:" "info"
    if ($SevenZip) {
        Write-Host "    [" -NoNewline; Write-Host "OK" -ForegroundColor Green -NoNewline; Write-Host "] 7-Zip             $SevenZip"
    } else {
        Write-Host "    [" -NoNewline; Write-Host "--" -ForegroundColor DarkGray -NoNewline; Write-Host "] 7-Zip             " -NoNewline; Write-Host "not found" -ForegroundColor DarkGray
    }
    if ($WinRar) {
        Write-Host "    [" -NoNewline; Write-Host "OK" -ForegroundColor Green -NoNewline; Write-Host "] WinRAR/UnRAR      $WinRar"
    } else {
        Write-Host "    [" -NoNewline; Write-Host "--" -ForegroundColor DarkGray -NoNewline; Write-Host "] WinRAR/UnRAR      " -NoNewline; Write-Host "not found" -ForegroundColor DarkGray
    }
    if ($PeaZip7z) {
        Write-Host "    [" -NoNewline; Write-Host "OK" -ForegroundColor Green -NoNewline; Write-Host "] PeaZip bundled 7z $PeaZip7z"
    } else {
        Write-Host "    [" -NoNewline; Write-Host "--" -ForegroundColor DarkGray -NoNewline; Write-Host "] PeaZip bundled 7z " -NoNewline; Write-Host "not found" -ForegroundColor DarkGray
    }
    Write-Both "" "INFO"

    Write-Log "Detected 7-Zip: $SevenZip"
    Write-Log "Detected WinRAR/UnRAR: $WinRar"
    Write-Log "Detected PeaZip bundled 7z: $PeaZip7z"

    if (-not $SevenZip -and -not $PeaZip7z -and -not $WinRar) {
        Write-Status "No extraction engine found. Install 7-Zip, WinRAR, or PeaZip." "fail"
        Write-Log "No extraction engine found." "ERROR"
        Pause-Close
        exit 1
    }

    if (!(Test-Path -LiteralPath $PwFile)) {
        New-Item -ItemType File -Force -Path $PwFile | Out-Null
        Write-Log "Created missing password file: $PwFile"
    }

    $result = Find-ArchivesFromInputs -Paths $InputPaths
    $Archives = @($result.Archives)
    $Skipped = @($result.Skipped)

    if ($Archives.Count -eq 0) {
        Write-Status "No supported archive entry files found." "fail"
        Write-Log "No supported archive entry files found." "ERROR"
        Pause-Close
        exit 1
    }

    Write-Status "Password list: $PwFile" "dim"
    if ($UsePasswordCache) {
        Write-Status "Password cache: $CacheFile" "dim"
    }
    Write-Both "" "INFO"

    # Custom output directory
    $UseCustomOutputDir = $false
    $CustomOutputBase = $null

    if ($DefaultOutputDirectory -and $DefaultOutputDirectory.Length -gt 0) {
        $expanded = [Environment]::ExpandEnvironmentVariables($DefaultOutputDirectory)
        if (!(Test-Path -LiteralPath $expanded)) {
            $createIt = Read-YesNo "Default output directory does not exist: $expanded. Create it?" $true
            if ($createIt) {
                New-Item -ItemType Directory -Force -Path $expanded | Out-Null
            }
        }
        if (Test-Path -LiteralPath $expanded) {
            $UseCustomOutputDir = $true
            $CustomOutputBase = $expanded
            Write-Status "Default output directory: $expanded" "info"
        }
    }

    if ($AlwaysAskOutputDirectory) {
        Write-Both "" "INFO"
        $currentDefault = if ($UseCustomOutputDir) { $CustomOutputBase } else { "(next to archive)" }
        Write-Status "Current output directory: $currentDefault" "dim"
        $customPath = Read-Host "    Output directory (Enter for default, or paste path)"
        if (-not [string]::IsNullOrWhiteSpace($customPath)) {
            $cleaned = $customPath.Trim('"')
            $expanded = [Environment]::ExpandEnvironmentVariables($cleaned)
            if (!(Test-Path -LiteralPath $expanded)) {
                New-Item -ItemType Directory -Force -Path $expanded | Out-Null
            }
            if (Test-Path -LiteralPath $expanded) {
                $UseCustomOutputDir = $true
                $CustomOutputBase = $expanded
            }
        }
    }

    Write-Status "Output behavior:" "info"
    switch ($ExistingOutputBehavior.ToLowerInvariant()) {
        "replace" { Write-Status "Existing extracted folders will be REPLACED." "dim" }
        "merge"   { Write-Status "Existing extracted folders will be MERGED (files overwritten)." "dim" }
        "new"     { Write-Status "Existing extracted folders will be kept; new _2/_3 folders created." "dim" }
        default   { Write-Status "Existing extracted folders will be REPLACED." "dim" }
    }
    Write-Both "" "INFO"

    Write-Status "Found $($Archives.Count) archive entry file(s):" "info"
    Write-Both "" "INFO"

    $i = 0

    foreach ($archive in $Archives) {
        $i++
        $fileSize = ""
        try {
            $fi = Get-Item -LiteralPath $archive -ErrorAction SilentlyContinue
            if ($fi) { $fileSize = " (" + (Format-FileSize $fi.Length) + ")" }
        } catch {}
        $indexStr = "$i".PadLeft(([string]$Archives.Count).Length)
        Write-Host "    " -NoNewline
        Write-Host "[$indexStr]" -ForegroundColor DarkCyan -NoNewline
        Write-Host " $archive" -NoNewline
        Write-Host $fileSize -ForegroundColor DarkGray
        Write-Log "[$i] $archive"
    }

    if ($Skipped.Count -gt 0) {
        Write-Both "" "INFO"
        Write-Status "Skipped $($Skipped.Count) unsupported or non-entry file(s):" "warn"

        foreach ($item in $Skipped) {
            Write-Host "    - $item" -ForegroundColor DarkYellow
            Write-Log "Skipped: $item" "WARN"
        }
    }

    if ($AskBeforeExtracting) {
        Write-Both "" "INFO"
        $continue = Read-YesNo "Continue with these $($Archives.Count) archive(s)?" $true

        if (-not $continue) {
            Write-Both "Cancelled." "INFO"
            Pause-Close
            exit 0
        }
    }

    if ($AskSeparateFolders) {
        $SeparateFolders = Read-YesNo "Extract each archive into its own separate folder?" $DefaultSeparateFolders
    } else {
        $SeparateFolders = $DefaultSeparateFolders
    }

    $CommonOutputDir = $null

    if (-not $SeparateFolders) {
        $firstDir = if ($UseCustomOutputDir) { $CustomOutputBase } else { Split-Path $Archives[0] -Parent }
        if ([string]::IsNullOrEmpty($firstDir)) {
            $firstDir = [IO.Path]::GetPathRoot($Archives[0])
        }
        $defaultCommon = Join-Path $firstDir ("Extracted_Batch_" + (Get-Date -Format "yyyyMMdd_HHmmss"))

        Write-Both "" "INFO"
        Write-Both "Default shared output folder:" "INFO"
        Write-Both $defaultCommon "INFO"

        $custom = Read-Host "Press Enter to use default, or paste a custom output folder"

        if ([string]::IsNullOrWhiteSpace($custom)) {
            $CommonOutputDir = $defaultCommon
        } else {
            $cleaned = $custom.Trim('"')
            $invalidChars = [IO.Path]::GetInvalidPathChars()
            $hasInvalid = $false
            foreach ($c in $invalidChars) {
                if ($cleaned.Contains($c)) { $hasInvalid = $true; break }
            }
            if ($hasInvalid) {
                Write-Both "Invalid characters in path. Using default." "WARN" "Yellow"
                $CommonOutputDir = $defaultCommon
            } else {
                $CommonOutputDir = $cleaned
            }
        }

        New-Item -ItemType Directory -Force -Path $CommonOutputDir | Out-Null
    }

    $Passwords = @(Get-Passwords)

    if ($Passwords.Count -eq 0) {
        Write-Status "No passwords loaded and no-password testing is disabled." "fail"
        Write-Log "No passwords loaded." "ERROR"
        Pause-Close
        exit 1
    }

    # ============================================================
    # Parallel archive mode
    # ============================================================

    if ($MaxParallelArchives -gt 1 -and $Archives.Count -gt 1) {
        Write-Status "Parallel mode: processing up to $MaxParallelArchives archives concurrently" "info"
        Write-Log "Launching parallel archive extraction (max $MaxParallelArchives threads)"

        $parallelResults = Invoke-ParallelArchiveExtraction `
            -Archives $Archives `
            -Passwords $Passwords `
            -SevenZip $SevenZip `
            -PeaZip7z $PeaZip7z `
            -WinRar $WinRar `
            -SeparateFolders $SeparateFolders `
            -CommonOutputDir $CommonOutputDir `
            -UseCustomOutputDir $UseCustomOutputDir `
            -CustomOutputBase $CustomOutputBase `
            -MaxThreads $MaxParallelArchives `
            -ModulesDir $ModulesDir

        $totalStopwatch.Stop()

        $Succeeded = @($parallelResults | Where-Object { $_.Status -eq "Succeeded" -or $_.Status -eq "NoPassword" } | ForEach-Object { $_.Archive })
        $Failed = @($parallelResults | Where-Object { $_.Status -eq "Failed" } | ForEach-Object { $_.Archive })
        $NoPassword = @($parallelResults | Where-Object { $_.Status -eq "NoPassword" } | ForEach-Object { $_.Archive })
        $OutputFolders = @($parallelResults | Where-Object { $_.OutputDir } | ForEach-Object { $_.OutputDir })

        # Fall through to summary
    } else {

    # ============================================================
    # Sequential archive processing
    # ============================================================

    $Succeeded = @()
    $Failed = @()
    $NoPassword = @()
    $OutputFolders = @()

    $ArchiveIndex = 0

    foreach ($Archive in $Archives) {
        $ArchiveIndex++
        $archiveStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $archiveName = [IO.Path]::GetFileName($Archive)
        Write-Section "[$ArchiveIndex/$($Archives.Count)] $archiveName"
        Write-Status $Archive "dim"

        if ($Archives.Count -gt 1) {
            $batchElapsed = Format-ElapsedFromMs $totalStopwatch.ElapsedMilliseconds
            Write-Status "Archive $ArchiveIndex/$($Archives.Count)  |  Overall elapsed: $batchElapsed" "dim"
        }

        Write-Both "" "INFO"

        if (-not (Test-FileAccessible $Archive)) {
            Write-Status "Archive is locked by another process or inaccessible." "fail"
            Write-Log "Archive locked or inaccessible: $Archive" "ERROR"
            $Failed += $Archive
            continue
        }

        $archiveSizeMB = 0
        try {
            $fi = Get-Item -LiteralPath $Archive -ErrorAction SilentlyContinue
            if ($fi) { $archiveSizeMB = [math]::Round($fi.Length / 1MB, 1) }
        } catch {}

        $isLargeArchive = ($archiveSizeMB -ge $LargeArchiveThresholdMB)
        if ($isLargeArchive) {
            Write-Status "Large archive ($(Format-FileSize ($archiveSizeMB * 1MB))) - password testing may be slow" "warn"
            Write-Log "Large archive detected: ${archiveSizeMB} MB" "WARN"
        }

        $volCheck = Test-MultiVolumeComplete $Archive
        if ($volCheck.Missing.Count -gt 0) {
            Write-Status "Warning: missing volume(s) detected: $($volCheck.Missing -join ', ')" "warn"
            Write-Log "Missing volumes: $($volCheck.Missing -join ', ')" "WARN"
        }

        $enginePlan = @(Get-EnginePlanForArchive -Archive $Archive -SevenZip $SevenZip -PeaZip7z $PeaZip7z -WinRar $WinRar)

        if (@($enginePlan).Count -eq 0) {
            Write-Status "No compatible engine for this archive." "fail"
            Write-Log "No compatible engine for this archive." "ERROR"
            $Failed += $Archive
            continue
        }

        Write-Status "Engines: $(($enginePlan | ForEach-Object { $_.Name }) -join ', ')" "info"
        Write-Both "" "INFO"

        $archiveDir = Split-Path $Archive -Parent
        $archiveBase = Get-ArchiveBaseName $Archive

        if ($SeparateFolders) {
            $outputBaseDir = if ($UseCustomOutputDir) { $CustomOutputBase } else { $archiveDir }
            $outputBase = Join-Path $outputBaseDir $archiveBase
            $outputDir = Resolve-OutputDir -BaseDir $outputBase -IsSharedOutput $false
        } else {
            $outputDir = Resolve-OutputDir -BaseDir $CommonOutputDir -IsSharedOutput $true
        }

        Write-Log "Output dir selected: $outputDir"

        $found = $false
        $isEncryptable = Test-IsEncryptionCapable $Archive

        $actuallyEncrypted = $null
        if ($isEncryptable -and $CheckEncryptionBeforeCycling -and $SevenZip) {
            Write-Status "Inspecting archive encryption status..." "dim"
            $actuallyEncrypted = Test-ArchiveIsEncrypted -Archive $Archive -SevenZipPath $SevenZip
            if ($actuallyEncrypted -eq $false) {
                Write-Status "Archive is not encrypted despite encryption-capable format; extracting directly..." "info"
                Write-Log "Header inspection: archive is not encrypted."
                $isEncryptable = $false
            } elseif ($null -eq $actuallyEncrypted) {
                Write-Log "Header inspection: could not determine encryption status; proceeding with password cycling."
            } else {
                Write-Log "Header inspection: archive is encrypted."
            }
        }

        if (-not $isEncryptable) {
            Write-Status "Format does not support encryption; extracting directly..." "info"

            foreach ($engine in $enginePlan) {
                Write-Host "    Trying " -NoNewline -ForegroundColor DarkGray
                Write-Host $engine.Name -NoNewline -ForegroundColor White
                Write-Host "..." -ForegroundColor DarkGray

                $ok = Try-EnginePassword `
                    -EngineName $engine.Name `
                    -EnginePath $engine.Path `
                    -Archive $Archive `
                    -Password "" `
                    -OutputDir $outputDir `
                    -CanClearFailedOutput $SeparateFolders `
                    -OmitPasswordArg $true `
                    -Timeout $ExtractionTimeoutSeconds

                if ($ok) {
                    $archiveStopwatch.Stop()
                    Write-Both "" "INFO"
                    Write-Status "Extracted successfully (no password required)" "success"
                    Write-Status "Engine: $($engine.Name)  |  Time: $(Format-Elapsed $archiveStopwatch)" "dim"
                    Write-Status "Output: $outputDir" "dim"
                    $Succeeded += $Archive
                    $NoPassword += $Archive
                    $OutputFolders += $outputDir
                    $found = $true
                    break
                }
            }

            if (-not $found) {
                $archiveStopwatch.Stop()
                Write-Both "" "INFO"
                Write-Status "FAILED: could not extract (corrupted, unsupported, or missing split part)" "fail"
                Write-Status "See log: $RunLogPath" "dim"
                Write-Log "FAILED: $Archive" "ERROR"
                $Failed += $Archive
                Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $SeparateFolders
            }

            continue
        }

        # Reorder passwords: put last successful password first
        $currentPasswords = $Passwords
        if ($lastSuccessfulPassword) {
            $reordered = @($lastSuccessfulPassword)
            foreach ($pw in $Passwords) {
                if ($pw -ne $lastSuccessfulPassword) {
                    $reordered += $pw
                }
            }
            $currentPasswords = $reordered
            Write-Log "Reordered passwords: last successful password moved to front."
        }

        $totalPasswords = $currentPasswords.Count
        $passwordIndex = 0
        $passwordStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        Write-Status "Testing $totalPasswords password(s) across $(@($enginePlan).Count) engine(s)..." "info"

        $useTestOnly = $TestOnlyFirst -or ($isLargeArchive -and $SkipTestExtractFallbackForLargeArchives)
        $winningPassword = $null
        $winningEngine = $null

        # Parallel password testing
        if ($MaxParallelPasswords -gt 1 -and $currentPasswords.Count -gt 1 -and $useTestOnly) {
            Write-Log "Using parallel password testing ($MaxParallelPasswords threads)"
            $parallelWinner = Invoke-ParallelPasswordTest `
                -Passwords $currentPasswords `
                -EnginePlan $enginePlan `
                -Archive $Archive `
                -OutputDir $outputDir `
                -SeparateFolders $SeparateFolders `
                -Timeout $ExtractionTimeoutSeconds `
                -MaxThreads $MaxParallelPasswords `
                -ModulesDir $ModulesDir

            if ($parallelWinner) {
                $winningPassword = $parallelWinner.Password
                $winningEngine = $parallelWinner.Engine
            }
        } elseif ($useTestOnly) {
            Write-Log "Using test-only-then-extract optimization."

            foreach ($Pw in $currentPasswords) {
                $passwordIndex++

                Write-ProgressBar -Current $passwordIndex -Total $totalPasswords -ElapsedMs $passwordStopwatch.ElapsedMilliseconds

                if ($Pw -eq "") {
                    Write-Log "Test-only: trying without password [$passwordIndex/$totalPasswords]..."
                } else {
                    Write-Log "Test-only: trying password [$passwordIndex/$totalPasswords]..."
                }

                foreach ($engine in $enginePlan) {
                    $testOk = Try-EnginePassword `
                        -EngineName $engine.Name `
                        -EnginePath $engine.Path `
                        -Archive $Archive `
                        -Password $Pw `
                        -OutputDir $outputDir `
                        -CanClearFailedOutput $SeparateFolders `
                        -Timeout $ExtractionTimeoutSeconds `
                        -TestOnly $true

                    if ($testOk) {
                        $winningPassword = $Pw
                        $winningEngine = $engine
                        break
                    }
                }

                if ($winningPassword -ne $null -or ($winningEngine -ne $null)) {
                    break
                }
            }
        }

        Write-Host ""

        if ($winningEngine) {
            Write-Log "Test-only phase found password with $($winningEngine.Name); proceeding to extract."

            $extractOk = Try-EnginePassword `
                -EngineName $winningEngine.Name `
                -EnginePath $winningEngine.Path `
                -Archive $Archive `
                -Password $winningPassword `
                -OutputDir $outputDir `
                -CanClearFailedOutput $SeparateFolders `
                -Timeout $ExtractionTimeoutSeconds `
                -TestOnly $false

            if ($extractOk) {
                $archiveStopwatch.Stop()
                Write-Both "" "INFO"

                if ($winningPassword -eq "") {
                    Write-Status "Extracted successfully (no password required)" "success"
                    $NoPassword += $Archive
                } else {
                    Write-Status "Password found and extracted successfully" "success"

                    if ($ShowPasswordInConsole) {
                        Write-Host "    Password: $winningPassword" -ForegroundColor White
                    } else {
                        Write-Host "    Password: " -ForegroundColor DarkGray -NoNewline
                        Write-Host (Format-MaskedPassword $winningPassword) -ForegroundColor White
                    }

                    Write-Log "SUCCESS: found password. Password redacted in log."
                    Save-PasswordToCache $winningPassword
                    $lastSuccessfulPassword = $winningPassword

                    if ($PSVersionTable.PSVersion.Major -ge 5) {
                        try {
                            $winningPassword | Set-Clipboard
                            $lastCopiedPassword = $winningPassword
                            Write-Status "Password copied to clipboard" "dim"
                        } catch {
                            Write-Log "Could not copy password to clipboard: $($_.Exception.Message)" "WARN"
                        }
                    } else {
                        Write-Status "Clipboard copy requires PowerShell 5.0+" "warn"
                    }
                }

                Write-Status "Engine: $($winningEngine.Name)  |  Time: $(Format-Elapsed $archiveStopwatch)" "dim"
                Write-Status "Output: $outputDir" "dim"

                $Succeeded += $Archive
                $OutputFolders += $outputDir
                $found = $true
            } else {
                Write-Log "Test succeeded but extraction failed; falling back to full cycle." "WARN"
            }
        }

        # Fallback: if test-only found nothing but TryExtractEvenIfTestFails, do full cycle
        if (-not $found -and $TryExtractEvenIfTestFails -and -not ($isLargeArchive -and $SkipTestExtractFallbackForLargeArchives)) {
            Write-Log "Test-only phase found no match; falling back to full extract cycle."
            $passwordIndex = 0
            $passwordStopwatch.Restart()

            foreach ($Pw in $currentPasswords) {
                $passwordIndex++
                Write-ProgressBar -Current $passwordIndex -Total $totalPasswords -ElapsedMs $passwordStopwatch.ElapsedMilliseconds

                foreach ($engine in $enginePlan) {
                    $ok = Try-EnginePassword `
                        -EngineName $engine.Name `
                        -EnginePath $engine.Path `
                        -Archive $Archive `
                        -Password $Pw `
                        -OutputDir $outputDir `
                        -CanClearFailedOutput $SeparateFolders `
                        -Timeout $ExtractionTimeoutSeconds

                    if ($ok) {
                        Write-Host ""
                        $archiveStopwatch.Stop()
                        Write-Both "" "INFO"

                        if ($Pw -eq "") {
                            Write-Status "Extracted successfully (no password required)" "success"
                            $NoPassword += $Archive
                        } else {
                            Write-Status "Password found and extracted successfully" "success"

                            if ($ShowPasswordInConsole) {
                                Write-Host "    Password: $Pw" -ForegroundColor White
                            } else {
                                Write-Host "    Password: " -ForegroundColor DarkGray -NoNewline
                                Write-Host (Format-MaskedPassword $Pw) -ForegroundColor White
                            }

                            Write-Log "SUCCESS: found password. Password redacted in log."
                            Save-PasswordToCache $Pw
                            $lastSuccessfulPassword = $Pw

                            if ($PSVersionTable.PSVersion.Major -ge 5) {
                                try {
                                    $Pw | Set-Clipboard
                                    $lastCopiedPassword = $Pw
                                    Write-Status "Password copied to clipboard" "dim"
                                } catch {
                                    Write-Log "Could not copy password to clipboard: $($_.Exception.Message)" "WARN"
                                }
                            } else {
                                Write-Status "Clipboard copy requires PowerShell 5.0+" "warn"
                            }
                        }

                        Write-Status "Engine: $($engine.Name)  |  Time: $(Format-Elapsed $archiveStopwatch)" "dim"
                        Write-Status "Output: $outputDir" "dim"

                        $Succeeded += $Archive
                        $OutputFolders += $outputDir
                        $found = $true
                        break
                    }
                }

                if ($found) { break }
            }
        }

        if (-not $useTestOnly -and -not $found) {
            # Original full test+extract per password
            $passwordIndex = 0
            $passwordStopwatch.Restart()

            foreach ($Pw in $currentPasswords) {
                $passwordIndex++

                Write-ProgressBar -Current $passwordIndex -Total $totalPasswords -ElapsedMs $passwordStopwatch.ElapsedMilliseconds

                if ($Pw -eq "") {
                    Write-Log "Trying without password [$passwordIndex/$totalPasswords]..."
                } else {
                    Write-Log "Trying password [$passwordIndex/$totalPasswords]..."
                }

                foreach ($engine in $enginePlan) {
                    $ok = Try-EnginePassword `
                        -EngineName $engine.Name `
                        -EnginePath $engine.Path `
                        -Archive $Archive `
                        -Password $Pw `
                        -OutputDir $outputDir `
                        -CanClearFailedOutput $SeparateFolders `
                        -Timeout $ExtractionTimeoutSeconds

                    if ($ok) {
                        Write-Host ""
                        $archiveStopwatch.Stop()
                        Write-Both "" "INFO"

                        if ($Pw -eq "") {
                            Write-Status "Extracted successfully (no password required)" "success"
                            $NoPassword += $Archive
                        } else {
                            Write-Status "Password found and extracted successfully" "success"

                            if ($ShowPasswordInConsole) {
                                Write-Host "    Password: $Pw" -ForegroundColor White
                            } else {
                                Write-Host "    Password: " -ForegroundColor DarkGray -NoNewline
                                Write-Host (Format-MaskedPassword $Pw) -ForegroundColor White
                            }

                            Write-Log "SUCCESS: found password. Password redacted in log."
                            Save-PasswordToCache $Pw
                            $lastSuccessfulPassword = $Pw

                            if ($PSVersionTable.PSVersion.Major -ge 5) {
                                try {
                                    $Pw | Set-Clipboard
                                    $lastCopiedPassword = $Pw
                                    Write-Status "Password copied to clipboard" "dim"
                                } catch {
                                    Write-Log "Could not copy password to clipboard: $($_.Exception.Message)" "WARN"
                                }
                            } else {
                                Write-Status "Clipboard copy requires PowerShell 5.0+" "warn"
                            }
                        }

                        Write-Status "Engine: $($engine.Name)  |  Time: $(Format-Elapsed $archiveStopwatch)" "dim"
                        Write-Status "Output: $outputDir" "dim"

                        $Succeeded += $Archive
                        $OutputFolders += $outputDir
                        $found = $true
                        break
                    }
                }

                if ($found) {
                    break
                }
            }
        }

        if (-not $found) {
            Write-Host ""
            $archiveStopwatch.Stop()
            Write-Both "" "INFO"
            Write-Status "FAILED: no matching password or archive could not be extracted" "fail"
            Write-Status "See log: $RunLogPath" "dim"
            Write-Log "FAILED: $Archive" "ERROR"
            $Failed += $Archive
            Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $SeparateFolders
        }

        $archiveStopwatch.Stop()
        Write-Log "Archive completed in $($archiveStopwatch.Elapsed.ToString('hh\:mm\:ss'))"
    }

    $totalStopwatch.Stop()

    } # end of sequential else block

    # ============================================================
    # Summary
    # ============================================================

    Write-Section "Summary"

    $totalCount = $Archives.Count
    $succCount = @($Succeeded).Count
    $failCount = @($Failed).Count
    $noPwCount = @($NoPassword).Count
    $elapsed = $totalStopwatch.Elapsed.ToString('hh\:mm\:ss')

    Write-Host ""
    Write-Host "    Results" -ForegroundColor White
    Write-Host "    -------" -ForegroundColor DarkGray

    Write-Host "    Succeeded:    " -NoNewline
    if ($succCount -gt 0) { Write-Host "$succCount / $totalCount" -ForegroundColor Green }
    else { Write-Host "$succCount / $totalCount" -ForegroundColor DarkGray }

    Write-Host "    Failed:       " -NoNewline
    if ($failCount -gt 0) { Write-Host "$failCount / $totalCount" -ForegroundColor Red }
    else { Write-Host "$failCount / $totalCount" -ForegroundColor Green }

    Write-Host "    No password:  " -NoNewline
    Write-Host "$noPwCount" -ForegroundColor DarkGray

    Write-Host "    Total time:   " -NoNewline
    Write-Host $elapsed -ForegroundColor White

    Write-Host ""

    Write-Log "Summary: Succeeded=$succCount Failed=$failCount NoPassword=$noPwCount Elapsed=$elapsed"

    Show-CompletionToast -Succeeded $succCount -Failed $failCount -Total $totalCount

    if ($failCount -gt 0) {
        Write-Status "Failed archives:" "fail"

        foreach ($item in $Failed) {
            Write-Host "    - " -NoNewline -ForegroundColor Red
            Write-Host $item
        }

        Write-Host ""
        Write-Status "Tip: Copy any known passwords into the password list file." "warn"
        Write-Status "PeaZip's Password Manager cannot be read automatically." "dim"
        Write-Status "Password file: $PwFile" "dim"
        Write-Status "Diagnostic log: $RunLogPath" "dim"

        $edit = Read-YesNo "Open password list now?" $false

        if ($edit) {
            Start-Process notepad.exe -ArgumentList $PwFile
        }
    } else {
        Write-Status "All $totalCount archive(s) completed successfully." "success"
        Write-Status "Diagnostic log: $RunLogPath" "dim"
    }

    if ($OpenOutputAfterSuccess -and @($OutputFolders).Count -gt 0) {
        $openFirst = Read-YesNo "Open first output folder?" $true

        if ($openFirst) {
            Start-Process -FilePath "explorer.exe" -ArgumentList @($OutputFolders[0])
        }
    }

    Write-Log "Run completed. Succeeded=$succCount Failed=$failCount NoPassword=$noPwCount"
    Write-Log "ArchivePwExtract run ended"

    if ($AlwaysShowFinalConfirmation) {
        Write-Host ""
        Write-Host "    Done." -ForegroundColor Cyan
        Pause-Close
    }

    if ($ClearClipboardOnExit -and $lastCopiedPassword -and $PSVersionTable.PSVersion.Major -ge 5) {
        try {
            $current = Get-Clipboard -ErrorAction SilentlyContinue
            if ($null -ne $current -and $current -eq $lastCopiedPassword) {
                Set-Clipboard -Value ""
                Write-Log "Clipboard cleared."
            }
        } catch {
            Write-Log "Could not clear clipboard: $($_.Exception.Message)" "WARN"
        }
    }

    exit 0
}
catch {
    Write-Host ""
    Write-Status "Fatal error: $($_.Exception.Message)" "fail"
    Write-Log "Fatal error: $($_.Exception.ToString())" "ERROR"
    Pause-Close
    exit 1
}
