# Config.ps1 — Default configuration and config file reader

# Single source of truth for the application version. All banners and log lines
# read from this; keep the installer's own $AppVersion (it does not dot-source
# this module at runtime) in lockstep when bumping.
$AppVersion = "4.2.0"

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
$VerboseEngineLogging = $false
$MaxParallelArchives = 1
$MaxParallelPasswords = 1
$MaxArchivesPerScan = 0
$PreferGui = $false
# Ask for confirmation before closing the GUI window when archives are queued,
# so a stray click on the close button never silently discards the run/results.
$ConfirmGuiClose = $true

# Recursively extract archives found inside an already-extracted output folder.
# On by default so an archive whose real payload is a *nested* archive (a common
# packaging habit) is unpacked all the way down without manual follow-up. The
# descent stops at the layer that yields a real executable payload (see
# $ExecutablePayloadExtensions / $RedistFileNamePatterns) or at $MaxNestedDepth.
$ExtractNestedArchives = $true
$MaxNestedDepth = 5
$DeleteNestedArchiveAfterExtract = $false

# Priority class given to each extraction engine process (7z / WinRAR / UnRAR).
# Lowering it keeps the system responsive — browsers, downloads, and other apps
# competing for CPU and disk are no longer starved by a busy extraction.
# Valid: "Idle" | "BelowNormal" | "Normal" | "AboveNormal" | "High".
# "Idle" also drops the engine to background disk-I/O priority on Windows, which
# is the gentlest setting when something else (e.g. a download) is writing to the
# same drive/path.
$EngineProcessPriority = "BelowNormal"

# Optional rename rules applied to the auto-derived output folder name (after the
# archive extension is stripped, before the name is sanitized). Each rule is a
# regex search/replace, letting the user exclude or rewrite parts of the name —
# e.g. turn "Nomachi-Ankergames.zip" into a "Nomachi" folder. Each entry is
# either a plain string (a regex pattern that is simply removed) or an object
# { "pattern": "...", "replacement": "...", "ignoreCase": true }. Rules apply in
# order; an empty/whitespace result falls back to the sanitizer's default.
$FolderNameRules = @()

# Prompt each run to choose how existing extracted folders are handled.
$AskOutputBehavior = $true
# What to do with the original source archives after a run:
# "none" | "prompt" | "delete" (successful sets) | "sort" (into _Extracted/_Failed).
$PostExtractionAction = "prompt"
# Skip the confirmation prompt when deleting (used only with action "delete").
$PostExtractionSilent = $false
# Keep the system awake (no idle-sleep) while extraction is running.
$PreventSleepDuringExtraction = $true

$EncryptionCapableExtensions = @{
    '.zip' = $true; '.zipx' = $true; '.7z' = $true; '.rar' = $true
}

# File extensions treated as an executable "payload". When the nested
# (multilayer) extraction pass uncovers one of these inside a freshly-extracted
# layer, it stops descending further: the executable is taken to be the intended
# final output, so there is no need to keep peeling layers underneath it.
$ExecutablePayloadExtensions = @('.exe', '.msi', '.com', '.scr')

# Redistributable/prerequisite installers that are NOT the real payload. The
# nested pass ignores these when deciding whether a layer has reached its final
# executable: a folder whose only .exe is a VC++ runtime, DirectX, or .NET
# prerequisite (sitting next to a still-packed game archive) keeps descending
# instead of stopping on the redist. Matched case-insensitively against the file
# name; a file whose parent path contains a redist/prerequisites folder is also
# treated as redist. Patterns are plain regex fragments.
$RedistFileNamePatterns = @(
    'vc_?redist', 'vcredist', 'msvc', 'dxsetup', 'dxwebsetup',
    # A bare "directx" substring would also match a real payload that happens to
    # be titled e.g. "DirectX Adventure.exe"; dxsetup/dxwebsetup already cover the
    # common installer file names, so this only matches DirectX installers that
    # spell out redist/setup/web/install elsewhere in the name.
    'directx.*(?:redist|setup|web|install)',
    'dotnet', 'ndp\d', 'netfx', 'oalinst', 'openal',
    'ue\d?prereqsetup', 'prereq', 'prerequisite', 'physx', 'xnafx',
    'commonredist', 'redist'
)

# Strip leading/trailing bracket "tag" groups from the auto-derived output folder
# name — e.g. 【PC+KR汉化ADV】男娘便女 -> 男娘便女, and
# [241128][硝石工房] IVAV!! 2nd Girl Ver25.01.13 [RJ01290563] -> IVAV!! 2nd Girl
# Ver25.01.13. Only fullwidth 【】 and square [] groups at the very start/end are
# removed; parentheses ()/（） and brackets in the middle of a title are left
# alone. Applies before $FolderNameRules so a user rule can still refine further.
$StripBracketTagsFromFolderName = $true

$lastCopiedPassword = $null
$lastSuccessfulPassword = $null

function Test-ConfigSane {
    $intClamps = @{
        "ExtractionTimeoutSeconds"       = @{ Min = 0;    Max = 86400; Default = 300 }
        "LogRetentionDays"               = @{ Min = 0;    Max = 36500; Default = 30 }
        "PasswordCacheRetentionDays"     = @{ Min = 0;    Max = 36500; Default = 90 }
        "LargeArchiveThresholdMB"        = @{ Min = 0;    Max = 1048576; Default = 500 }
        "MaxParallelArchives"            = @{ Min = 1;    Max = 32; Default = 1 }
        "MaxParallelPasswords"           = @{ Min = 1;    Max = 32; Default = 1 }
        "MaxArchivesPerScan"             = @{ Min = 0;    Max = 1000000; Default = 0 }
        "MaxNestedDepth"                 = @{ Min = 0;    Max = 10; Default = 1 }
    }

    foreach ($name in $intClamps.Keys) {
        $rule = $intClamps[$name]
        $val = Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue

        $intVal = 0
        if (-not [int]::TryParse([string]$val, [ref]$intVal)) {
            Write-Host "[!] Config '$name' is not a valid integer ('$val'); resetting to default ($($rule.Default))." -ForegroundColor Yellow
            Set-Variable -Name $name -Value $rule.Default -Scope Script
            continue
        }

        if ($intVal -lt $rule.Min -or $intVal -gt $rule.Max) {
            $clamped = [Math]::Min([Math]::Max($intVal, $rule.Min), $rule.Max)
            Write-Host "[!] Config '$name'=$intVal out of range [$($rule.Min),$($rule.Max)]; clamped to $clamped." -ForegroundColor Yellow
            Set-Variable -Name $name -Value $clamped -Scope Script
        } else {
            Set-Variable -Name $name -Value $intVal -Scope Script
        }
    }

    $behavior = Get-Variable -Name "ExistingOutputBehavior" -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($behavior -notin @("replace", "merge", "new")) {
        $lc = ([string]$behavior).ToLowerInvariant()
        if ($lc -in @("replace", "merge", "new")) {
            Set-Variable -Name "ExistingOutputBehavior" -Value $lc -Scope Script
        } else {
            Write-Host "[!] Config 'existingOutputBehavior'='$behavior' invalid (expected replace|merge|new); resetting to 'replace'." -ForegroundColor Yellow
            Set-Variable -Name "ExistingOutputBehavior" -Value "replace" -Scope Script
        }
    }

    $postAction = Get-Variable -Name "PostExtractionAction" -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ($postAction -notin @("none", "prompt", "delete", "sort")) {
        $lc = ([string]$postAction).ToLowerInvariant()
        if ($lc -in @("none", "prompt", "delete", "sort")) {
            Set-Variable -Name "PostExtractionAction" -Value $lc -Scope Script
        } else {
            Write-Host "[!] Config 'postExtractionAction'='$postAction' invalid (expected none|prompt|delete|sort); resetting to 'prompt'." -ForegroundColor Yellow
            Set-Variable -Name "PostExtractionAction" -Value "prompt" -Scope Script
        }
    }

    $szMode = Get-Variable -Name "SevenZipOverwriteMode" -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ([string]$szMode -notmatch '^a(oa|os|ot|ou)$') {
        Write-Host "[!] Config 'sevenZipOverwriteMode'='$szMode' invalid (expected aoa|aos|aot|aou); resetting to 'aoa'." -ForegroundColor Yellow
        Set-Variable -Name "SevenZipOverwriteMode" -Value "aoa" -Scope Script
    }

    $rarMode = Get-Variable -Name "WinRarOverwriteMode" -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    if ([string]$rarMode -notmatch '^-o(\+|-|r)$') {
        Write-Host "[!] Config 'winRarOverwriteMode'='$rarMode' invalid (expected -o+|-o-|-or); resetting to '-o+'." -ForegroundColor Yellow
        Set-Variable -Name "WinRarOverwriteMode" -Value "-o+" -Scope Script
    }

    $validPriorities = @("Idle", "BelowNormal", "Normal", "AboveNormal", "High")
    $priority = Get-Variable -Name "EngineProcessPriority" -Scope Script -ValueOnly -ErrorAction SilentlyContinue
    $matchedPriority = $validPriorities | Where-Object { $_ -ieq [string]$priority } | Select-Object -First 1
    if ($matchedPriority) {
        # Normalize casing so downstream comparisons/enum parsing are exact.
        Set-Variable -Name "EngineProcessPriority" -Value $matchedPriority -Scope Script
    } else {
        Write-Host "[!] Config 'engineProcessPriority'='$priority' invalid (expected Idle|BelowNormal|Normal|AboveNormal|High); resetting to 'BelowNormal'." -ForegroundColor Yellow
        Set-Variable -Name "EngineProcessPriority" -Value "BelowNormal" -Scope Script
    }
}

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
            "verboseEngineLogging" = "VerboseEngineLogging"
            "maxParallelArchives" = "MaxParallelArchives"
            "maxParallelPasswords" = "MaxParallelPasswords"
            "maxArchivesPerScan" = "MaxArchivesPerScan"
            "preferGui" = "PreferGui"
            "confirmGuiClose" = "ConfirmGuiClose"
            "extractNestedArchives" = "ExtractNestedArchives"
            "maxNestedDepth" = "MaxNestedDepth"
            "deleteNestedArchiveAfterExtract" = "DeleteNestedArchiveAfterExtract"
            "askOutputBehavior" = "AskOutputBehavior"
            "postExtractionAction" = "PostExtractionAction"
            "postExtractionSilent" = "PostExtractionSilent"
            "preventSleepDuringExtraction" = "PreventSleepDuringExtraction"
            "engineProcessPriority" = "EngineProcessPriority"
            "folderNameRules" = "FolderNameRules"
            "stripBracketTagsFromFolderName" = "StripBracketTagsFromFolderName"
            "redistFileNamePatterns" = "RedistFileNamePatterns"
        }

        foreach ($jsonKey in $map.Keys) {
            $varName = $map[$jsonKey]
            $val = $cfg.PSObject.Properties[$jsonKey]
            if ($null -ne $val) {
                Set-Variable -Name $varName -Value $val.Value -Scope 1
            }
        }

        Test-ConfigSane
    } catch {
        Write-Host "[!] Could not load config.json: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "[!] Falling back to defaults due to invalid config.json" -ForegroundColor Yellow
    }
}
