# Logging.psm1
# Logging subsystem for Archive Password-List Extractor.
#
# Provides timestamped log writing, dual console+file output,
# structured attempt summaries, argument redaction, and
# deadlock-safe external process execution with output capture.

# ---------------------------------------------------------------------------
# Module-scoped state
# ---------------------------------------------------------------------------
$script:RunLogPath = $null
$script:VerboseEngineLogging = $false

# ---------------------------------------------------------------------------
# Initialize-Logging
# ---------------------------------------------------------------------------
function Initialize-Logging {
    <#
    .SYNOPSIS
        Sets the module-scoped log path and verbose-logging flag.
    .PARAMETER LogPath
        Full path to the run log file.
    .PARAMETER VerboseEngine
        When $true, Invoke-ProcessLogged always writes full output
        regardless of the CondenseOutput parameter.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [bool]$VerboseEngine = $false
    )

    $script:RunLogPath = $LogPath
    $script:VerboseEngineLogging = $VerboseEngine
}

# ---------------------------------------------------------------------------
# Write-Log
# ---------------------------------------------------------------------------
function Write-Log {
    <#
    .SYNOPSIS
        Appends a single timestamped line to the run log.
    #>
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Write-Both
# ---------------------------------------------------------------------------
function Write-Both {
    <#
    .SYNOPSIS
        Writes to both the console (with optional colour) and the log file.
    #>
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

# ---------------------------------------------------------------------------
# Write-LogSummary
# ---------------------------------------------------------------------------
function Write-LogSummary {
    <#
    .SYNOPSIS
        Writes a structured one-liner for per-password-attempt summaries.
    .DESCRIPTION
        Format: [date] [ATTEMPT] [index/total] result | Engine: name | Exit: code | duration
    .PARAMETER Index
        Current attempt number (1-based).
    .PARAMETER Total
        Total number of attempts planned.
    .PARAMETER Result
        Short result string (e.g. "SUCCESS", "WRONG_PASSWORD", "ERROR").
    .PARAMETER EngineName
        Name of the extraction engine used (e.g. "7-Zip", "WinRAR").
    .PARAMETER ExitCode
        Process exit code returned by the engine.
    .PARAMETER Duration
        Human-readable duration string (e.g. "1.23s", "0:02:15").
    #>
    param(
        [int]$Index,
        [int]$Total,
        [string]$Result,
        [string]$EngineName,
        [int]$ExitCode,
        [string]$Duration
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[{0}] [ATTEMPT] [{1}/{2}] {3} | Engine: {4} | Exit: {5} | {6}" -f `
        $timestamp, $Index, $Total, $Result, $EngineName, $ExitCode, $Duration
    Add-Content -LiteralPath $script:RunLogPath -Value $line -Encoding UTF8
}

# ---------------------------------------------------------------------------
# Redact-ArgsForLog
# ---------------------------------------------------------------------------
function Redact-ArgsForLog {
    <#
    .SYNOPSIS
        Sanitises -p / -hp password arguments, replacing values with ********.
    #>
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

# ---------------------------------------------------------------------------
# ConvertTo-WindowsCommandLineArg
# ---------------------------------------------------------------------------
function ConvertTo-WindowsCommandLineArg {
    param([AllowNull()][string]$Argument)
    if ($null -eq $Argument) { return '""' }
    if ($Argument -eq '') { return '""' }
    if ($Argument -notmatch '[ \t"\\]') { return $Argument }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $nBackslash = 0
    foreach ($c in $Argument.ToCharArray()) {
        if ($c -eq '\') { $nBackslash++; continue }
        if ($c -eq '"') {
            [void]$sb.Append('\', ($nBackslash * 2 + 1)); $nBackslash = 0; [void]$sb.Append('"')
        } else {
            if ($nBackslash -gt 0) { [void]$sb.Append('\', $nBackslash); $nBackslash = 0 }
            [void]$sb.Append($c)
        }
    }
    if ($nBackslash -gt 0) { [void]$sb.Append('\', $nBackslash * 2) }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Invoke-ProcessLogged
# ---------------------------------------------------------------------------
function Invoke-ProcessLogged {
    <#
    .SYNOPSIS
        Runs an external process, captures stdout/stderr, and logs output.
    .DESCRIPTION
        When CondenseOutput is $true and VerboseEngineLogging is $false,
        repetitive error patterns (Wrong password, Data Error, CRC Failed,
        Checksum error) are collapsed into a single summary line instead
        of logging each line individually.  Full output is always returned
        in the result hashtable for callers.
    #>
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
        if ($null -ne $a) { $argArray += [string]$a }
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
        if ($CondenseOutput -and -not $script:VerboseEngineLogging) {
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
                Add-Content -LiteralPath $script:RunLogPath -Value $kl -Encoding UTF8
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
                Add-Content -LiteralPath $script:RunLogPath -Value $text -Encoding UTF8
                if ($ShowOutput -and $text.Trim()) { Write-Host $text }
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

# ---------------------------------------------------------------------------
# Exports
# ---------------------------------------------------------------------------
Export-ModuleMember -Function Initialize-Logging, Write-Log, Write-Both, Write-LogSummary, Redact-ArgsForLog, Invoke-ProcessLogged, ConvertTo-WindowsCommandLineArg
