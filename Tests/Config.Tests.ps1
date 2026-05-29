# Config.Tests.ps1 — unit tests for Test-ConfigSane in Modules/Config.ps1
#
# Test-ConfigSane reads/writes its settings via Get-Variable/Set-Variable
# '-Scope Script'. Under Pester 5 the "Script" scope seen by test code is NOT
# the same scope a dot-sourced function sees, so we load Config.ps1 as a real
# (dynamic) module and drive it from InModuleScope: inside the module both
# $script: and the function's '-Scope Script' resolve to the module's script
# scope, so they are guaranteed to refer to the same variables.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $src = Get-Content -Raw -LiteralPath $ProductionModule['Config']
    New-Module -Name CfgUnderTest -ScriptBlock ([scriptblock]::Create($src)) | Import-Module -Force
}

AfterAll {
    Remove-Module CfgUnderTest -Force -ErrorAction SilentlyContinue
}

Describe 'Test-ConfigSane integer clamping' {
    It 'clamps a too-large MaxParallelArchives down to the maximum (32)' {
        InModuleScope CfgUnderTest {
            $script:MaxParallelArchives = 99
            Test-ConfigSane
            $script:MaxParallelArchives | Should -Be 32
        }
    }

    It 'clamps a too-small MaxParallelArchives up to the minimum (1)' {
        InModuleScope CfgUnderTest {
            $script:MaxParallelArchives = 0
            Test-ConfigSane
            $script:MaxParallelArchives | Should -Be 1
        }
    }

    It 'resets a non-integer value to its default' {
        InModuleScope CfgUnderTest {
            $script:ExtractionTimeoutSeconds = 'abc'
            Test-ConfigSane
            $script:ExtractionTimeoutSeconds | Should -Be 300
        }
    }

    It 'preserves an in-range value' {
        InModuleScope CfgUnderTest {
            $script:PasswordCacheRetentionDays = 45
            Test-ConfigSane
            $script:PasswordCacheRetentionDays | Should -Be 45
        }
    }
}

Describe 'Test-ConfigSane enum validation' {
    It 'resets an invalid ExistingOutputBehavior to replace' {
        InModuleScope CfgUnderTest {
            $script:ExistingOutputBehavior = 'bogus'
            Test-ConfigSane
            $script:ExistingOutputBehavior | Should -Be 'replace'
        }
    }

    It 'lower-cases a valid-but-miscased ExistingOutputBehavior' {
        InModuleScope CfgUnderTest {
            $script:ExistingOutputBehavior = 'MERGE'
            Test-ConfigSane
            $script:ExistingOutputBehavior | Should -Be 'merge'
        }
    }

    It 'resets an invalid SevenZipOverwriteMode to aoa' {
        InModuleScope CfgUnderTest {
            $script:SevenZipOverwriteMode = 'zzz'
            Test-ConfigSane
            $script:SevenZipOverwriteMode | Should -Be 'aoa'
        }
    }

    It 'resets an invalid WinRarOverwriteMode to -o+' {
        InModuleScope CfgUnderTest {
            $script:WinRarOverwriteMode = 'nope'
            Test-ConfigSane
            $script:WinRarOverwriteMode | Should -Be '-o+'
        }
    }
}
