# Config.ps1 — Default configuration and config file reader

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
$PreferGui = $false

$EncryptionCapableExtensions = @{
    '.zip' = $true; '.zipx' = $true; '.7z' = $true; '.rar' = $true
}

$lastCopiedPassword = $null
$lastSuccessfulPassword = $null

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
            "preferGui" = "PreferGui"
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
