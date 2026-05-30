# ConsoleUI.Tests.ps1 — unit tests for pure formatting helpers in Modules/ConsoleUI.ps1

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['ConsoleUI']
    # ConsoleUI helpers log via Write-Log (defined in the Logging module); stub it
    # so these UI tests stay self-contained.
    function Write-Log { param($Message, $Level) }
}

Describe 'Format-FileSize' {
    It 'reports raw bytes below 1 KB' {
        Format-FileSize 512 | Should -Be '512 B'
    }

    It 'reports KB at the 1 KB boundary' {
        Format-FileSize 1024 | Should -Match '^1[.,]0 KB$'
    }

    It 'reports MB at the 1 MB boundary' {
        Format-FileSize 1048576 | Should -Match '^1[.,]0 MB$'
    }

    It 'reports GB at the 1 GB boundary' {
        Format-FileSize 1073741824 | Should -Match '^1[.,]0 GB$'
    }
}

Describe 'Format-ElapsedFromMs' {
    It 'formats sub-minute durations in seconds' {
        Format-ElapsedFromMs 500 | Should -Match '^0[.,]5s$'
    }

    It 'formats minute-scale durations as mm:ss' {
        Format-ElapsedFromMs 65000 | Should -Be '01:05'
    }

    It 'formats hour-scale durations as hh:mm:ss' {
        Format-ElapsedFromMs 3700000 | Should -Be '01:01:40'
    }
}

Describe 'Format-MaskedPassword' {
    It 'fully masks passwords of four characters or fewer' {
        Format-MaskedPassword 'abcd' | Should -Be '****'
    }

    It 'fully masks a short password' {
        Format-MaskedPassword 'ab' | Should -Be '**'
    }

    It 'keeps the first two characters of a longer password' {
        Format-MaskedPassword 'abcdef' | Should -Be 'ab****'
    }
}

Describe 'Write-ProgressBar' {
    It 'returns without output when Total is non-positive' {
        Write-ProgressBar -Current 1 -Total 0 | Should -BeNullOrEmpty
    }
}

Describe 'Get-ProgressLine' {
    It 'returns an empty string when Total is non-positive' {
        Get-ProgressLine -Current 1 -Total 0 | Should -BeNullOrEmpty
    }

    It 'shows the count and percentage' {
        Get-ProgressLine -Current 9 -Total 36 | Should -Match '\(9/36\)'
    }

    It 'omits an ETA when the sample is too small (one attempt)' {
        $line = Get-ProgressLine -Current 1 -Total 36 -ElapsedMs 500
        $line | Should -Not -Match '~'
        $line | Should -Match 'elapsed'
    }

    It 'shows an ETA once the sample is stable (>=5 attempts, >=1s)' {
        Get-ProgressLine -Current 10 -Total 36 -ElapsedMs 5000 | Should -Match '~'
    }

    It 'shows a per-second rate after two or more attempts' {
        Get-ProgressLine -Current 4 -Total 36 -ElapsedMs 2000 | Should -Match '/s\)'
    }

    It 'appends the engine name when provided' {
        Get-ProgressLine -Current 2 -Total 10 -ElapsedMs 1000 -EngineName '7-Zip' | Should -Match '\[engine: 7-Zip\]'
    }
}

Describe 'Read-OutputBehavior' {
    It 'maps "1" to replace' {
        Mock Read-Host { '1' }
        Read-OutputBehavior -Current 'merge' | Should -Be 'replace'
    }

    It 'maps "2" to new' {
        Mock Read-Host { '2' }
        Read-OutputBehavior -Current 'replace' | Should -Be 'new'
    }

    It 'maps "3" to merge' {
        Mock Read-Host { '3' }
        Read-OutputBehavior -Current 'replace' | Should -Be 'merge'
    }

    It 'keeps the current value on a blank answer' {
        Mock Read-Host { '' }
        Read-OutputBehavior -Current 'merge' | Should -Be 'merge'
    }

    It 'keeps the current value on an invalid answer' {
        Mock Read-Host { 'banana' }
        Read-OutputBehavior -Current 'new' | Should -Be 'new'
    }
}
