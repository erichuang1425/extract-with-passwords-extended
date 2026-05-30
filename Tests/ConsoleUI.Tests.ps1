# ConsoleUI.Tests.ps1 — unit tests for pure formatting helpers in Modules/ConsoleUI.ps1

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['ConsoleUI']
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
