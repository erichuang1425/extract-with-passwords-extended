# Parallel.ps1 — Runspace pool management for concurrent archive and password processing

function New-ExtractionRunspacePool {
    param([int]$MaxThreads = 2)

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, $MaxThreads, $iss, $Host)
    $pool.ApartmentState = [System.Threading.ApartmentState]::MTA
    $pool.Open()
    return $pool
}

function Invoke-ParallelPasswordTest {
    param(
        [object[]]$Passwords,
        [object[]]$EnginePlan,
        [string]$Archive,
        [string]$OutputDir,
        [bool]$SeparateFolders,
        [int]$Timeout,
        [int]$MaxThreads = 4,
        [string]$ModulesDir
    )

    if ($MaxThreads -le 1 -or $Passwords.Count -le 1) {
        return $null
    }

    $cancelSource = New-Object System.Threading.CancellationTokenSource
    $resultBag = [System.Collections.Concurrent.ConcurrentDictionary[string, object]]::new()
    $errorBag = [System.Collections.Concurrent.ConcurrentBag[string]]::new()
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    foreach ($pw in $Passwords) { $queue.Enqueue([string]$pw) }
    $jobs = @()

    $scriptBlock = {
        param(
            $Queue, $EnginePlan, $Archive, $OutputDir,
            $SeparateFolders, $Timeout,
            $CancelSource, $ResultBag, $ErrorBag, $ModulesDir,
            $ConfigVars
        )

        foreach ($key in $ConfigVars.Keys) {
            Set-Variable -Name $key -Value $ConfigVars[$key] -Scope 0
        }

        $RunLogPath = $ConfigVars["RunLogPath"]

        . "$ModulesDir\Logging.ps1"
        . "$ModulesDir\ArchiveUtils.ps1"
        . "$ModulesDir\Extraction.ps1"

        $pw = $null
        while (-not $CancelSource.Token.IsCancellationRequested) {
            if (-not $Queue.TryDequeue([ref]$pw)) { break }

            foreach ($engine in $EnginePlan) {
                if ($CancelSource.Token.IsCancellationRequested) { break }

                $testOk = $false
                try {
                    if ($engine.Name -eq "7-Zip" -or $engine.Name -eq "PeaZip bundled 7z") {
                        $testOk = Test-With7z -SevenZip $engine.Path -Archive $Archive -Password $pw -Timeout $Timeout
                    } elseif ($engine.Name -eq "WinRAR" -or $engine.Name -eq "UnRAR") {
                        $testOk = Test-WithWinRar -RarExe $engine.Path -Archive $Archive -Password $pw -Timeout $Timeout
                    }
                } catch {
                    $ErrorBag.Add("Engine $($engine.Name) threw while testing a password: $($_.Exception.Message)")
                    continue
                }

                if ($testOk) {
                    [void]$ResultBag.TryAdd("winner", @{ Password = $pw; Engine = $engine })
                    $CancelSource.Cancel()
                    break
                }
            }
        }
    }

    $configVars = @{
        RunLogPath = $RunLogPath
        VerboseEngineLogging = $VerboseEngineLogging
        TryExtractEvenIfTestFails = $TryExtractEvenIfTestFails
        CleanFailedAttemptOutput = $CleanFailedAttemptOutput
        SevenZipOverwriteMode = $SevenZipOverwriteMode
        WinRarOverwriteMode = $WinRarOverwriteMode
        UseSevenZip = $UseSevenZip
        UseWinRarFallback = $UseWinRarFallback
        UsePeaZipBundled7zFallback = $UsePeaZipBundled7zFallback
        EncryptionCapableExtensions = $EncryptionCapableExtensions
    }

    $workerCount = [math]::Min([int]$MaxThreads, [int]$Passwords.Count)
    $pool = New-ExtractionRunspacePool -MaxThreads $workerCount

    try {
        for ($t = 0; $t -lt $workerCount; $t++) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($scriptBlock)
            [void]$ps.AddArgument($queue)
            [void]$ps.AddArgument($EnginePlan)
            [void]$ps.AddArgument($Archive)
            [void]$ps.AddArgument($OutputDir)
            [void]$ps.AddArgument($SeparateFolders)
            [void]$ps.AddArgument($Timeout)
            [void]$ps.AddArgument($cancelSource)
            [void]$ps.AddArgument($resultBag)
            [void]$ps.AddArgument($errorBag)
            [void]$ps.AddArgument($ModulesDir)
            [void]$ps.AddArgument($configVars)

            $handle = $ps.BeginInvoke()
            $jobs += @{ PS = $ps; Handle = $handle }
        }

        foreach ($job in $jobs) {
            try {
                $job.PS.EndInvoke($job.Handle)
            } catch {
                Write-Log "Parallel password worker join failed: $($_.Exception.Message)" "ERROR"
            }
            $job.PS.Dispose()
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
        $cancelSource.Dispose()
    }

    if ($errorBag.Count -gt 0) {
        Write-Log "Parallel password test encountered $($errorBag.Count) worker error(s):" "WARN"
        foreach ($err in $errorBag) {
            Write-Log "  $err" "WARN"
        }
    }

    $winner = $null
    if ($resultBag.ContainsKey("winner")) {
        $winner = $resultBag["winner"]
    }

    return $winner
}

function Invoke-ParallelArchiveExtraction {
    param(
        [object[]]$Archives,
        [object[]]$Passwords,
        [string]$SevenZip,
        [string]$PeaZip7z,
        [string]$WinRar,
        [bool]$SeparateFolders,
        [string]$CommonOutputDir,
        [bool]$UseCustomOutputDir,
        [string]$CustomOutputBase,
        [int]$MaxThreads = 2,
        [string]$ModulesDir
    )

    $results = [System.Collections.Concurrent.ConcurrentBag[PSObject]]::new()
    $pool = New-ExtractionRunspacePool -MaxThreads $MaxThreads
    $jobs = @()

    $scriptBlock = {
        param(
            $Archive, $Passwords, $SevenZip, $PeaZip7z, $WinRar,
            $SeparateFolders, $CommonOutputDir, $UseCustomOutputDir,
            $CustomOutputBase, $Results, $ModulesDir, $ConfigVars
        )

        $outputDir = $null
        $archiveStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $engineCandidates = @()

        try {
            foreach ($key in $ConfigVars.Keys) {
                Set-Variable -Name $key -Value $ConfigVars[$key] -Scope 0
            }

            $workerLogPath = $ConfigVars["RunLogPath"] -replace '\.log$', "_worker_$([System.Threading.Thread]::CurrentThread.ManagedThreadId).log"
            $RunLogPath = $workerLogPath

            . "$ModulesDir\Logging.ps1"
            . "$ModulesDir\ConsoleUI.ps1"
            . "$ModulesDir\ArchiveUtils.ps1"
            . "$ModulesDir\Extraction.ps1"
            . "$ModulesDir\Passwords.ps1"

            $archiveName = [IO.Path]::GetFileName($Archive)
            $archiveDir = Split-Path $Archive -Parent

            if (-not (Test-FileAccessible $Archive)) {
                $archiveStopwatch.Stop()
                $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Failed"; Reason = "Inaccessible"; Password = $null; OutputDir = $null; Engine = $null; EnginesInPlan = @(); ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
                return
            }

            $enginePlan = @(Get-EnginePlanForArchive -Archive $Archive -SevenZip $SevenZip -PeaZip7z $PeaZip7z -WinRar $WinRar)
            $engineCandidates = @($enginePlan | ForEach-Object { $_.Name })
            if ($enginePlan.Count -eq 0) {
                $archiveStopwatch.Stop()
                $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Failed"; Reason = "NoEngine"; Password = $null; OutputDir = $null; Engine = $null; EnginesInPlan = @(); ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
                return
            }

            $archiveBase = Get-ArchiveBaseName $Archive
            if ($SeparateFolders) {
                $outputBaseDir = if ($UseCustomOutputDir) { $CustomOutputBase } else { $archiveDir }
                $outputBase = Join-Path $outputBaseDir $archiveBase
                $outputDir = Resolve-OutputDir -BaseDir $outputBase -IsSharedOutput $false
            } else {
                $outputDir = Resolve-OutputDir -BaseDir $CommonOutputDir -IsSharedOutput $true
            }

            $isEncryptable = Test-IsEncryptionCapable $Archive
            if ($isEncryptable -and $ConfigVars["CheckEncryptionBeforeCycling"] -and $SevenZip) {
                $actuallyEncrypted = Test-ArchiveIsEncrypted -Archive $Archive -SevenZipPath $SevenZip
                if ($actuallyEncrypted -eq $false) { $isEncryptable = $false }
            }

            if (-not $isEncryptable) {
                foreach ($engine in $enginePlan) {
                    $ok = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $Archive -Password "" -OutputDir $outputDir -CanClearFailedOutput $SeparateFolders -OmitPasswordArg $true -Timeout $ConfigVars["ExtractionTimeoutSeconds"]
                    if ($ok) {
                        $archiveStopwatch.Stop()
                        $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "NoPassword"; Reason = $null; Password = $null; OutputDir = $outputDir; Engine = $engine.Name; EnginesInPlan = $engineCandidates; ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
                        return
                    }
                }
                $archiveStopwatch.Stop()
                $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Failed"; Reason = "ExtractionFailed"; Password = $null; OutputDir = $outputDir; Engine = $null; EnginesInPlan = $engineCandidates; ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
                Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $SeparateFolders
                return
            }

            foreach ($Pw in $Passwords) {
                foreach ($engine in $enginePlan) {
                    $testOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $Archive -Password $Pw -OutputDir $outputDir -CanClearFailedOutput $SeparateFolders -Timeout $ConfigVars["ExtractionTimeoutSeconds"] -TestOnly $true
                    if ($testOk) {
                        $extractOk = Try-EnginePassword -EngineName $engine.Name -EnginePath $engine.Path -Archive $Archive -Password $Pw -OutputDir $outputDir -CanClearFailedOutput $SeparateFolders -Timeout $ConfigVars["ExtractionTimeoutSeconds"] -TestOnly $false
                        if ($extractOk) {
                            Save-PasswordToCache $Pw
                            $archiveStopwatch.Stop()
                            $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Succeeded"; Reason = $null; Password = $Pw; OutputDir = $outputDir; Engine = $engine.Name; EnginesInPlan = $engineCandidates; ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
                            return
                        }
                    }
                }
            }

            $archiveStopwatch.Stop()
            $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Failed"; Reason = "WrongPassword"; Password = $null; OutputDir = $outputDir; Engine = $null; EnginesInPlan = $engineCandidates; ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
            Remove-EmptyOutputDir -OutputDir $outputDir -SeparateFolders $SeparateFolders
        } catch {
            $errMsg = "WorkerException: $($_.Exception.Message)"
            try { Write-Log "Worker exception extracting $Archive : $errMsg" "ERROR" } catch {}
            $archiveStopwatch.Stop()
            $Results.Add([PSCustomObject]@{ Archive = $Archive; Status = "Failed"; Reason = $errMsg; Password = $null; OutputDir = $outputDir; Engine = $null; EnginesInPlan = $engineCandidates; ElapsedMs = $archiveStopwatch.ElapsedMilliseconds })
        }
    }

    $configVars = @{
        RunLogPath = $RunLogPath
        VerboseEngineLogging = $VerboseEngineLogging
        TryExtractEvenIfTestFails = $TryExtractEvenIfTestFails
        CleanFailedAttemptOutput = $CleanFailedAttemptOutput
        SevenZipOverwriteMode = $SevenZipOverwriteMode
        WinRarOverwriteMode = $WinRarOverwriteMode
        UseSevenZip = $UseSevenZip
        UseWinRarFallback = $UseWinRarFallback
        UsePeaZipBundled7zFallback = $UsePeaZipBundled7zFallback
        EncryptionCapableExtensions = $EncryptionCapableExtensions
        ExtractionTimeoutSeconds = $ExtractionTimeoutSeconds
        ExistingOutputBehavior = $ExistingOutputBehavior
        UsePasswordCache = $UsePasswordCache
        PasswordCacheRetentionDays = $PasswordCacheRetentionDays
        CheckEncryptionBeforeCycling = $CheckEncryptionBeforeCycling
        TestOnlyFirst = $TestOnlyFirst
        TryNoPasswordFirst = $TryNoPasswordFirst
        LoadAllPasswordFiles = $LoadAllPasswordFiles
        LargeArchiveThresholdMB = $LargeArchiveThresholdMB
        SkipTestExtractFallbackForLargeArchives = $SkipTestExtractFallbackForLargeArchives
    }

    try {
        foreach ($archive in $Archives) {
            $ps = [PowerShell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($scriptBlock)
            [void]$ps.AddArgument($archive)
            [void]$ps.AddArgument($Passwords)
            [void]$ps.AddArgument($SevenZip)
            [void]$ps.AddArgument($PeaZip7z)
            [void]$ps.AddArgument($WinRar)
            [void]$ps.AddArgument($SeparateFolders)
            [void]$ps.AddArgument($CommonOutputDir)
            [void]$ps.AddArgument($UseCustomOutputDir)
            [void]$ps.AddArgument($CustomOutputBase)
            [void]$ps.AddArgument($results)
            [void]$ps.AddArgument($ModulesDir)
            [void]$ps.AddArgument($configVars)

            $handle = $ps.BeginInvoke()
            $jobs += @{ PS = $ps; Handle = $handle; Archive = $archive }
        }

        foreach ($job in $jobs) {
            try { $job.PS.EndInvoke($job.Handle) } catch {
                Write-Log "Parallel worker failed for $($job.Archive): $($_.Exception.Message)" "ERROR"
            }
            $job.PS.Dispose()
        }
    } finally {
        $pool.Close()
        $pool.Dispose()

        try { Merge-WorkerLogs -MainLogPath $RunLogPath } catch {
            try { Write-Log "Merge-WorkerLogs failed: $($_.Exception.Message)" "WARN" } catch {}
        }
    }

    return @($results)
}
