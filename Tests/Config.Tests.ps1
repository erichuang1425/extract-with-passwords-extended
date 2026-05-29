# Config.Tests.ps1 — unit tests for Test-ConfigSane in Modules/Config.ps1
#
# Test-ConfigSane reads/writes its settings via Get-Variable/Set-Variable
# '-Scope Script', so the tests manipulate and assert the same script-scoped
# variables. Write-Host warnings from clamping are harmless during tests.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Config']
}

Describe 'Test-ConfigSane integer clamping' {
    It 'clamps a too-large MaxParallelArchives down to the maximum (32)' {
        Set-Variable -Name MaxParallelArchives -Value 99 -Scope Script
        Test-ConfigSane
        (Get-Variable -Name MaxParallelArchives -Scope Script -ValueOnly) | Should -Be 32
    }

    It 'clamps a too-small MaxParallelArchives up to the minimum (1)' {
        Set-Variable -Name MaxParallelArchives -Value 0 -Scope Script
        Test-ConfigSane
        (Get-Variable -Name MaxParallelArchives -Scope Script -ValueOnly) | Should -Be 1
    }

    It 'resets a non-integer value to its default' {
        Set-Variable -Name ExtractionTimeoutSeconds -Value 'abc' -Scope Script
        Test-ConfigSane
        (Get-Variable -Name ExtractionTimeoutSeconds -Scope Script -ValueOnly) | Should -Be 300
    }

    It 'preserves an in-range value' {
        Set-Variable -Name PasswordCacheRetentionDays -Value 45 -Scope Script
        Test-ConfigSane
        (Get-Variable -Name PasswordCacheRetentionDays -Scope Script -ValueOnly) | Should -Be 45
    }
}

Describe 'Test-ConfigSane enum validation' {
    It 'resets an invalid ExistingOutputBehavior to replace' {
        Set-Variable -Name ExistingOutputBehavior -Value 'bogus' -Scope Script
        Test-ConfigSane
        (Get-Variable -Name ExistingOutputBehavior -Scope Script -ValueOnly) | Should -Be 'replace'
    }

    It 'lower-cases a valid-but-miscased ExistingOutputBehavior' {
        Set-Variable -Name ExistingOutputBehavior -Value 'MERGE' -Scope Script
        Test-ConfigSane
        (Get-Variable -Name ExistingOutputBehavior -Scope Script -ValueOnly) | Should -Be 'merge'
    }

    It 'resets an invalid SevenZipOverwriteMode to aoa' {
        Set-Variable -Name SevenZipOverwriteMode -Value 'zzz' -Scope Script
        Test-ConfigSane
        (Get-Variable -Name SevenZipOverwriteMode -Scope Script -ValueOnly) | Should -Be 'aoa'
    }

    It 'resets an invalid WinRarOverwriteMode to -o+' {
        Set-Variable -Name WinRarOverwriteMode -Value 'nope' -Scope Script
        Test-ConfigSane
        (Get-Variable -Name WinRarOverwriteMode -Scope Script -ValueOnly) | Should -Be '-o+'
    }
}
