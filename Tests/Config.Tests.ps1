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

    It 'clamps a too-large MaxNestedDepth down to the maximum (10)' {
        InModuleScope CfgUnderTest {
            $script:MaxNestedDepth = 99
            Test-ConfigSane
            $script:MaxNestedDepth | Should -Be 10
        }
    }

    It 'allows MaxNestedDepth of 0 (feature effectively disabled)' {
        InModuleScope CfgUnderTest {
            $script:MaxNestedDepth = 0
            Test-ConfigSane
            $script:MaxNestedDepth | Should -Be 0
        }
    }

    It 'resets a non-integer MaxNestedDepth to its default (1)' {
        InModuleScope CfgUnderTest {
            $script:MaxNestedDepth = 'deep'
            Test-ConfigSane
            $script:MaxNestedDepth | Should -Be 1
        }
    }
}

Describe 'Nested-archive defaults' {
    It 'defaults ExtractNestedArchives to disabled' {
        InModuleScope CfgUnderTest {
            $script:ExtractNestedArchives | Should -BeFalse
        }
    }

    It 'defaults DeleteNestedArchiveAfterExtract to disabled' {
        InModuleScope CfgUnderTest {
            $script:DeleteNestedArchiveAfterExtract | Should -BeFalse
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

    It 'resets an invalid PostExtractionAction to prompt' {
        InModuleScope CfgUnderTest {
            $script:PostExtractionAction = 'shred'
            Test-ConfigSane
            $script:PostExtractionAction | Should -Be 'prompt'
        }
    }

    It 'lower-cases a valid-but-miscased PostExtractionAction' {
        InModuleScope CfgUnderTest {
            $script:PostExtractionAction = 'DELETE'
            Test-ConfigSane
            $script:PostExtractionAction | Should -Be 'delete'
        }
    }

    It 'preserves a valid PostExtractionAction' {
        InModuleScope CfgUnderTest {
            $script:PostExtractionAction = 'sort'
            Test-ConfigSane
            $script:PostExtractionAction | Should -Be 'sort'
        }
    }

    It 'resets an invalid EngineProcessPriority to BelowNormal' {
        InModuleScope CfgUnderTest {
            $script:EngineProcessPriority = 'turbo'
            Test-ConfigSane
            $script:EngineProcessPriority | Should -Be 'BelowNormal'
        }
    }

    It 'normalizes the casing of a valid EngineProcessPriority' {
        InModuleScope CfgUnderTest {
            $script:EngineProcessPriority = 'idle'
            Test-ConfigSane
            $script:EngineProcessPriority | Should -Be 'Idle'
        }
    }

    It 'preserves a valid EngineProcessPriority' {
        InModuleScope CfgUnderTest {
            $script:EngineProcessPriority = 'High'
            Test-ConfigSane
            $script:EngineProcessPriority | Should -Be 'High'
        }
    }
}

Describe 'Post-extraction & power defaults' {
    It 'defaults AskOutputBehavior to enabled' {
        InModuleScope CfgUnderTest {
            $script:AskOutputBehavior | Should -BeTrue
        }
    }

    It 'defaults PreventSleepDuringExtraction to enabled' {
        InModuleScope CfgUnderTest {
            $script:PreventSleepDuringExtraction | Should -BeTrue
        }
    }

    It 'defaults FolderNameRules to an empty list' {
        InModuleScope CfgUnderTest {
            @($script:FolderNameRules).Count | Should -Be 0
        }
    }
}
