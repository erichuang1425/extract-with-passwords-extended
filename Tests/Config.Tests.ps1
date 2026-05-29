# Config.Tests.ps1 — unit tests for Test-ConfigSane in Modules/Config.ps1
#
# Test-ConfigSane reads/writes its settings via Get-Variable/Set-Variable
# '-Scope Script'. Under Pester 5 the 'Script' scope seen inside an It block is
# NOT the same scope as the one seen by functions dot-sourced in BeforeAll, so
# we drive the config variables through Set-Cfg/Get-Cfg helpers that are defined
# in the same BeforeAll and therefore share the production functions' script
# scope. (Write-Host warnings emitted while clamping are harmless here.)

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Config']

    function Set-Cfg { param([string]$Name, $Value) Set-Variable -Name $Name -Value $Value -Scope Script }
    function Get-Cfg { param([string]$Name) Get-Variable -Name $Name -Scope Script -ValueOnly }
}

Describe 'Test-ConfigSane integer clamping' {
    It 'clamps a too-large MaxParallelArchives down to the maximum (32)' {
        Set-Cfg MaxParallelArchives 99
        Test-ConfigSane
        Get-Cfg MaxParallelArchives | Should -Be 32
    }

    It 'clamps a too-small MaxParallelArchives up to the minimum (1)' {
        Set-Cfg MaxParallelArchives 0
        Test-ConfigSane
        Get-Cfg MaxParallelArchives | Should -Be 1
    }

    It 'resets a non-integer value to its default' {
        Set-Cfg ExtractionTimeoutSeconds 'abc'
        Test-ConfigSane
        Get-Cfg ExtractionTimeoutSeconds | Should -Be 300
    }

    It 'preserves an in-range value' {
        Set-Cfg PasswordCacheRetentionDays 45
        Test-ConfigSane
        Get-Cfg PasswordCacheRetentionDays | Should -Be 45
    }
}

Describe 'Test-ConfigSane enum validation' {
    It 'resets an invalid ExistingOutputBehavior to replace' {
        Set-Cfg ExistingOutputBehavior 'bogus'
        Test-ConfigSane
        Get-Cfg ExistingOutputBehavior | Should -Be 'replace'
    }

    It 'lower-cases a valid-but-miscased ExistingOutputBehavior' {
        Set-Cfg ExistingOutputBehavior 'MERGE'
        Test-ConfigSane
        Get-Cfg ExistingOutputBehavior | Should -Be 'merge'
    }

    It 'resets an invalid SevenZipOverwriteMode to aoa' {
        Set-Cfg SevenZipOverwriteMode 'zzz'
        Test-ConfigSane
        Get-Cfg SevenZipOverwriteMode | Should -Be 'aoa'
    }

    It 'resets an invalid WinRarOverwriteMode to -o+' {
        Set-Cfg WinRarOverwriteMode 'nope'
        Test-ConfigSane
        Get-Cfg WinRarOverwriteMode | Should -Be '-o+'
    }
}
