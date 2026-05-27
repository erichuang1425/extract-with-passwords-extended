# ============================================================================
# Config.psm1 — Configuration management for Extract-with-Passwords-Extended
# ============================================================================

# ---------------------------------------------------------------------------
# Script-scoped default values
# ---------------------------------------------------------------------------
$script:TryNoPasswordFirst                      = $true
$script:AskBeforeExtracting                     = $true
$script:AskSeparateFolders                      = $true
$script:DefaultSeparateFolders                  = $true
$script:ExistingOutputBehavior                  = "replace"
$script:SevenZipOverwriteMode                   = "aoa"
$script:WinRarOverwriteMode                     = "-o+"
$script:UseSevenZip                             = $true
$script:UseWinRarFallback                       = $true
$script:UsePeaZipBundled7zFallback              = $true
$script:TryExtractEvenIfTestFails               = $true
$script:CleanFailedAttemptOutput                = $true
$script:ShowPasswordInConsole                   = $false
$script:ClearClipboardOnExit                    = $true
$script:OpenOutputAfterSuccess                  = $true
$script:AlwaysShowFinalConfirmation             = $true
$script:ExtractionTimeoutSeconds                = 300
$script:LogRetentionDays                        = 30
$script:UsePasswordCache                        = $true
$script:PasswordCacheRetentionDays              = 90
$script:LoadAllPasswordFiles                    = $false
$script:CheckEncryptionBeforeCycling            = $true
$script:TestOnlyFirst                           = $true
$script:DefaultOutputDirectory                  = ""
$script:AlwaysAskOutputDirectory                = $false
$script:ShowToastNotification                   = $true
$script:LargeArchiveThresholdMB                 = 500
$script:SkipTestExtractFallbackForLargeArchives = $true
$script:VerboseEngineLogging                    = $false
$script:MaxParallelArchives                     = 1
$script:MaxParallelPasswords                    = 1
$script:PreferGui                               = $false

# ---------------------------------------------------------------------------
# JSON key  ->  PowerShell variable name mapping
# ---------------------------------------------------------------------------
$script:ConfigKeyMap = [ordered]@{
    "tryNoPasswordFirst"                      = "TryNoPasswordFirst"
    "askBeforeExtracting"                     = "AskBeforeExtracting"
    "askSeparateFolders"                      = "AskSeparateFolders"
    "defaultSeparateFolders"                  = "DefaultSeparateFolders"
    "existingOutputBehavior"                  = "ExistingOutputBehavior"
    "sevenZipOverwriteMode"                   = "SevenZipOverwriteMode"
    "winRarOverwriteMode"                     = "WinRarOverwriteMode"
    "useSevenZip"                             = "UseSevenZip"
    "useWinRarFallback"                       = "UseWinRarFallback"
    "usePeaZipBundled7zFallback"              = "UsePeaZipBundled7zFallback"
    "tryExtractEvenIfTestFails"               = "TryExtractEvenIfTestFails"
    "cleanFailedAttemptOutput"                = "CleanFailedAttemptOutput"
    "showPasswordInConsole"                   = "ShowPasswordInConsole"
    "clearClipboardOnExit"                    = "ClearClipboardOnExit"
    "openOutputAfterSuccess"                  = "OpenOutputAfterSuccess"
    "alwaysShowFinalConfirmation"             = "AlwaysShowFinalConfirmation"
    "extractionTimeoutSeconds"                = "ExtractionTimeoutSeconds"
    "logRetentionDays"                        = "LogRetentionDays"
    "usePasswordCache"                        = "UsePasswordCache"
    "passwordCacheRetentionDays"              = "PasswordCacheRetentionDays"
    "loadAllPasswordFiles"                    = "LoadAllPasswordFiles"
    "checkEncryptionBeforeCycling"            = "CheckEncryptionBeforeCycling"
    "testOnlyFirst"                           = "TestOnlyFirst"
    "defaultOutputDirectory"                  = "DefaultOutputDirectory"
    "alwaysAskOutputDirectory"                = "AlwaysAskOutputDirectory"
    "showToastNotification"                   = "ShowToastNotification"
    "largeArchiveThresholdMB"                 = "LargeArchiveThresholdMB"
    "skipTestExtractFallbackForLargeArchives" = "SkipTestExtractFallbackForLargeArchives"
    "verboseEngineLogging"                    = "VerboseEngineLogging"
    "maxParallelArchives"                     = "MaxParallelArchives"
    "maxParallelPasswords"                    = "MaxParallelPasswords"
    "preferGui"                               = "PreferGui"
}

# ---------------------------------------------------------------------------
# Read-Config — Reads a JSON config file and sets variables in the caller scope
# ---------------------------------------------------------------------------
function Read-Config {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigFile
    )

    if (-not (Test-Path -LiteralPath $ConfigFile)) {
        Write-Warning "Config file not found: $ConfigFile — using defaults."
        return
    }

    try {
        $json = Get-Content -LiteralPath $ConfigFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "Failed to parse config file: $ConfigFile — $($_.Exception.Message)"
        return
    }

    foreach ($jsonKey in $script:ConfigKeyMap.Keys) {
        $varName = $script:ConfigKeyMap[$jsonKey]

        # Check whether the JSON object actually contains this key
        if ($null -ne $json.PSObject.Properties[$jsonKey]) {
            Set-Variable -Name $varName -Value $json.$jsonKey -Scope 1
        }
    }
}

# ---------------------------------------------------------------------------
# Get-ConfigDefaults — Returns a hashtable of all default configuration values
# ---------------------------------------------------------------------------
function Get-ConfigDefaults {
    [CmdletBinding()]
    param()

    return [ordered]@{
        TryNoPasswordFirst                      = $true
        AskBeforeExtracting                     = $true
        AskSeparateFolders                      = $true
        DefaultSeparateFolders                  = $true
        ExistingOutputBehavior                  = "replace"
        SevenZipOverwriteMode                   = "aoa"
        WinRarOverwriteMode                     = "-o+"
        UseSevenZip                             = $true
        UseWinRarFallback                       = $true
        UsePeaZipBundled7zFallback              = $true
        TryExtractEvenIfTestFails               = $true
        CleanFailedAttemptOutput                = $true
        ShowPasswordInConsole                   = $false
        ClearClipboardOnExit                    = $true
        OpenOutputAfterSuccess                  = $true
        AlwaysShowFinalConfirmation             = $true
        ExtractionTimeoutSeconds                = 300
        LogRetentionDays                        = 30
        UsePasswordCache                        = $true
        PasswordCacheRetentionDays              = 90
        LoadAllPasswordFiles                    = $false
        CheckEncryptionBeforeCycling            = $true
        TestOnlyFirst                           = $true
        DefaultOutputDirectory                  = ""
        AlwaysAskOutputDirectory                = $false
        ShowToastNotification                   = $true
        LargeArchiveThresholdMB                 = 500
        SkipTestExtractFallbackForLargeArchives = $true
        VerboseEngineLogging                    = $false
        MaxParallelArchives                     = 1
        MaxParallelPasswords                    = 1
        PreferGui                               = $false
    }
}

# ---------------------------------------------------------------------------
# Get-DefaultConfigJson — Returns the default config.json content as a string
# ---------------------------------------------------------------------------
function Get-DefaultConfigJson {
    [CmdletBinding()]
    param()

    $defaults = [ordered]@{}

    # Build the JSON object using camelCase keys and their default values
    foreach ($jsonKey in $script:ConfigKeyMap.Keys) {
        $varName = $script:ConfigKeyMap[$jsonKey]
        $defaults[$jsonKey] = (Get-Variable -Name $varName -Scope Script).Value
    }

    return ($defaults | ConvertTo-Json -Depth 4)
}

# ---------------------------------------------------------------------------
# Module exports
# ---------------------------------------------------------------------------
Export-ModuleMember -Function Read-Config, Get-ConfigDefaults, Get-DefaultConfigJson
