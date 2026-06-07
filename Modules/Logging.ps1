# Logging.ps1 — Log writing, argument redaction, and process invocation with output capture

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message

    # The logger must never throw: a transient share violation (concurrent
    # writer, AV scanner, log open in an editor) should be retried briefly and
    # then dropped silently rather than aborting an extraction run.
    $attempts = 0
    while ($true) {
        try {
            Add-Content -LiteralPath $RunLogPath -Value $line -Encoding UTF8
            break
        } catch {
            $attempts++
            if ($attempts -ge 3) { break }
            Start-Sleep -Milliseconds 25
        }
    }
}

function Merge-WorkerLogs {
    param(
        [string]$MainLogPath
    )

    if (-not $MainLogPath -or -not (Test-Path -LiteralPath $MainLogPath)) {
        return
    }

    $logDir = Split-Path $MainLogPath -Parent
    $logLeaf = [IO.Path]::GetFileNameWithoutExtension($MainLogPath)
    $logExt = [IO.Path]::GetExtension($MainLogPath)
    $workerPattern = "${logLeaf}_worker_*${logExt}"

    $workerFiles = @()
    try {
        $workerFiles = @(Get-ChildItem -LiteralPath $logDir -Filter $workerPattern -File -ErrorAction SilentlyContinue |
                        Sort-Object Name)
    } catch {
        return
    }

    if ($workerFiles.Count -eq 0) { return }

    foreach ($wf in $workerFiles) {
        try {
            $threadId = "?"
            if ($wf.Name -match '_worker_(\d+)') {
                $threadId = $Matches[1]
            }

            $header = @(
                "",
                "--- merged from worker thread $threadId ($($wf.Name)) ---"
            )
            Add-Content -LiteralPath $MainLogPath -Value $header -Encoding UTF8

            $content = Get-Content -LiteralPath $wf.FullName -Encoding UTF8 -ErrorAction SilentlyContinue
            if ($content) {
                Add-Content -LiteralPath $MainLogPath -Value $content -Encoding UTF8
            }

            Add-Content -LiteralPath $MainLogPath -Value "--- end worker thread $threadId ---" -Encoding UTF8

            Remove-Item -LiteralPath $wf.FullName -Force -ErrorAction SilentlyContinue
        } catch {
            try { Write-Log "Failed to merge worker log $($wf.Name): $($_.Exception.Message)" "WARN" } catch {}
        }
    }
}

function Write-Both {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = ""
    )

    if ($Color) {
        Write-Host $Message -ForegroundColor $Color
    } else {
        Write-Host $Message
    }

    Write-Log -Message $Message -Level $Level
}

function Redact-ArgsForLog {
    param([object[]]$ArgumentList)

    $safe = @()
    $redactNext = $false

    foreach ($a in @($ArgumentList)) {
        $s = [string]$a

        if ($redactNext) {
            $safe += "********"
            $redactNext = $false
            continue
        }

        if ($s -eq '-p' -or $s -eq '-hp') {
            $safe += $s
            $redactNext = $true
        } elseif ($s -match '^-hp.+') {
            $safe += "-hp********"
        } elseif ($s -match '^-p.+') {
            $safe += "-p********"
        } else {
            $safe += $s
        }
    }

    return ($safe -join " ")
}

function ConvertTo-WindowsCommandLineArg {
    param([AllowNull()][string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument -eq '') {
        return '""'
    }

    $needsQuoting = $false
    if ($Argument.Contains(' ') -or $Argument.Contains('"') -or $Argument.Contains("`t")) {
        $needsQuoting = $true
    }

    if (-not $needsQuoting) {
        return $Argument
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $backslashCount = 0

    for ($i = 0; $i -lt $Argument.Length; $i++) {
        $c = $Argument[$i]

        if ($c -eq '\') {
            $backslashCount++
        } elseif ($c -eq '"') {
            [void]$sb.Append('\', $backslashCount * 2 + 1)
            [void]$sb.Append('"')
            $backslashCount = 0
        } else {
            if ($backslashCount -gt 0) {
                [void]$sb.Append('\', $backslashCount)
                $backslashCount = 0
            }
            [void]$sb.Append($c)
        }
    }

    if ($backslashCount -gt 0) {
        [void]$sb.Append('\', $backslashCount * 2)
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Get-EngineProcessPriorityClass {
    # Map the configured EngineProcessPriority string to a ProcessPriorityClass.
    # Returns $null when no (or an unrecognized) priority is configured, so the
    # caller leaves the OS default in place. Test-ConfigSane normally validates
    # the value first; this stays defensive for direct/parallel-worker use.
    # $EngineProcessPriority resolves via dynamic scope (set at script scope in
    # normal runs and re-hydrated into the worker scope in parallel runs), the
    # same convention used by every other config reference in these modules.
    if ([string]::IsNullOrWhiteSpace([string]$EngineProcessPriority)) {
        return $null
    }

    switch (([string]$EngineProcessPriority).Trim().ToLowerInvariant()) {
        "idle"        { return [System.Diagnostics.ProcessPriorityClass]::Idle }
        "belownormal" { return [System.Diagnostics.ProcessPriorityClass]::BelowNormal }
        "normal"      { return [System.Diagnostics.ProcessPriorityClass]::Normal }
        "abovenormal" { return [System.Diagnostics.ProcessPriorityClass]::AboveNormal }
        "high"        { return [System.Diagnostics.ProcessPriorityClass]::High }
        default       { return $null }
    }
}

function Set-EngineProcessPriority {
    # Best-effort lowering (or raising) of a freshly-started engine process so a
    # long extraction does not starve interactive apps and downloads. Never
    # throws: a process that exits instantly can no longer be adjusted, which is
    # harmless.
    param([System.Diagnostics.Process]$Process)

    $priority = Get-EngineProcessPriorityClass
    if ($null -eq $priority) { return }

    try {
        $Process.PriorityClass = $priority
        # One log line per engine process would be very noisy (every password
        # attempt spawns one), so only record success under verbose logging.
        if ($VerboseEngineLogging) {
            Write-Log "Engine process priority set to $priority"
        }
    } catch {
        Write-Log "Could not set engine process priority to $priority : $($_.Exception.Message)" "WARN"
    }
}

function Invoke-ProcessLogged {
    param(
        [string]$Exe,
        [object[]]$ArgumentList,
        [string]$Operation,
        [bool]$ShowOutput = $false,
        [int]$TimeoutSeconds = 0,
        [bool]$CondenseOutput = $false
    )

    $argArray = @()
    foreach ($a in @($ArgumentList)) {
        if ($null -ne $a) {
            $argArray += [string]$a
        }
    }

    Write-Log "Operation: $Operation"
    Write-Log "Executable: $Exe"
    Write-Log ("Args: " + (Redact-ArgsForLog -ArgumentList $argArray))

    $output = @()
    $exitCode = -999

    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true

        $quotedArgs = @()
        foreach ($arg in $argArray) {
            $quotedArgs += (ConvertTo-WindowsCommandLineArg -Argument $arg)
        }
        $psi.Arguments = ($quotedArgs -join " ")

        $p = New-Object System.Diagnostics.Process
        $p.StartInfo = $psi

        [void]$p.Start()

        # Apply the configured priority immediately so heavy work (which starts
        # right away) runs at the chosen level rather than fighting for resources
        # at normal priority first.
        Set-EngineProcessPriority -Process $p

        $stdoutTask = $p.StandardOutput.ReadToEndAsync()
        $stderrTask = $p.StandardError.ReadToEndAsync()

        try { $p.StandardInput.Close() } catch {
            Write-Log "Could not close stdin: $($_.Exception.Message)" "WARN"
        }

        if ($TimeoutSeconds -gt 0) {
            $exited = $p.WaitForExit($TimeoutSeconds * 1000)

            if (-not $exited) {
                try { $p.Kill() } catch {
                    Write-Log "Could not kill timed-out process: $($_.Exception.Message)" "WARN"
                }
                $exitCode = -998
                $output = @("[TIMEOUT after ${TimeoutSeconds}s] Process timed out and was killed.")

                try {
                    if ($stdoutTask.Wait(3000)) {
                        $partialOut = $stdoutTask.Result
                        if ($partialOut) { $output += ($partialOut -split "`r?`n") }
                    }
                } catch {}
                try {
                    if ($stderrTask.Wait(3000)) {
                        $partialErr = $stderrTask.Result
                        if ($partialErr) { $output += ($partialErr -split "`r?`n") }
                    }
                } catch {}
            } else {
                $p.WaitForExit()
                $exitCode = $p.ExitCode
                $stdout = $stdoutTask.Result
                $stderr = $stderrTask.Result
                if ($stdout) { $output += ($stdout -split "`r?`n") }
                if ($stderr) { $output += ($stderr -split "`r?`n") }
            }
        } else {
            $p.WaitForExit()
            $exitCode = $p.ExitCode
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            if ($stdout) { $output += ($stdout -split "`r?`n") }
            if ($stderr) { $output += ($stderr -split "`r?`n") }
        }
    } catch {
        $exitCode = -999
        $output = @($_.Exception.ToString())
    }

    Write-Log "Exit code: $exitCode"

    if ($output -and @($output).Count -gt 0) {
        if ($CondenseOutput -and -not $VerboseEngineLogging) {
            $suppressPatterns = @("Wrong password", "Data Error", "CRC Failed", "Checksum error", "ERROR: Data Error", "ERROR: Wrong password")
            $suppressedCount = 0
            $suppressedType = ""
            $keptLines = @()

            foreach ($line in @($output)) {
                $text = [string]$line
                $suppressed = $false
                foreach ($pattern in $suppressPatterns) {
                    if ($text -match [regex]::Escape($pattern)) {
                        $suppressedCount++
                        if (-not $suppressedType) { $suppressedType = $pattern }
                        $suppressed = $true
                        break
                    }
                }
                if (-not $suppressed -and $text.Trim()) {
                    $keptLines += $text
                }
            }

            Write-Log "Output begin (condensed)"
            foreach ($kl in $keptLines) {
                Add-Content -LiteralPath $RunLogPath -Value $kl -Encoding UTF8
                if ($ShowOutput) { Write-Host $kl }
            }
            if ($suppressedCount -gt 0) {
                $summaryMsg = "[ENGINE] $suppressedType ($suppressedCount repetitive error lines suppressed)"
                Write-Log $summaryMsg
            }
            Write-Log "Output end"
        } else {
            Write-Log "Output begin"

            foreach ($line in @($output)) {
                $text = [string]$line
                Add-Content -LiteralPath $RunLogPath -Value $text -Encoding UTF8

                if ($ShowOutput -and $text.Trim()) {
                    Write-Host $text
                }
            }

            Write-Log "Output end"
        }
    } else {
        Write-Log "Output: <empty>"
    }

    return @{
        ExitCode = $exitCode
        Output = $output
    }
}
