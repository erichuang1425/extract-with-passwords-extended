# Config.ps1 — Default configuration and config file reader

# Single source of truth for the application version. All banners and log lines
# read from this; keep the installer's own $AppVersion (it does not dot-source
# this module at runtime) in lockstep when bumping.
$AppVersion = "4.1.0"

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

$ExtractNestedArchives = $false
$MaxNestedDepth = 1
$DeleteNestedArchiveAfterExtract = $false

$EncryptionCapableExtensions = @{
    '.zip' = $true; '.zipx' = $true; '.7z' = $true; '.rar' = $true
}

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
            "extractNestedArchives" = "ExtractNestedArchives"
            "maxNestedDepth" = "MaxNestedDepth"
            "deleteNestedArchiveAfterExtract" = "DeleteNestedArchiveAfterExtract"
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
