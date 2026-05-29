# ArchiveUtils.Tests.ps1 — unit tests for archive name/format helpers in Modules/ArchiveUtils.ps1
#
# NOTE: Sanitize-FileName depends on [IO.Path]::GetInvalidFileNameChars(),
# which differs between Windows and Linux. These tests assume the Windows
# invalid-char set (the tool is Windows-only) and run on a Windows CI runner.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    # Config.ps1 defines $EncryptionCapableExtensions used by Test-IsEncryptionCapable.
    . $ProductionModule['Config']
    . $ProductionModule['ArchiveUtils']
    # Find-NestedArchives only calls Write-Log from its enumeration catch blocks;
    # stub it so the helper is self-contained without the Logging module.
    function Write-Log { param($Message, $Level) }
}

Describe 'Get-ArchiveBaseName' {
    It 'strips a compound .tar.gz extension' {
        Get-ArchiveBaseName 'C:\dir\thing.tar.gz' | Should -Be 'thing'
    }

    It 'strips a .part01.rar volume suffix' {
        Get-ArchiveBaseName 'archive.part01.rar' | Should -Be 'archive'
    }

    It 'strips a .zip.001 split suffix' {
        Get-ArchiveBaseName 'data.zip.001' | Should -Be 'data'
    }

    It 'strips a plain .7z extension' {
        Get-ArchiveBaseName 'photos.7z' | Should -Be 'photos'
    }
}

Describe 'Test-IsSupportedArchiveName' {
    It 'recognizes common archive extensions' -ForEach @(
        @{ Name = 'a.zip' }, @{ Name = 'a.7z' }, @{ Name = 'b.rar' },
        @{ Name = 'c.tar.gz' }, @{ Name = 'd.part2.rar' }, @{ Name = 'e.r01' },
        @{ Name = 'f.7z.001' }, @{ Name = 'g.z01' }
    ) {
        Test-IsSupportedArchiveName $Name | Should -BeTrue
    }

    It 'rejects non-archive names' -ForEach @(
        @{ Name = 'notes.txt' }, @{ Name = 'README.md' }, @{ Name = 'noextension' }
    ) {
        Test-IsSupportedArchiveName $Name | Should -BeFalse
    }
}

Describe 'Test-IsEncryptionCapable' {
    It 'treats zip/7z/rar (and split variants) as encryption-capable' -ForEach @(
        @{ Name = 'a.zip' }, @{ Name = 'a.7z' }, @{ Name = 'b.rar' },
        @{ Name = 'c.zip.001' }, @{ Name = 'd.part1.rar' }
    ) {
        Test-IsEncryptionCapable $Name | Should -BeTrue
    }

    It 'treats tar/iso as not encryption-capable' -ForEach @(
        @{ Name = 'e.tar.gz' }, @{ Name = 'f.iso' }
    ) {
        Test-IsEncryptionCapable $Name | Should -BeFalse
    }
}

Describe 'Test-IsRarLike' {
    It 'matches rar and rar volume forms' -ForEach @(
        @{ Name = 'a.rar' }, @{ Name = 'a.part01.rar' }, @{ Name = 'a.rar.001' }
    ) {
        Test-IsRarLike $Name | Should -BeTrue
    }

    It 'does not match a zip' {
        Test-IsRarLike 'a.zip' | Should -BeFalse
    }
}

Describe 'Find-NestedArchives' {
    BeforeAll {
        $script:nestRoot = Join-Path $TestDrive 'nest'
        $sub = Join-Path $script:nestRoot 'sub'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null

        # Entry archives that should be discovered
        New-Item -ItemType File -Force -Path (Join-Path $script:nestRoot 'a.zip')   | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $script:nestRoot 'b.rar')   | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $sub 'd.7z')                | Out-Null
        # Excluded: not an archive, and a non-entry split volume
        New-Item -ItemType File -Force -Path (Join-Path $script:nestRoot 'notes.txt')      | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $script:nestRoot 'c.part02.rar')   | Out-Null
    }

    It 'returns only supported entry archives, recursing into subfolders' {
        $found = @(Find-NestedArchives -Root $script:nestRoot)
        $names = @($found | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        $names | Should -Be @('a.zip', 'b.rar', 'd.7z')
    }

    It 'excludes non-entry split volumes and non-archive files' {
        $found = @(Find-NestedArchives -Root $script:nestRoot)
        $names = @($found | ForEach-Object { [IO.Path]::GetFileName($_) })
        $names | Should -Not -Contain 'c.part02.rar'
        $names | Should -Not -Contain 'notes.txt'
    }

    It 'returns an empty result for a non-existent root' {
        @(Find-NestedArchives -Root (Join-Path $TestDrive 'does-not-exist')).Count | Should -Be 0
    }
}

Describe 'Sanitize-FileName' {
    It 'replaces Windows-invalid characters with underscores' {
        Sanitize-FileName 'a:b*c' | Should -Be 'a_b_c'
    }

    It 'prefixes reserved device names' {
        Sanitize-FileName 'CON' | Should -Be '_CON'
    }

    It 'trims trailing dots' {
        Sanitize-FileName 'name.' | Should -Be 'name'
    }

    It 'falls back to a default for whitespace-only input' {
        Sanitize-FileName '   ' | Should -Be 'Extracted'
    }

    It 'clamps very long names to 240 characters' {
        (Sanitize-FileName ('x' * 300)).Length | Should -Be 240
    }
}
