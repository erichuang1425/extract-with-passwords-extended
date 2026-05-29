# PesterConfiguration.ps1 — builds and runs the Pester 5 configuration.
#
# Usage (from repo root or anywhere):
#   pwsh -File ./Tests/PesterConfiguration.ps1
#
# Produces NUnit test results (testResults.xml) and JaCoCo code coverage
# (coverage.xml) for the pure-logic modules, and exits non-zero on failure.

param(
    [string]$ResultsPath  = 'testResults.xml',
    [string]$CoveragePath = 'coverage.xml'
)

$ErrorActionPreference = 'Stop'

Import-Module Pester -MinimumVersion 5.0.0

$testsDir   = $PSScriptRoot
$modulesDir = Join-Path (Split-Path -Parent $testsDir) 'Modules'

$config = New-PesterConfiguration
$config.Run.Path                  = $testsDir
$config.Run.Exit                  = $true
$config.Output.Verbosity          = 'Detailed'
$config.TestResult.Enabled        = $true
$config.TestResult.OutputPath     = $ResultsPath
$config.TestResult.OutputFormat   = 'NUnitXml'
$config.CodeCoverage.Enabled      = $true
$config.CodeCoverage.Path         = @(
    (Join-Path $modulesDir 'Config.ps1'),
    (Join-Path $modulesDir 'Logging.ps1'),
    (Join-Path $modulesDir 'ConsoleUI.ps1'),
    (Join-Path $modulesDir 'ArchiveUtils.ps1'),
    (Join-Path $modulesDir 'Passwords.ps1')
)
$config.CodeCoverage.OutputPath   = $CoveragePath

Invoke-Pester -Configuration $config
