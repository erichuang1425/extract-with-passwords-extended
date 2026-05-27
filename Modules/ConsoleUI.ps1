# ConsoleUI.ps1 — Console output formatting, progress bars, interactive menus, and notifications

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
    $displayText = $Text
    if ($displayText.Length -gt $pad) {
        $displayText = $displayText.Substring(0, $pad - 3) + "..."
    }
    $textPad = $pad - $displayText.Length
    $leftPad = [math]::Max(0, [math]::Floor($textPad / 2))
    $rightPad = [math]::Max(0, [math]::Ceiling($textPad / 2))

    Write-Host ""
    Write-Host ("+" + ("-" * ($width - 2)) + "+") -ForegroundColor DarkCyan
    Write-Host ("|" + (" " * $leftPad) + " " + $displayText + " " + (" " * $rightPad) + "|") -ForegroundColor Cyan
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
    $filled = [math]::Min($Width, [math]::Max(0, [math]::Floor(($Current / $Total) * $Width)))
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
    param([System.Diagnostics.Stopwatch]$sw)
    $e = $sw.Elapsed
    if ($e.TotalHours -ge 1) { return $e.ToString('hh\:mm\:ss') }
    if ($e.TotalMinutes -ge 1) { return $e.ToString('mm\:ss') }
    return "{0:N1}s" -f $e.TotalSeconds
}

function Format-ElapsedFromMs {
    param([long]$ms)
    $ts = [TimeSpan]::FromMilliseconds($ms)
    if ($ts.TotalHours -ge 1) { return $ts.ToString('hh\:mm\:ss') }
    if ($ts.TotalMinutes -ge 1) { return $ts.ToString('mm\:ss') }
    return "{0:N1}s" -f $ts.TotalSeconds
}

function Format-MaskedPassword {
    param([string]$Password)
    if ($Password.Length -le 4) { return ("*" * $Password.Length) }
    return ($Password.Substring(0, 2) + ("*" * ($Password.Length - 2)))
}

function Show-CompletionToast {
    param(
        [int]$Succeeded,
        [int]$Failed,
        [int]$Total
    )

    if (-not $ShowToastNotification) { return }
    if ($PSVersionTable.PSVersion.Major -lt 5) { return }

    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

        $template = @"
<toast>
  <visual>
    <binding template="ToastGeneric">
      <text>Archive Extractor</text>
      <text>Completed: $Succeeded/$Total succeeded$(if ($Failed -gt 0) { ", $Failed failed" })</text>
    </binding>
  </visual>
</toast>
"@

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml($template)
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("ArchivePwExtract").Show($toast)
    } catch {
        Write-Log "Toast notification failed: $($_.Exception.Message)" "WARN"
    }
}

function Show-InteractiveMenu {
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
    Write-Host "  [1] " -ForegroundColor Cyan -NoNewline; Write-Host "Browse for archive(s) to extract"
    Write-Host "  [2] " -ForegroundColor Cyan -NoNewline; Write-Host "Browse for folder to scan"
    Write-Host "  [3] " -ForegroundColor Cyan -NoNewline; Write-Host "Edit password list"
    Write-Host "  [4] " -ForegroundColor Cyan -NoNewline; Write-Host "Open settings (config.json)"
    Write-Host "  [5] " -ForegroundColor Cyan -NoNewline; Write-Host "View recent logs"
    Write-Host "  [6] " -ForegroundColor Cyan -NoNewline; Write-Host "Launch GUI mode"
    Write-Host "  [7] " -ForegroundColor Cyan -NoNewline; Write-Host "Exit"
    Write-Host ""

    while ($true) {
        Write-Host "  Select option (1-7): " -ForegroundColor Magenta -NoNewline
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
            "6" {
                return @("__GUI_MODE__")
            }
            "7" { exit 0 }
            default { Write-Host "  Please enter 1-7." -ForegroundColor Yellow }
        }
    }
}
