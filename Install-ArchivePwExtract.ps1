# Install-ArchivePwExtract.ps1
# Multi-engine installer for Archive Password-List Extractor.
#
# Features:
# - Robust Windows command-line argument quoting, including trailing backslashes.
# - Deadlock-safe stdout/stderr reading for 7-Zip / WinRAR / UnRAR.
# - WinRAR.exe can be used as fallback for ZIP/7z/etc.; UnRAR.exe stays RAR-only.
# - 7-Zip password tests only treat exit code 0 as a verified password.
# - Warning exit code 1 only counts as extraction success when new files appeared.
# - Shared output cleanup no longer deletes earlier successful batch output.
# - Format-aware password testing: non-encryption formats skip password cycling.
# - Dynamic user paths (no hardcoded user profile).
# - Masked password console display with clipboard auto-clear.
# - Persistent password cache and session-local password reordering.
# - External JSON configuration file support.
# - Header-based encryption detection for encryption-capable formats.
# - Test-only-then-extract optimization for faster password cycling.
# - ETA and time remaining reporting during password testing.
# - Interactive browse interface when launched without arguments.
# - Toast notifications on batch completion.
# - Large archive strategies with multi-volume validation.
# - Custom export path options.
#
# Password file (default):
# <Documents>\ArchivePwExtract\passwords.txt

$ErrorActionPreference = "Stop"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host "PowerShell 3.0 or later is required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$ToolDir = Join-Path $env:LOCALAPPDATA "ArchivePwExtract"
$LogDir = Join-Path $ToolDir "Logs"
$_docs = [Environment]::GetFolderPath("MyDocuments")
if ([string]::IsNullOrEmpty($_docs)) { $_docs = Join-Path $env:USERPROFILE "Documents" }
$PwDir = Join-Path $_docs "ArchivePwExtract"
$PwFile = Join-Path $PwDir "passwords.txt"
$HelperPath = Join-Path $ToolDir "TryPwExtract.ps1"
$UninstallPath = Join-Path $ToolDir "Uninstall-ArchivePwExtract.ps1"
$ConfigPath = Join-Path $ToolDir "config.json"

New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path $PwDir | Out-Null

if (!(Test-Path -LiteralPath $PwFile)) {
@"
# Put one password per line.
# Lines starting with # are ignored.
#
# No-password archives are tested automatically first.
#
# Example:
# mypassword
# password123
# gamezip2024

"@ | Set-Content -LiteralPath $PwFile -Encoding UTF8
}

# Generate default config.json if not present
if (!(Test-Path -LiteralPath $ConfigPath)) {
@"
{
    "tryNoPasswordFirst": true,
    "askBeforeExtracting": true,
    "askSeparateFolders": true,
    "defaultSeparateFolders": true,
    "existingOutputBehavior": "replace",
    "sevenZipOverwriteMode": "aoa",
    "winRarOverwriteMode": "-o+",
    "useSevenZip": true,
    "useWinRarFallback": true,
    "usePeaZipBundled7zFallback": true,
    "tryExtractEvenIfTestFails": true,
    "cleanFailedAttemptOutput": true,
    "showPasswordInConsole": false,
    "clearClipboardOnExit": true,
    "openOutputAfterSuccess": true,
    "alwaysShowFinalConfirmation": true,
    "extractionTimeoutSeconds": 300,
    "logRetentionDays": 30,
    "usePasswordCache": true,
    "passwordCacheRetentionDays": 90,
    "loadAllPasswordFiles": false,
    "checkEncryptionBeforeCycling": true,
    "testOnlyFirst": true,
    "defaultOutputDirectory": "",
    "alwaysAskOutputDirectory": false,
    "showToastNotification": true,
    "largeArchiveThresholdMB": 500,
    "skipTestExtractFallbackForLargeArchives": true
}
"@ | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

$HelperScript = @'
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

# ============================================================
# Default configuration
# ============================================================

$TryNoPasswordFirst = $true
$AskBeforeExtracting = $true
$AskSeparateFolders = $true
$DefaultSeparateFolders = $true

$ExistingOutputBehavior = "replace"

$SevenZipOverwriteMode = "aoa"
$WinRarOverwriteMode = "-o+"

$UseSevenZip = $true
$UseWinRarFallback = $true
$UsePeaZipBundled7zFallback = $true

$TryExtractEvenIfTestFails = $true
$CleanFailedAttemptOutput = $true

$ShowPasswordInConsole = $false
$ClearClipboardOnExit = $true

$OpenOutputAfterSuccess = $true
$AlwaysShowFinalConfirmation = $true

$ExtractionTimeoutSeconds = 300
$LogRetentionDays = 30

$UsePasswordCache = $true
$PasswordCacheRetentionDays = 90
$LoadAllPasswordFiles = $false
$CheckEncryptionBeforeCycling = $true
$TestOnlyFirst = $true
$DefaultOutputDirectory = ""
$AlwaysAskOutputDirectory = $false
$ShowToastNotification = $true
$LargeArchiveThresholdMB = 500
$SkipTestExtractFallbackForLargeArchives = $true

$EncryptionCapableExtensions = @{
    '.zip' = $true; '.zipx' = $true; '.7z' = $true; '.rar' = $true
}

$lastCopiedPassword = $null
$lastSuccessfulPassword = $null

# ============================================================
# Load external configuration (overrides defaults)
# ============================================================

function Read-Config {
    if (!(Test-Path -LiteralPath $ConfigFile)) { return }

    try {
        $json = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 -ErrorAction Stop
        $cfg = $json | ConvertFrom-Json

        $map = @{
            "tryNoPasswordFirst" = "TryNoPasswordFirst"
            "askBeforeExtracting" = "AskBeforeExtracting"
            "askSeparateFolders" = "AskSeparateFolders"
            "defaultSeparateFolders" = "DefaultSeparateFolders"
            "existingOutputBehavior" = "ExistingOutputBehavior"
            "sevenZipOverwriteMode" = "SevenZipOverwriteMode"
            "winRarOverwriteMode" = "WinRarOverwriteMode"
            "useSevenZip" = "UseSevenZip"
            "useWinRarFallback" = "UseWinRarFallback"
            "usePeaZipBundled7zFallback" = "UsePeaZipBundled7zFallback"
            "tryExtractEvenIfTestFails" = "TryExtractEvenIfTestFails"
            "cleanFailedAttemptOutput" = "CleanFailedAttemptOutput"
            "showPasswordInConsole" = "ShowPasswordInConsole"
            "clearClipboardOnExit" = "ClearClipboardOnExit"
            "openOutputAfterSuccess" = "OpenOutputAfterSuccess"
            "alwaysShowFinalConfirmation" = "AlwaysShowFinalConfirmation"
            "extractionTimeoutSeconds" = "ExtractionTimeoutSeconds"
            "logRetentionDays" = "LogRetentionDays"
            "usePasswordCache" = "UsePasswordCache"
            "passwordCacheRetentionDays" = "PasswordCacheRetentionDays"
            "loadAllPasswordFiles" = "LoadAllPasswordFiles"
            "checkEncryptionBeforeCycling" = "CheckEncryptionBeforeCycling"
            "testOnlyFirst" = "TestOnlyFirst"
            "defaultOutputDirectory" = "DefaultOutputDirectory"
            "alwaysAskOutputDirectory" = "AlwaysAskOutputDirectory"
            "showToastNotification" = "ShowToastNotification"
            "largeArchiveThresholdMB" = "LargeArchiveThresholdMB"
            "skipTestExtractFallbackForLargeArchives" = "SkipTestExtractFallbackForLargeArchives"
        }

        foreach ($jsonKey in $map.Keys) {
            $varName = $map[$jsonKey]
            $val = $cfg.PSObject.Properties[$jsonKey]
            if ($null -ne $val) {
                Set-Variable -Name $varName -Value $val.Value -Scope 1
            }
        }
    } catch {
        Write-Host "[!] Could not load config.json: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

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

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"), $Level, $Message
    Add-Content -LiteralPath $RunLogPath -Value $line -Encoding UTF8
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

    if ($Argument.Length -eq 0) {
        return '""'
    }

    if ($Argument -notmatch '[\s"]') {
        return $Argument
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')

    $backslashes = 0

    for ($i = 0; $i -lt $Argument.Length; $i++) {
        $ch = $Argument[$i]

        if ($ch -eq '\') {
            $backslashes++
            continue
        }

        if ($ch -eq '"') {
            if ($backslashes -gt 0) {
                [void]$sb.Append(('\' * (($backslashes * 2) + 1)))
                $backslashes = 0
            } else {
                [void]$sb.Append('\')
            }

            [void]$sb.Append('"')
            continue
        }

        if ($backslashes -gt 0) {
            [void]$sb.Append(('\' * $backslashes))
            $backslashes = 0
        }

        [void]$sb.Append($ch)
    }

    if ($backslashes -gt 0) {
        [void]$sb.Append(('\' * ($backslashes * 2)))
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

function Invoke-ProcessLogged {
    param(
        [string]$Exe,
        [object[]]$ArgumentList,
        [string]$Operation,
        [bool]$ShowOutput = $false,
        [int]$TimeoutSeconds = 0
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

                # Harvest partial output from async tasks
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
        Write-Log "Output begin"

        foreach ($line in @($output)) {
            $text = [string]$line
            Add-Content -LiteralPath $RunLogPath -Value $text -Encoding UTF8

            if ($ShowOutput -and $text.Trim()) {
                Write-Host $text
            }
        }

        Write-Log "Output end"
    } else {
        Write-Log "Output: <empty>"
    }

    return @{
        ExitCode = $exitCode
        Output = $output
    }
}

function Pause-Close {
    Write-Host ""
    Write-Host "    Log: " -ForegroundColor DarkGray -NoNewline
    Write-Host $RunLogPath
    Write-Host ""
    Read-Host "    Press Enter to close"
}

function Write-Section {
    param([string]$Text)

    $width = 60
    $pad = $width - 4
    $textPad = $pad - $Text.Length
    $leftPad = [math]::Floor($textPad / 2)
    $rightPad = [math]::Ceiling($textPad / 2)

    Write-Host ""
    Write-Host ("+" + ("-" * ($width - 2)) + "+") -ForegroundColor DarkCyan
    Write-Host ("|" + (" " * $leftPad) + " " + $Text + " " + (" " * $rightPad) + "|") -ForegroundColor Cyan
    Write-Host ("+" + ("-" * ($width - 2)) + "+") -ForegroundColor DarkCyan

    Write-Log "============================================================"
    Write-Log $Text
    Write-Log "============================================================"
}

function Read-YesNo {
    param(
        [string]$Question,
        [bool]$DefaultYes = $true
    )

    if ($DefaultYes) {
        $suffix = " [Y/n]"
    } else {
        $suffix = " [y/N]"
    }

    while ($true) {
        Write-Host "[?] " -ForegroundColor Magenta -NoNewline
        $answer = Read-Host "$Question$suffix"
        Write-Log "Prompt: $Question$suffix Answer: $answer"

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch ($answer.Trim().ToLowerInvariant()) {
            "y" { return $true }
            "yes" { return $true }
            "n" { return $false }
            "no" { return $false }
            default { Write-Host "    Please type Y or N." -ForegroundColor Yellow }
        }
    }
}

function Write-Status {
    param(
        [string]$Message,
        [string]$Type = "info"
    )

    switch ($Type) {
        "success" { Write-Host "[+] " -ForegroundColor Green -NoNewline; Write-Host $Message -ForegroundColor Green }
        "fail"    { Write-Host "[-] " -ForegroundColor Red -NoNewline; Write-Host $Message -ForegroundColor Red }
        "warn"    { Write-Host "[!] " -ForegroundColor Yellow -NoNewline; Write-Host $Message -ForegroundColor Yellow }
        "info"    { Write-Host "[*] " -ForegroundColor Cyan -NoNewline; Write-Host $Message }
        "dim"     { Write-Host "    " -NoNewline; Write-Host $Message -ForegroundColor DarkGray }
        default   { Write-Host "    " -NoNewline; Write-Host $Message }
    }
}

function Write-ProgressBar {
    param(
        [int]$Current,
        [int]$Total,
        [int]$Width = 30,
        [long]$ElapsedMs = 0
    )

    if ($Total -le 0) { return }
    $pct = [math]::Min(100, [math]::Floor(($Current / $Total) * 100))
    $filled = [math]::Floor(($Current / $Total) * $Width)
    $empty = $Width - $filled
    $bar = ("=" * $filled) + ("-" * $empty)

    $etaStr = ""
    if ($ElapsedMs -gt 0 -and $Current -gt 0 -and $Current -lt $Total) {
        $avgMs = $ElapsedMs / $Current
        $remainMs = $avgMs * ($Total - $Current)
        $remainSec = [math]::Ceiling($remainMs / 1000)
        if ($remainSec -ge 60) {
            $etaStr = " ~{0}m {1}s left" -f [math]::Floor($remainSec / 60), ($remainSec % 60)
        } else {
            $etaStr = " ~${remainSec}s left"
        }
    }

    Write-Host "`r    [$bar] $pct% ($Current/$Total)$etaStr    " -NoNewline
}

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
# Engine detection
# ============================================================

function Find-FirstExistingPath {
    param([string[]]$Candidates)

    foreach ($path in $Candidates) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            return $path
        }
    }

    return $null
}

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

# ============================================================
# Archive detection
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

    foreach ($ext in $EncryptionCapableExtensions.Keys) {
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
# Passwords
# ============================================================

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
            # Format: timestamp|password
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

        # Prune expired entries
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
    if ([string]::IsNullOrEmpty($Password)) { return }

    try {
        $existing = @()
        if (Test-Path -LiteralPath $CacheFile) {
            $existing = @(Get-Content -LiteralPath $CacheFile -Encoding UTF8 -ErrorAction SilentlyContinue)
        }

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

    # Load cached passwords first (most recently successful)
    $cached = @(Get-CachedPasswords)
    if ($cached.Count -gt 0) {
        Write-Log "Cached passwords loaded: $($cached.Count)"
        $list += $cached
    }

    if ($TryNoPasswordFirst) {
        $list += ""
    }

    # Load from primary password file
    if (!(Test-Path -LiteralPath $PwFile)) {
        New-Item -ItemType File -Force -Path $PwFile | Out-Null
    }

    $filesToLoad = @($PwFile)

    # Load all .txt files from password directory if enabled
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

# ============================================================
# Encryption header inspection
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
# Engine operations
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

    $result = Invoke-ProcessLogged -Exe $SevenZip -ArgumentList $argumentList -Operation "7Z TEST" -ShowOutput $false -TimeoutSeconds $Timeout
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

    $result = Invoke-ProcessLogged -Exe $RarExe -ArgumentList $argumentList -Operation "WINRAR/UNRAR TEST" -ShowOutput $false -TimeoutSeconds $Timeout
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
    $shouldTryExtract = (-not $TestOnly) -and ($testOk -or $TryExtractEvenIfTestFails)

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

    $candidates = @()

    if ($UseSevenZip -and $SevenZip) {
        $candidates += [pscustomobject]@{ Name = "7-Zip"; Path = $SevenZip }
    }

    if ($UseWinRarFallback -and $WinRar) {
        if ($isRar) {
            $candidates += [pscustomobject]@{ Name = $winRarName; Path = $WinRar }
        } elseif ($winRarIsUniversal) {
            $candidates += [pscustomobject]@{ Name = $winRarName; Path = $WinRar }
        } else {
            Write-Log "UnRAR detected but skipped for non-RAR archive: $Archive" "INFO"
        }
    }

    if ($UsePeaZipBundled7zFallback -and $PeaZip7z) {
        if (-not $SevenZip -or ($PeaZip7z -ne $SevenZip)) {
            $candidates += [pscustomobject]@{ Name = "PeaZip bundled 7z"; Path = $PeaZip7z }
        }
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate.Path) {
            continue
        }

        $key = ([string]$candidate.Path).ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $plan += $candidate
        }
    }

    return @($plan)
}

# ============================================================
# Toast notification
# ============================================================

function Show-CompletionToast {
    param(
        [int]$Succeeded,
        [int]$Failed,
        [int]$Total
    )

    if (-not $ShowToastNotification) { return }
    if ($PSVersionTable.PSVersion.Major -lt 5) { return }

    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] | Out-Null

        $status = if ($Failed -eq 0) { "All $Total archive(s) extracted successfully." } else { "$Succeeded/$Total succeeded, $Failed failed." }
        $xml = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Archive Extraction Complete</text>
      <text>$status</text>
    </binding>
  </visual>
</toast>
"@
        $toastXml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $toastXml.LoadXml($xml)

        $appId = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
        $toast = New-Object Windows.UI.Notifications.ToastNotification $toastXml
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
        Write-Log "Toast notification displayed."
    } catch {
        Write-Log "Toast notification unavailable: $($_.Exception.Message)" "WARN"
    }
}

# ============================================================
# Interactive browse menu
# ============================================================

function Show-InteractiveMenu {
    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "     Archive Password-List Extractor" -ForegroundColor White -NoNewline
    Write-Host "               |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "         Multi-Engine  |  v3.0" -ForegroundColor DarkGray -NoNewline
    Write-Host "                      |" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline; Write-Host "Browse for archive(s) to extract"
    Write-Host "  [2] " -ForegroundColor Cyan -NoNewline; Write-Host "Browse for folder to scan"
    Write-Host "  [3] " -ForegroundColor Cyan -NoNewline; Write-Host "Edit password list"
    Write-Host "  [4] " -ForegroundColor Cyan -NoNewline; Write-Host "Open settings (config.json)"
    Write-Host "  [5] " -ForegroundColor Cyan -NoNewline; Write-Host "View recent logs"
    Write-Host "  [6] " -ForegroundColor Cyan -NoNewline; Write-Host "Exit"
    Write-Host ""

    while ($true) {
        Write-Host "  Select option (1-6): " -ForegroundColor Magenta -NoNewline
        $choice = Read-Host

        switch ($choice.Trim()) {
            "1" {
                try {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                    $dlg = New-Object System.Windows.Forms.OpenFileDialog
                    $dlg.Title = "Select archive(s) to extract"
                    $dlg.Filter = "Archive files|*.zip;*.zipx;*.7z;*.rar;*.001;*.tar;*.gz;*.tgz;*.bz2;*.tbz2;*.xz;*.txz;*.zst;*.tzst;*.cab;*.iso;*.wim;*.img;*.dmg|All files|*.*"
                    $dlg.Multiselect = $true
                    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        return @($dlg.FileNames)
                    }
                    Write-Host "  No files selected." -ForegroundColor DarkGray
                } catch {
                    Write-Host "  File dialog unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            "2" {
                try {
                    Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
                    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
                    $dlg.Description = "Select folder to scan for archives"
                    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
                        return @($dlg.SelectedPath)
                    }
                    Write-Host "  No folder selected." -ForegroundColor DarkGray
                } catch {
                    Write-Host "  Folder dialog unavailable: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            "3" {
                Start-Process notepad.exe -ArgumentList $PwFile
                Write-Host "  Opened password list in Notepad." -ForegroundColor DarkGray
            }
            "4" {
                if (Test-Path -LiteralPath $ConfigFile) {
                    Start-Process notepad.exe -ArgumentList $ConfigFile
                    Write-Host "  Opened config.json in Notepad." -ForegroundColor DarkGray
                } else {
                    Write-Host "  No config.json found at $ConfigFile" -ForegroundColor Yellow
                }
            }
            "5" {
                $logs = Get-ChildItem -LiteralPath $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending | Select-Object -First 10
                if ($logs.Count -eq 0) {
                    Write-Host "  No log files found." -ForegroundColor DarkGray
                } else {
                    Write-Host ""
                    Write-Host "  Recent logs:" -ForegroundColor White
                    $idx = 0
                    foreach ($log in $logs) {
                        $idx++
                        Write-Host "    [$idx] " -ForegroundColor DarkCyan -NoNewline
                        Write-Host "$($log.Name)" -NoNewline
                        Write-Host " ($([math]::Round($log.Length / 1KB, 1)) KB)" -ForegroundColor DarkGray
                    }
                    Write-Host ""
                    Write-Host "  Open log # (or Enter to go back): " -ForegroundColor Magenta -NoNewline
                    $logChoice = Read-Host
                    if ($logChoice -match '^\d+$') {
                        $logIdx = [int]$logChoice - 1
                        if ($logIdx -ge 0 -and $logIdx -lt $logs.Count) {
                            Start-Process notepad.exe -ArgumentList $logs[$logIdx].FullName
                        }
                    }
                }
            }
            "6" { exit 0 }
            default { Write-Host "  Please enter 1-6." -ForegroundColor Yellow }
        }
    }
}

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

    foreach ($p in $InputPaths) {
        Write-Log "Input: $p"
    }

    Write-Log "============================================================"

    # Interactive browse menu when launched without arguments
    if (!$InputPaths -or $InputPaths.Count -eq 0) {
        $selectedPaths = Show-InteractiveMenu
        if ($selectedPaths -and $selectedPaths.Count -gt 0) {
            $InputPaths = $selectedPaths
        } else {
            exit 0
        }
    }

    Write-Host ""
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "     Archive Password-List Extractor" -ForegroundColor White -NoNewline
    Write-Host "               |" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "         Multi-Engine  |  v3.0" -ForegroundColor DarkGray -NoNewline
    Write-Host "                      |" -ForegroundColor DarkCyan
    Write-Host "  |                                                      |" -ForegroundColor DarkCyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host ""
    Write-Log "Archive password-list extractor - multi engine v3.0"
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

        # Show batch progress
        if ($Archives.Count -gt 1) {
            $batchElapsed = Format-ElapsedFromMs $totalStopwatch.ElapsedMilliseconds
            Write-Status "Archive $ArchiveIndex/$($Archives.Count)  |  Overall elapsed: $batchElapsed" "dim"
        }

        Write-Both "" "INFO"

        # Check file accessibility
        if (-not (Test-FileAccessible $Archive)) {
            Write-Status "Archive is locked by another process or inaccessible." "fail"
            Write-Log "Archive locked or inaccessible: $Archive" "ERROR"
            $Failed += $Archive
            continue
        }

        # Large archive detection
        $archiveSizeMB = 0
        try {
            $fi = Get-Item -LiteralPath $Archive -ErrorAction SilentlyContinue
            if ($fi) { $archiveSizeMB = [math]::Round($fi.Length / 1MB, 1) }
        } catch {}

        $isLargeArchive = ($archiveSizeMB -ge $LargeArchiveThresholdMB)
        if ($isLargeArchive) {
            Write-Status "Large archive ($(Format-FileSize ($archiveSizeMB * 1MB))) — password testing may be slow" "warn"
            Write-Log "Large archive detected: ${archiveSizeMB} MB" "WARN"
        }

        # Multi-volume validation
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

        # Header-based encryption detection for encryption-capable formats
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

        # Determine if we should use test-only-then-extract
        $useTestOnly = $TestOnlyFirst -or ($isLargeArchive -and $SkipTestExtractFallbackForLargeArchives)
        $winningPassword = $null
        $winningEngine = $null

        if ($useTestOnly) {
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
        } else {
            # Original full test+extract per password
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

    # Toast notification
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
'@

Set-Content -LiteralPath $HelperPath -Value $HelperScript -Encoding UTF8

# ============================================================
# Shared extension list for context menus and uninstaller
# ============================================================

$ArchiveExtensions = @(
    ".zip",
    ".zipx",
    ".7z",
    ".rar",
    ".001",
    ".tar",
    ".gz",
    ".tgz",
    ".bz2",
    ".tbz2",
    ".xz",
    ".txz",
    ".zst",
    ".tzst",
    ".cab",
    ".iso",
    ".wim",
    ".img",
    ".dmg"
)

# ============================================================
# Uninstaller
# ============================================================

$extArrayString = ($ArchiveExtensions | ForEach-Object { "    `"$_`"" }) -join ",`n"

$UninstallScript = @"
`$ErrorActionPreference = "SilentlyContinue"

`$archiveExtensions = @(
$extArrayString
)

foreach (`$ext in `$archiveExtensions) {
    Remove-Item -Path "HKCU:\Software\Classes\SystemFileAssociations\`$ext\shell\ArchivePwExtract" -Recurse -Force
}

Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolder" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHere" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditPasswords" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditConfig" -Recurse -Force

# Undo Windows 11 classic context menu restoration if it was set
`$classicMenuKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
if (Test-Path -Path `$classicMenuKey) {
    `$undoClassic = Read-Host "Remove classic context menu restoration (Windows 11)? [y/N]"
    if (`$undoClassic -match '^[yY]') {
        Remove-Item -Path "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}" -Recurse -Force
        Write-Host "Classic context menu restoration removed. Restart Explorer to apply." -ForegroundColor Yellow
    }
}

`$sendTo = [Environment]::GetFolderPath("SendTo")
Remove-Item -Path (Join-Path `$sendTo "Archive password-list extract.lnk") -Force

Write-Host ""
Write-Host "Removed right-click and Send To menu entries." -ForegroundColor Green
Write-Host ""
Write-Host "Your password file was NOT deleted:"
`$_docs = [Environment]::GetFolderPath("MyDocuments")
if ([string]::IsNullOrEmpty(`$_docs)) { `$_docs = Join-Path `$env:USERPROFILE "Documents" }
Write-Host (Join-Path (Join-Path `$_docs "ArchivePwExtract") "passwords.txt")
Write-Host ""
Write-Host "Config file was NOT deleted:"
Write-Host (Join-Path `$env:LOCALAPPDATA "ArchivePwExtract\config.json")
Write-Host ""
Write-Host "Helper folder was NOT deleted:"
Write-Host "`$env:LOCALAPPDATA\ArchivePwExtract"
Write-Host ""
Read-Host "Press Enter to close"
"@

Set-Content -LiteralPath $UninstallPath -Value $UninstallScript -Encoding UTF8

# ============================================================
# Context menus with robust error handling
# ============================================================

$registeredCount = 0
$failedExtensions = @()
$totalExtensions = $ArchiveExtensions.Count

foreach ($Ext in $ArchiveExtensions) {
    try {
        $MenuPath = "HKCU:\Software\Classes\SystemFileAssociations\$Ext\shell\ArchivePwExtract"
        $CommandPath = "$MenuPath\command"

        New-Item -Path $MenuPath -Force | Out-Null
        New-Item -Path $CommandPath -Force | Out-Null

        Set-ItemProperty -Path $MenuPath -Name "(default)" -Value "Try password list and extract"
        Set-ItemProperty -Path $MenuPath -Name "MUIVerb" -Value "Try password list and extract"
        Set-ItemProperty -Path $MenuPath -Name "Icon" -Value "powershell.exe"

        $Command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%1`""
        Set-ItemProperty -Path $CommandPath -Name "(default)" -Value $Command

        $registeredCount++
    } catch {
        $failedExtensions += $Ext
        Write-Host "  Warning: Failed to register context menu for $Ext : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$folderMenuOk = $true
try {
    $FolderMenuPath = "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolder"
    $FolderCommandPath = "$FolderMenuPath\command"

    New-Item -Path $FolderMenuPath -Force | Out-Null
    New-Item -Path $FolderCommandPath -Force | Out-Null

    Set-ItemProperty -Path $FolderMenuPath -Name "(default)" -Value "Extract archives with password list"
    Set-ItemProperty -Path $FolderMenuPath -Name "MUIVerb" -Value "Extract archives with password list"
    Set-ItemProperty -Path $FolderMenuPath -Name "Icon" -Value "powershell.exe"

    $FolderCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%1`""
    Set-ItemProperty -Path $FolderCommandPath -Name "(default)" -Value $FolderCommand
} catch {
    $folderMenuOk = $false
    Write-Host "  Warning: Failed to register folder context menu: $($_.Exception.Message)" -ForegroundColor Yellow
}

$backgroundMenuOk = $true
try {
    $BackgroundMenuPath = "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHere"
    $BackgroundCommandPath = "$BackgroundMenuPath\command"

    New-Item -Path $BackgroundMenuPath -Force | Out-Null
    New-Item -Path $BackgroundCommandPath -Force | Out-Null

    Set-ItemProperty -Path $BackgroundMenuPath -Name "(default)" -Value "Extract archives here with password list"
    Set-ItemProperty -Path $BackgroundMenuPath -Name "MUIVerb" -Value "Extract archives here with password list"
    Set-ItemProperty -Path $BackgroundMenuPath -Name "Icon" -Value "powershell.exe"

    $BackgroundCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%V`""
    Set-ItemProperty -Path $BackgroundCommandPath -Name "(default)" -Value $BackgroundCommand
} catch {
    $backgroundMenuOk = $false
    Write-Host "  Warning: Failed to register background context menu: $($_.Exception.Message)" -ForegroundColor Yellow
}

$editMenuOk = $true
try {
    $EditMenuPath = "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditPasswords"
    $EditCommandPath = "$EditMenuPath\command"

    New-Item -Path $EditMenuPath -Force | Out-Null
    New-Item -Path $EditCommandPath -Force | Out-Null

    Set-ItemProperty -Path $EditMenuPath -Name "(default)" -Value "Edit archive password list"
    Set-ItemProperty -Path $EditMenuPath -Name "MUIVerb" -Value "Edit archive password list"
    Set-ItemProperty -Path $EditMenuPath -Name "Icon" -Value "notepad.exe"

    $EditCommand = "notepad.exe `"$PwFile`""
    Set-ItemProperty -Path $EditCommandPath -Name "(default)" -Value $EditCommand
} catch {
    $editMenuOk = $false
    Write-Host "  Warning: Failed to register password edit context menu: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Config editor context menu entry
$configMenuOk = $true
try {
    $ConfigMenuPath = "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditConfig"
    $ConfigCommandPath = "$ConfigMenuPath\command"

    New-Item -Path $ConfigMenuPath -Force | Out-Null
    New-Item -Path $ConfigCommandPath -Force | Out-Null

    Set-ItemProperty -Path $ConfigMenuPath -Name "(default)" -Value "Edit archive extractor config"
    Set-ItemProperty -Path $ConfigMenuPath -Name "MUIVerb" -Value "Edit archive extractor config"
    Set-ItemProperty -Path $ConfigMenuPath -Name "Icon" -Value "notepad.exe"

    $ConfigCommand = "notepad.exe `"$ConfigPath`""
    Set-ItemProperty -Path $ConfigCommandPath -Name "(default)" -Value $ConfigCommand
} catch {
    $configMenuOk = $false
    Write-Host "  Warning: Failed to register config edit context menu: $($_.Exception.Message)" -ForegroundColor Yellow
}

$shortcutOk = $true
try {
    $SendToDir = [Environment]::GetFolderPath("SendTo")
    $ShortcutPath = Join-Path $SendToDir "Archive password-list extract.lnk"

    $WshShell = New-Object -ComObject WScript.Shell
    $Shortcut = $WshShell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = "powershell.exe"
    $Shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`""
    $Shortcut.WorkingDirectory = $ToolDir
    $Shortcut.IconLocation = "powershell.exe,0"
    $Shortcut.Save()
} catch {
    $shortcutOk = $false
    Write-Host "  Warning: Failed to create Send To shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Windows 11 classic context menu opt-in
$win11ClassicApplied = $false
try {
    $osBuild = [Environment]::OSVersion.Version.Build
    if ($osBuild -ge 22000) {
        $classicMenuKey = "HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32"
        if (!(Test-Path -Path $classicMenuKey)) {
            Write-Host ""
            Write-Host "  Windows 11 detected." -ForegroundColor Cyan
            Write-Host "  Context menu entries appear under 'Show more options' by default." -ForegroundColor DarkGray
            Write-Host "  You can restore the classic full right-click menu (system-wide)." -ForegroundColor DarkGray
            Write-Host ""

            $restoreClassic = Read-Host "  Restore classic right-click menu? (Can be undone via uninstaller) [y/N]"
            if ($restoreClassic -match '^[yY]') {
                New-Item -Path $classicMenuKey -Force | Out-Null
                Set-ItemProperty -Path $classicMenuKey -Name "(default)" -Value "" -Type String
                $win11ClassicApplied = $true
                Write-Host "  Classic context menu restored. Restart Explorer or log off/on to apply." -ForegroundColor Green
            }
        }
    }
} catch {
    Write-Host "  Note: Could not check/apply Windows 11 classic menu: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# Installation summary
$hasFailures = ($failedExtensions.Count -gt 0) -or (-not $folderMenuOk) -or (-not $backgroundMenuOk) -or (-not $editMenuOk) -or (-not $shortcutOk)

Write-Host ""
if ($hasFailures) {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |" -ForegroundColor Yellow -NoNewline
    Write-Host "           Installed with Warnings" -ForegroundColor Yellow -NoNewline
    Write-Host "                 |" -ForegroundColor Yellow
    Write-Host "  +------------------------------------------------------+" -ForegroundColor Yellow
} else {
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
    Write-Host "  |" -ForegroundColor DarkCyan -NoNewline
    Write-Host "              Installed Successfully" -ForegroundColor Green -NoNewline
    Write-Host "                |" -ForegroundColor DarkCyan
    Write-Host "  +------------------------------------------------------+" -ForegroundColor DarkCyan
}

Write-Host ""
Write-Host "  Registration summary:" -ForegroundColor Cyan
Write-Host "    File extensions: $registeredCount / $totalExtensions registered"
if ($failedExtensions.Count -gt 0) {
    Write-Host "    Failed: $($failedExtensions -join ', ')" -ForegroundColor Yellow
}
Write-Host "    Folder menu:    $(if ($folderMenuOk) { 'OK' } else { 'FAILED' })"
Write-Host "    Background menu:$(if ($backgroundMenuOk) { ' OK' } else { ' FAILED' })"
Write-Host "    Password edit:  $(if ($editMenuOk) { 'OK' } else { 'FAILED' })"
Write-Host "    Config edit:    $(if ($configMenuOk) { 'OK' } else { 'FAILED' })"
Write-Host "    Send To:        $(if ($shortcutOk) { 'OK' } else { 'FAILED' })"
if ($win11ClassicApplied) {
    Write-Host "    Win11 classic:  Applied (restart Explorer)" -ForegroundColor Green
}

Write-Host ""
Write-Host "  Engines (tried in order):" -ForegroundColor Cyan
Write-Host "    1. 7-Zip"
Write-Host "    2. WinRAR (all formats) / UnRAR (RAR only)"
Write-Host "    3. PeaZip bundled 7z"
Write-Host ""
Write-Host "  Key paths:" -ForegroundColor Cyan
Write-Host "    Passwords:  " -NoNewline; Write-Host $PwFile -ForegroundColor White
Write-Host "    Config:     " -NoNewline; Write-Host $ConfigPath -ForegroundColor White
Write-Host "    Logs:       " -NoNewline; Write-Host $LogDir -ForegroundColor White
Write-Host ""
Write-Host "  Notes:" -ForegroundColor Cyan
Write-Host "    - PeaZip's saved Password Manager cannot be read automatically."
Write-Host "    - Edit config.json to customize settings (survives reinstalls)."
if (-not $win11ClassicApplied) {
    Write-Host "    - On Windows 11, context menu entries appear under 'Show more options'."
}
Write-Host ""
Write-Host "  Opening password list..." -ForegroundColor DarkGray
Start-Process notepad.exe -ArgumentList $PwFile

Write-Host ""
Read-Host "  Press Enter to close"
