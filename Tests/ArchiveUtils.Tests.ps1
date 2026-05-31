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

    It 'strips an underscore-separated _part1.rar volume suffix' {
        Get-ArchiveBaseName 'X_part1.rar' | Should -Be 'X'
    }

    It 'strips an underscore-separated middle part too' {
        Get-ArchiveBaseName 'X_part3.rar' | Should -Be 'X'
    }

    It 'strips hyphen- and space-separated part suffixes' {
        Get-ArchiveBaseName 'X-part1.rar' | Should -Be 'X'
        Get-ArchiveBaseName 'X part1.rar' | Should -Be 'X'
    }

    It 'keeps a literal "part" name with no separator as-is' {
        Get-ArchiveBaseName 'mypart1.rar' | Should -Be 'mypart1'
    }

    It 'handles a multi-byte (Japanese) base name' {
        Get-ArchiveBaseName '日本語_part1.rar' | Should -Be '日本語'
    }
}

Describe 'Test-IsFirstVolumeOrNormalArchive' {
    It 'treats only the first underscore-separated part as the entry' -ForEach @(
        @{ Name = 'X_part1.rar';   Expected = $true }
        @{ Name = 'X_part01.rar';  Expected = $true }
        @{ Name = 'X_part001.rar'; Expected = $true }
        @{ Name = 'X_part2.rar';   Expected = $false }
        @{ Name = 'X_part3.rar';   Expected = $false }
        @{ Name = 'X_part4.rar';   Expected = $false }
    ) {
        Test-IsFirstVolumeOrNormalArchive $Name | Should -Be $Expected
    }

    It 'handles dot/hyphen/space separators the same way' -ForEach @(
        @{ Name = 'X.part1.rar';  Expected = $true }
        @{ Name = 'X.part2.rar';  Expected = $false }
        @{ Name = 'X-part1.rar';  Expected = $true }
        @{ Name = 'X-part2.rar';  Expected = $false }
        @{ Name = 'X part2.rar';  Expected = $false }
    ) {
        Test-IsFirstVolumeOrNormalArchive $Name | Should -Be $Expected
    }

    It 'treats names without a real separator before "part" as normal archives' {
        Test-IsFirstVolumeOrNormalArchive 'mypart1.rar' | Should -BeTrue
        Test-IsFirstVolumeOrNormalArchive 'mypart2.rar' | Should -BeTrue
    }

    It 'keeps existing volume-form behavior' -ForEach @(
        @{ Name = 'normal.rar'; Expected = $true }
        @{ Name = 'data.001';   Expected = $true }
        @{ Name = 'data.002';   Expected = $false }
        @{ Name = 'data.r01';   Expected = $false }
        @{ Name = 'data.z02';   Expected = $false }
    ) {
        Test-IsFirstVolumeOrNormalArchive $Name | Should -Be $Expected
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

Describe 'Test-MultiVolumeComplete (underscore part sets)' {
    BeforeAll {
        $script:volDir = Join-Path $TestDrive 'vol'
        New-Item -ItemType Directory -Force -Path $script:volDir | Out-Null
    }

    It 'reports a complete underscore-separated set' {
        $d = Join-Path $script:volDir 'complete'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        1..3 | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d "S_part$_.rar") | Out-Null }
        (Test-MultiVolumeComplete -Archive (Join-Path $d 'S_part1.rar')).Complete | Should -BeTrue
    }

    It 'detects a missing middle volume and names it with the same separator' {
        # part2 must be present for the gap heuristic to engage (an absent part2
        # is treated as a single-volume archive by design); here part3 is missing.
        $d = Join-Path $script:volDir 'gappy'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        'S_part1.rar', 'S_part2.rar', 'S_part4.rar' | ForEach-Object {
            New-Item -ItemType File -Force -Path (Join-Path $d $_) | Out-Null
        }
        $r = Test-MultiVolumeComplete -Archive (Join-Path $d 'S_part1.rar')
        $r.Complete | Should -BeFalse
        ($r.Missing -join ',') | Should -Match 'S_part03\.rar'
    }
}

Describe 'Get-ArchiveVolumeSet' {
    It 'returns all underscore-separated parts of a set' {
        $d = Join-Path $TestDrive 'gvs_part'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        1..3 | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d "A_part$_.rar") | Out-Null }
        $set = @(Get-ArchiveVolumeSet -EntryArchive (Join-Path $d 'A_part1.rar') | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        $set | Should -Be @('A_part1.rar', 'A_part2.rar', 'A_part3.rar')
    }

    It 'returns all numeric .NNN volumes' {
        $d = Join-Path $TestDrive 'gvs_num'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        '001', '002', '003' | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d "data.$_") | Out-Null }
        @(Get-ArchiveVolumeSet -EntryArchive (Join-Path $d 'data.001')).Count | Should -Be 3
    }

    It 'includes the base .rar member alongside .rNN parts' {
        $d = Join-Path $TestDrive 'gvs_rnn'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        'vid.rar', 'vid.r00', 'vid.r01' | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d $_) | Out-Null }
        $set = @(Get-ArchiveVolumeSet -EntryArchive (Join-Path $d 'vid.rar') | ForEach-Object { [IO.Path]::GetFileName($_) } | Sort-Object)
        $set | Should -Be @('vid.r00', 'vid.r01', 'vid.rar')
    }

    It 'returns just the entry for a standalone archive' {
        $d = Join-Path $TestDrive 'gvs_solo'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $d 'solo.7z') | Out-Null
        @(Get-ArchiveVolumeSet -EntryArchive (Join-Path $d 'solo.7z')).Count | Should -Be 1
    }
}

Describe 'Remove-ArchiveSet / Move-ArchiveSet' {
    It 'deletes every part of the set' {
        $d = Join-Path $TestDrive 'del'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        1..3 | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d "B_part$_.rar") | Out-Null }
        $removed = Remove-ArchiveSet -EntryArchive (Join-Path $d 'B_part1.rar')
        $removed | Should -Be 3
        @(Get-ChildItem -LiteralPath $d -File).Count | Should -Be 0
    }

    It 'moves every part into the destination subfolder' {
        $d = Join-Path $TestDrive 'mov'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        1..2 | ForEach-Object { New-Item -ItemType File -Force -Path (Join-Path $d "C_part$_.rar") | Out-Null }
        $moved = Move-ArchiveSet -EntryArchive (Join-Path $d 'C_part1.rar') -DestSubfolder '_Extracted'
        $moved | Should -Be 2
        @(Get-ChildItem -LiteralPath (Join-Path $d '_Extracted') -File).Count | Should -Be 2
        @(Get-ChildItem -LiteralPath $d -File).Count | Should -Be 0
    }
}

Describe 'Resolve-OutputDir BehaviorOverride' {
    It 'forcing "new" preserves an existing directory and returns a unique sibling' {
        $existing = Join-Path $TestDrive 'photos'
        New-Item -ItemType Directory -Force -Path $existing | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $existing 'keep.txt') | Out-Null

        $resolved = Resolve-OutputDir -BaseDir $existing -IsSharedOutput $false -BehaviorOverride 'new'

        # The pre-existing directory and its contents must survive.
        Test-Path -LiteralPath (Join-Path $existing 'keep.txt') | Should -BeTrue
        # A distinct, freshly created sibling is returned.
        $resolved | Should -Not -Be $existing
        Test-Path -LiteralPath $resolved | Should -BeTrue
    }
}

Describe 'Test-IsCompoundTarArchive' {
    It 'matches compound tar formats (two-layer)' -ForEach @(
        @{ Name = 'a.tar.zst' }, @{ Name = 'a.tar.gz' }, @{ Name = 'a.tar.bz2' },
        @{ Name = 'a.tar.xz' }, @{ Name = 'a.tgz' }, @{ Name = 'a.tbz2' },
        @{ Name = 'a.txz' }, @{ Name = 'a.tzst' }
    ) {
        Test-IsCompoundTarArchive $Name | Should -BeTrue
    }

    It 'does not match a plain tar or single-layer archives' -ForEach @(
        @{ Name = 'a.tar' }, @{ Name = 'a.zip' }, @{ Name = 'a.7z' }, @{ Name = 'a.zst' }
    ) {
        Test-IsCompoundTarArchive $Name | Should -BeFalse
    }
}

Describe 'Get-ExpectedTarResidueName' {
    It 'derives the intermediate tarball name from a compound tar archive' -ForEach @(
        @{ Name = 'foo.tar.zst';     Expected = 'foo.tar' }
        @{ Name = 'foo.tar.gz';      Expected = 'foo.tar' }
        @{ Name = 'foo.tar.bz2';     Expected = 'foo.tar' }
        @{ Name = 'data.set.tar.xz'; Expected = 'data.set.tar' }
        @{ Name = 'foo.tgz';         Expected = 'foo.tar' }
        @{ Name = 'foo.tbz2';        Expected = 'foo.tar' }
        @{ Name = 'foo.txz';         Expected = 'foo.tar' }
        @{ Name = 'foo.tzst';        Expected = 'foo.tar' }
    ) {
        Get-ExpectedTarResidueName $Name | Should -Be $Expected
    }

    It 'returns nothing for non-compound-tar names' -ForEach @(
        @{ Name = 'foo.tar' }, @{ Name = 'foo.zip' }, @{ Name = 'foo.7z' }, @{ Name = 'foo.zst' }
    ) {
        Get-ExpectedTarResidueName $Name | Should -BeNullOrEmpty
    }
}

Describe 'Test-DirectoryHasExecutable' {
    It 'detects an .exe anywhere in the tree' {
        $d = Join-Path $TestDrive 'exe-tree'
        $sub = Join-Path $d 'sub'
        New-Item -ItemType Directory -Force -Path $sub | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $sub 'payload.exe') | Out-Null
        Test-DirectoryHasExecutable -Dir $d | Should -BeTrue
    }

    It 'returns false when no executable payload is present' {
        $d = Join-Path $TestDrive 'no-exe'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $d 'readme.txt') | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $d 'inner.7z')   | Out-Null
        Test-DirectoryHasExecutable -Dir $d | Should -BeFalse
    }

    It 'returns false for a missing directory' {
        Test-DirectoryHasExecutable -Dir (Join-Path $TestDrive 'does-not-exist') | Should -BeFalse
    }

    It 'detects an executable that sits alongside an archive (payload-reached signal)' {
        $d = Join-Path $TestDrive 'exe-with-arc'
        New-Item -ItemType Directory -Force -Path $d | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $d 'next.7z')   | Out-Null
        New-Item -ItemType File -Force -Path (Join-Path $d 'setup.exe') | Out-Null
        Test-DirectoryHasExecutable -Dir $d | Should -BeTrue
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
