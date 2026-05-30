# TestHelpers.ps1 — shared paths for the Pester suite.
#
# Dot-source this from a test file's top-level BeforeAll, then dot-source the
# production modules you need into the same (script) scope, e.g.:
#
#   BeforeAll {
#       . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
#       . $ProductionModule['Logging']
#   }
#
# Dot-sourcing (rather than wrapping in a function) is deliberate: the
# production functions rely on script-scoped variables (e.g. $ConfigFile,
# $CacheFile, $EncryptionCapableExtensions) and Set-Variable/Get-Variable
# '-Scope Script', which only resolve correctly when loaded into the test
# file's script scope.

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$ModulesDir = Join-Path $RepoRoot 'Modules'

# Only the modules with no hard Windows/WPF/engine dependencies are listed
# here. WpfGui.ps1 and Parallel.ps1 are intentionally omitted. Extraction.ps1 is
# included only for its pure-logic error classifier (Get-ExtractionErrorType /
# Get-LastEngineFailureType); its engine-invocation functions are not tested.
$ProductionModule = @{
    Config       = Join-Path $ModulesDir 'Config.ps1'
    Logging      = Join-Path $ModulesDir 'Logging.ps1'
    ConsoleUI    = Join-Path $ModulesDir 'ConsoleUI.ps1'
    ArchiveUtils = Join-Path $ModulesDir 'ArchiveUtils.ps1'
    Passwords    = Join-Path $ModulesDir 'Passwords.ps1'
    Extraction   = Join-Path $ModulesDir 'Extraction.ps1'
}
