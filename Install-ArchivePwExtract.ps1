# Install-ArchivePwExtract.ps1
# Multi-engine installer for Archive Password-List Extractor.
#
# Features:
# - Modular architecture with separate .ps1 module files
# - WPF GUI mode with drag-and-drop, progress tracking, and live log viewer
# - Parallel archive processing and parallel password testing
# - Condensed logging that suppresses repetitive wrong-password errors
# - Robust Windows command-line argument quoting
# - Deadlock-safe stdout/stderr reading for 7-Zip / WinRAR / UnRAR
# - Format-aware password testing with header-based encryption detection
# - Test-only-then-extract optimization for faster password cycling
# - Password cache, session-local reordering, ETA reporting
# - Interactive browse interface and toast notifications
# - Large archive strategies with multi-volume validation
# - Error classification (wrong password vs corrupt vs timeout)
#
# Password file (default):
# <Documents>\ArchivePwExtract\passwords.txt

$ErrorActionPreference = "Stop"

# Keep in lockstep with $AppVersion in Modules/Config.ps1. The installer does not
# dot-source Config.ps1 at runtime, so it carries its own copy of the version.
$AppVersion = "4.1.1"

if ($PSVersionTable.PSVersion.Major -lt 3) {
    Write-Host "PowerShell 3.0 or later is required. Current: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    Read-Host "Press Enter to close"
    exit 1
}

$ToolDir = Join-Path $env:LOCALAPPDATA "ArchivePwExtract"
$ModulesInstallDir = Join-Path $ToolDir "Modules"
$ResourcesInstallDir = Join-Path $ToolDir "Resources"
$LogDir = Join-Path $ToolDir "Logs"
$_docs = [Environment]::GetFolderPath("MyDocuments")
if ([string]::IsNullOrEmpty($_docs)) { $_docs = Join-Path $env:USERPROFILE "Documents" }
$PwDir = Join-Path $_docs "ArchivePwExtract"
$PwFile = Join-Path $PwDir "passwords.txt"
$HelperPath = Join-Path $ToolDir "TryPwExtract.ps1"
$UninstallPath = Join-Path $ToolDir "Uninstall-ArchivePwExtract.ps1"
$ConfigPath = Join-Path $ToolDir "config.json"
$LaunchGuiVbs = Join-Path $ToolDir "LaunchGui.vbs"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
New-Item -ItemType Directory -Force -Path $ModulesInstallDir | Out-Null
New-Item -ItemType Directory -Force -Path $ResourcesInstallDir | Out-Null
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
    "skipTestExtractFallbackForLargeArchives": true,
    "verboseEngineLogging": false,
    "maxParallelArchives": 1,
    "maxParallelPasswords": 1,
    "maxArchivesPerScan": 0,
    "preferGui": false,
    "confirmGuiClose": true,
    "extractNestedArchives": false,
    "maxNestedDepth": 1,
    "deleteNestedArchiveAfterExtract": false,
    "askOutputBehavior": true,
    "postExtractionAction": "prompt",
    "postExtractionSilent": false,
    "preventSleepDuringExtraction": true,
    "engineProcessPriority": "BelowNormal",
    "folderNameRules": []
}
"@ | Set-Content -LiteralPath $ConfigPath -Encoding UTF8
}

# ============================================================
# Copy module files from distribution to install directory
# ============================================================

$sourceModulesDir = Join-Path $ScriptDir "Modules"
$sourceResourcesDir = Join-Path $ScriptDir "Resources"
$sourceHelperPath = Join-Path $ScriptDir "TryPwExtract.ps1"

$moduleFiles = @(
    "Config.ps1",
    "Logging.ps1",
    "ConsoleUI.ps1",
    "ArchiveUtils.ps1",
    "Extraction.ps1",
    "Passwords.ps1",
    "NestedExtraction.ps1",
    "Parallel.ps1",
    "PowerManagement.ps1",
    "WpfGui.ps1"
)

$copyErrors = @()

# Copy main orchestrator
try {
    if (Test-Path -LiteralPath $sourceHelperPath) {
        Copy-Item -LiteralPath $sourceHelperPath -Destination $HelperPath -Force
        Write-Host "  Copied TryPwExtract.ps1" -ForegroundColor DarkGray
    } else {
        throw "TryPwExtract.ps1 not found at $sourceHelperPath"
    }
} catch {
    $copyErrors += "TryPwExtract.ps1: $($_.Exception.Message)"
}

# Copy module files
foreach ($moduleFile in $moduleFiles) {
    $sourcePath = Join-Path $sourceModulesDir $moduleFile
    $destPath = Join-Path $ModulesInstallDir $moduleFile
    try {
        if (Test-Path -LiteralPath $sourcePath) {
            Copy-Item -LiteralPath $sourcePath -Destination $destPath -Force
            Write-Host "  Copied Modules\$moduleFile" -ForegroundColor DarkGray
        } else {
            throw "$moduleFile not found at $sourcePath"
        }
    } catch {
        $copyErrors += "$moduleFile`: $($_.Exception.Message)"
    }
}

# Copy resource files
$resourceFiles = Get-ChildItem -LiteralPath $sourceResourcesDir -File -ErrorAction SilentlyContinue
foreach ($resFile in $resourceFiles) {
    $destPath = Join-Path $ResourcesInstallDir $resFile.Name
    try {
        Copy-Item -LiteralPath $resFile.FullName -Destination $destPath -Force
        Write-Host "  Copied Resources\$($resFile.Name)" -ForegroundColor DarkGray
    } catch {
        $copyErrors += "$($resFile.Name): $($_.Exception.Message)"
    }
}

if ($copyErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Errors copying files:" -ForegroundColor Red
    foreach ($err in $copyErrors) {
        Write-Host "    - $err" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  Installation may be incomplete. Ensure you run the installer from the distribution folder." -ForegroundColor Yellow
    Write-Host ""
}

# ============================================================
# GUI launcher shim (no console window)
# ============================================================
# A windowless wscript shim launches the WPF GUI with PowerShell fully hidden, so
# the "...with password list" right-click entries open straight into the window
# with NO flashing console. The shim resolves TryPwExtract.ps1 relative to itself
# (both live in $ToolDir), so its body is static ASCII and copes with non-ASCII
# install paths at runtime instead of baking the path in.
$LaunchGuiContent = @'
' LaunchGui.vbs - opens the Archive Password Extractor GUI with no console window.
Option Explicit
Dim sh, fso, helper, ps, i
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
helper = fso.BuildPath(fso.GetParentFolderName(WScript.ScriptFullName), "TryPwExtract.ps1")
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & helper & """ -Gui"
For i = 0 To WScript.Arguments.Count - 1
    ps = ps & " """ & WScript.Arguments(i) & """"
Next
sh.Run ps, 0, False
'@

try {
    Set-Content -LiteralPath $LaunchGuiVbs -Value $LaunchGuiContent -Encoding ASCII
    Write-Host "  Created LaunchGui.vbs" -ForegroundColor DarkGray
} catch {
    $copyErrors += "LaunchGui.vbs: $($_.Exception.Message)"
}

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
    Remove-Item -Path "HKCU:\Software\Classes\SystemFileAssociations\`$ext\shell\ArchivePwExtractConsole" -Recurse -Force
    Remove-Item -Path "HKCU:\Software\Classes\SystemFileAssociations\`$ext\shell\ArchivePwExtractGui" -Recurse -Force
}

Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolder" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolderConsole" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolderGui" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHere" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHereConsole" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHereGui" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditPasswords" -Recurse -Force
Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwEditConfig" -Recurse -Force

Remove-Item -Path (Join-Path `$env:LOCALAPPDATA "ArchivePwExtract\LaunchGui.vbs") -Force

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
        # Primary entry: open the GUI with no console window (via the VBS shim).
        $MenuPath = "HKCU:\Software\Classes\SystemFileAssociations\$Ext\shell\ArchivePwExtract"
        $CommandPath = "$MenuPath\command"

        New-Item -Path $MenuPath -Force | Out-Null
        New-Item -Path $CommandPath -Force | Out-Null

        Set-ItemProperty -Path $MenuPath -Name "(default)" -Value "Extract with password list"
        Set-ItemProperty -Path $MenuPath -Name "MUIVerb" -Value "Extract with password list"
        Set-ItemProperty -Path $MenuPath -Name "Icon" -Value "powershell.exe"

        $GuiCommand = "wscript.exe `"$LaunchGuiVbs`" `"%1`""
        Set-ItemProperty -Path $CommandPath -Name "(default)" -Value $GuiCommand

        # Secondary entry: the text-mode console flow.
        $ConsoleMenuPath = "HKCU:\Software\Classes\SystemFileAssociations\$Ext\shell\ArchivePwExtractConsole"
        $ConsoleCommandPath = "$ConsoleMenuPath\command"

        New-Item -Path $ConsoleMenuPath -Force | Out-Null
        New-Item -Path $ConsoleCommandPath -Force | Out-Null

        Set-ItemProperty -Path $ConsoleMenuPath -Name "(default)" -Value "Extract in console (password list)"
        Set-ItemProperty -Path $ConsoleMenuPath -Name "MUIVerb" -Value "Extract in console (password list)"
        Set-ItemProperty -Path $ConsoleMenuPath -Name "Icon" -Value "powershell.exe"

        $ConsoleCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%1`""
        Set-ItemProperty -Path $ConsoleCommandPath -Name "(default)" -Value $ConsoleCommand

        # Remove the standalone "...Gui" entry shipped by an earlier build, if present.
        Remove-Item -Path "HKCU:\Software\Classes\SystemFileAssociations\$Ext\shell\ArchivePwExtractGui" -Recurse -Force -ErrorAction SilentlyContinue

        $registeredCount++
    } catch {
        $failedExtensions += $Ext
        Write-Host "  Warning: Failed to register context menu for $Ext : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

$folderMenuOk = $true
try {
    # Primary entry: open the GUI with no console window (via the VBS shim).
    $FolderMenuPath = "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolder"
    $FolderCommandPath = "$FolderMenuPath\command"

    New-Item -Path $FolderMenuPath -Force | Out-Null
    New-Item -Path $FolderCommandPath -Force | Out-Null

    Set-ItemProperty -Path $FolderMenuPath -Name "(default)" -Value "Extract archives with password list"
    Set-ItemProperty -Path $FolderMenuPath -Name "MUIVerb" -Value "Extract archives with password list"
    Set-ItemProperty -Path $FolderMenuPath -Name "Icon" -Value "powershell.exe"

    $FolderCommand = "wscript.exe `"$LaunchGuiVbs`" `"%1`""
    Set-ItemProperty -Path $FolderCommandPath -Name "(default)" -Value $FolderCommand

    # Secondary entry: the text-mode console flow for a right-clicked folder.
    $FolderConsoleMenuPath = "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolderConsole"
    $FolderConsoleCommandPath = "$FolderConsoleMenuPath\command"

    New-Item -Path $FolderConsoleMenuPath -Force | Out-Null
    New-Item -Path $FolderConsoleCommandPath -Force | Out-Null

    Set-ItemProperty -Path $FolderConsoleMenuPath -Name "(default)" -Value "Extract archives in console (list)"
    Set-ItemProperty -Path $FolderConsoleMenuPath -Name "MUIVerb" -Value "Extract archives in console (list)"
    Set-ItemProperty -Path $FolderConsoleMenuPath -Name "Icon" -Value "powershell.exe"

    $FolderConsoleCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%1`""
    Set-ItemProperty -Path $FolderConsoleCommandPath -Name "(default)" -Value $FolderConsoleCommand

    Remove-Item -Path "HKCU:\Software\Classes\Directory\shell\ArchivePwExtractFolderGui" -Recurse -Force -ErrorAction SilentlyContinue
} catch {
    $folderMenuOk = $false
    Write-Host "  Warning: Failed to register folder context menu: $($_.Exception.Message)" -ForegroundColor Yellow
}

$backgroundMenuOk = $true
try {
    # Primary entry: open the GUI with no console window (via the VBS shim).
    $BackgroundMenuPath = "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHere"
    $BackgroundCommandPath = "$BackgroundMenuPath\command"

    New-Item -Path $BackgroundMenuPath -Force | Out-Null
    New-Item -Path $BackgroundCommandPath -Force | Out-Null

    Set-ItemProperty -Path $BackgroundMenuPath -Name "(default)" -Value "Extract archives here with password list"
    Set-ItemProperty -Path $BackgroundMenuPath -Name "MUIVerb" -Value "Extract archives here with password list"
    Set-ItemProperty -Path $BackgroundMenuPath -Name "Icon" -Value "powershell.exe"

    $BackgroundCommand = "wscript.exe `"$LaunchGuiVbs`" `"%V`""
    Set-ItemProperty -Path $BackgroundCommandPath -Name "(default)" -Value $BackgroundCommand

    # Secondary entry: the text-mode console flow for the folder background.
    $BackgroundConsoleMenuPath = "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHereConsole"
    $BackgroundConsoleCommandPath = "$BackgroundConsoleMenuPath\command"

    New-Item -Path $BackgroundConsoleMenuPath -Force | Out-Null
    New-Item -Path $BackgroundConsoleCommandPath -Force | Out-Null

    Set-ItemProperty -Path $BackgroundConsoleMenuPath -Name "(default)" -Value "Extract here in console (list)"
    Set-ItemProperty -Path $BackgroundConsoleMenuPath -Name "MUIVerb" -Value "Extract here in console (list)"
    Set-ItemProperty -Path $BackgroundConsoleMenuPath -Name "Icon" -Value "powershell.exe"

    $BackgroundConsoleCommand = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$HelperPath`" `"%V`""
    Set-ItemProperty -Path $BackgroundConsoleCommandPath -Name "(default)" -Value $BackgroundConsoleCommand

    Remove-Item -Path "HKCU:\Software\Classes\Directory\Background\shell\ArchivePwExtractHereGui" -Recurse -Force -ErrorAction SilentlyContinue
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
$hasFailures = ($failedExtensions.Count -gt 0) -or (-not $folderMenuOk) -or (-not $backgroundMenuOk) -or (-not $editMenuOk) -or (-not $shortcutOk) -or ($copyErrors.Count -gt 0)

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
Write-Host "  Files installed:" -ForegroundColor Cyan
Write-Host "    Orchestrator:   $HelperPath"
Write-Host "    GUI launcher:   $LaunchGuiVbs"
Write-Host "    Modules:        $ModulesInstallDir ($($moduleFiles.Count) files)"
Write-Host "    Resources:      $ResourcesInstallDir"

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
Write-Host "  New in v$($AppVersion):" -ForegroundColor Cyan
Write-Host "    - Right-click 'Extract with password list' now opens the GUI directly"
Write-Host "      (no console window), with your selection already queued"
Write-Host "    - 'Extract in console (password list)' is the secondary, text-mode entry"
Write-Host "    - GUI closes with a confirmation prompt; failed launches no longer vanish"
Write-Host "    - Recursive nested-archive extraction (set extractNestedArchives: true)"
Write-Host "    - Parallel archive and password processing"
Write-Host "    - Condensed logging (no more per-file wrong-password spam)"
Write-Host "    - Error classification (wrong password vs corrupt vs timeout)"
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
