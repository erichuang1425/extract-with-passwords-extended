# Logging.Tests.ps1 — unit tests for pure string helpers in Modules/Logging.ps1

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Logging']
}

Describe 'Redact-ArgsForLog' {
    It 'masks the value following a separate -p argument' {
        Redact-ArgsForLog @('x', '-p', 'secret', 'y') | Should -Be 'x -p ******** y'
    }

    It 'masks the value following a separate -hp argument' {
        Redact-ArgsForLog @('-hp', 'secret') | Should -Be '-hp ********'
    }

    It 'masks an inline -p password' {
        Redact-ArgsForLog @('-pSECRET') | Should -Be '-p********'
    }

    It 'masks an inline -hp password' {
        Redact-ArgsForLog @('-hpSECRET') | Should -Be '-hp********'
    }

    It 'leaves non-password arguments untouched' {
        Redact-ArgsForLog @('e', 'archive.7z', '-aoa') | Should -Be 'e archive.7z -aoa'
    }
}

Describe 'ConvertTo-WindowsCommandLineArg' {
    It 'quotes a null argument as empty quotes' {
        ConvertTo-WindowsCommandLineArg $null | Should -Be '""'
    }

    It 'quotes an empty string as empty quotes' {
        ConvertTo-WindowsCommandLineArg '' | Should -Be '""'
    }

    It 'returns a simple token unquoted' {
        ConvertTo-WindowsCommandLineArg 'simple' | Should -Be 'simple'
    }

    It 'does not quote a path without spaces' {
        ConvertTo-WindowsCommandLineArg 'C:\path\file.7z' | Should -Be 'C:\path\file.7z'
    }

    It 'wraps an argument containing spaces in quotes' {
        ConvertTo-WindowsCommandLineArg 'has space' | Should -Be '"has space"'
    }

    It 'escapes embedded double quotes' {
        ConvertTo-WindowsCommandLineArg 'a"b' | Should -Be '"a\"b"'
    }
}

Describe 'Write-Log resilience' {
    It 'writes a formatted line to the log file (happy path)' {
        $script:RunLogPath = Join-Path $TestDrive ("wl_{0}.log" -f ([guid]::NewGuid()))
        Write-Log -Message 'hello world' -Level 'INFO'
        (Get-Content -LiteralPath $script:RunLogPath -Raw) | Should -Match '\[INFO\] hello world'
    }

    It 'does not throw when the target path is unwritable' {
        # Parent directory does not exist, so Add-Content fails on every attempt;
        # the logger must retry and then give up silently rather than throw.
        $script:RunLogPath = Join-Path $TestDrive 'no-such-dir\sub\x.log'
        { Write-Log -Message 'x' } | Should -Not -Throw
    }
}

Describe 'Get-EngineProcessPriorityClass' {
    It 'maps each valid (case-insensitive) name to its ProcessPriorityClass' {
        $cases = @{
            'idle'        = [System.Diagnostics.ProcessPriorityClass]::Idle
            'BelowNormal' = [System.Diagnostics.ProcessPriorityClass]::BelowNormal
            'NORMAL'      = [System.Diagnostics.ProcessPriorityClass]::Normal
            'aboveNormal' = [System.Diagnostics.ProcessPriorityClass]::AboveNormal
            'High'        = [System.Diagnostics.ProcessPriorityClass]::High
        }
        foreach ($name in $cases.Keys) {
            $EngineProcessPriority = $name
            Get-EngineProcessPriorityClass | Should -Be $cases[$name]
        }
    }

    It 'returns $null when unset (leave OS default in place)' {
        $EngineProcessPriority = ''
        Get-EngineProcessPriorityClass | Should -BeNullOrEmpty
    }

    It 'returns $null for an unrecognized value' {
        $EngineProcessPriority = 'turbo'
        Get-EngineProcessPriorityClass | Should -BeNullOrEmpty
    }
}

Describe 'Merge-WorkerLogs' {
    It 'appends worker logs into the main log and removes the worker files' {
        $main = Join-Path $TestDrive 'run.log'
        Set-Content -LiteralPath $main -Value '[main] start' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $TestDrive 'run_worker_111.log') -Value 'w1 line' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $TestDrive 'run_worker_222.log') -Value 'w2 line' -Encoding UTF8

        Merge-WorkerLogs -MainLogPath $main

        $body = Get-Content -LiteralPath $main -Raw
        $body | Should -Match 'merged from worker thread 111'
        $body | Should -Match 'w1 line'
        $body | Should -Match 'w2 line'
        (Test-Path -LiteralPath (Join-Path $TestDrive 'run_worker_111.log')) | Should -BeFalse
        (Test-Path -LiteralPath (Join-Path $TestDrive 'run_worker_222.log')) | Should -BeFalse
    }
}
