# NestedExtraction.Tests.ps1 — unit tests for recursive nested extraction orchestration.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['NestedExtraction']

    function Write-Status { param($Message, $Kind) }
    function Write-Log { param($Message, $Level) }
    function Find-NestedArchives { param($Root) }
    function Test-DirectoryHasExecutable { param($Dir, [switch]$IgnoreRedist) }
    function Get-CanonicalArchiveName { param($Name) }
    function Restore-MangledArchiveName { param($Current, $Original) return $Current }
    function Get-EnginePlanForArchive { param($Archive, $SevenZip, $PeaZip7z, $WinRar) }
    function Get-ArchiveBaseName { param($Path) }
    function Resolve-OutputDir { param($BaseDir, $IsSharedOutput, $BehaviorOverride) }
    function Test-IsEncryptionCapable { param($Path) }
    function Get-PasswordTryOrder { param($Passwords, $PreferredFirst) }
    function Try-EnginePassword { param($EngineName, $EnginePath, $Archive, $Password, $OutputDir, $CanClearFailedOutput, $OmitPasswordArg, $Timeout, $TestOnly, $CancelToken) }
    function Save-PasswordToCache { param($Password) }
    function Remove-EmptyOutputDir { param($OutputDir, $SeparateFolders) }
    function Get-LastEngineFailureType { param($ArchiveKnownEncrypted) }

    $script:DeleteNestedArchiveAfterExtract = $false
}

Describe 'Invoke-NestedExtractionPass cancellation' {
    BeforeEach {
        $script:observedCancelToken = $null

        Mock Find-NestedArchives { return @('C:/seed/inner.zip') }
        Mock Test-DirectoryHasExecutable { return $false }
        Mock Get-EnginePlanForArchive { return @(@{ Name = '7-Zip'; Path = 'C:/7z.exe' }) }
        Mock Get-ArchiveBaseName { return 'inner' }
        Mock Resolve-OutputDir { return 'C:/seed/inner' }
        Mock Test-IsEncryptionCapable { return $false }
        Mock Try-EnginePassword {
            $script:observedCancelToken = $CancelToken
            return $true
        }
    }

    It 'forwards the cancellation token into nested engine attempts' {
        $cts = New-Object System.Threading.CancellationTokenSource

        $results = @(Invoke-NestedExtractionPass `
            -SeedFolders @('C:/seed') `
            -Passwords @('pw') `
            -SevenZip 'C:/7z.exe' `
            -PeaZip7z $null `
            -WinRar $null `
            -MaxDepth 1 `
            -Timeout 12 `
            -CancelToken $cts.Token)

        $results.Count | Should -Be 1
        $script:observedCancelToken | Should -Be $cts.Token
    }

    It 'stops before scanning queued folders once cancellation is requested' {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()

        $results = @(Invoke-NestedExtractionPass `
            -SeedFolders @('C:/seed') `
            -Passwords @('pw') `
            -SevenZip 'C:/7z.exe' `
            -PeaZip7z $null `
            -WinRar $null `
            -MaxDepth 1 `
            -CancelToken $cts.Token)

        $results.Count | Should -Be 0
        Should -Invoke Find-NestedArchives -Times 0 -Exactly
        Should -Invoke Try-EnginePassword -Times 0 -Exactly
    }

    It 'reports a nested archive cancelled mid-attempt as Skipped, not Failed' {
        $cts = New-Object System.Threading.CancellationTokenSource
        $script:cancelSource = $cts

        Mock Test-IsEncryptionCapable { return $true }
        Mock Get-PasswordTryOrder { return @('pw') }
        Mock Remove-EmptyOutputDir { }
        Mock Get-LastEngineFailureType { return 'WrongPassword' }
        # Simulate the user pressing Skip/Cancel while the engine attempt runs:
        # the token flips to cancelled and the attempt returns failure.
        Mock Try-EnginePassword {
            $script:cancelSource.Cancel()
            return $false
        }

        $results = @(Invoke-NestedExtractionPass `
            -SeedFolders @('C:/seed') `
            -Passwords @('pw') `
            -SevenZip 'C:/7z.exe' `
            -PeaZip7z $null `
            -WinRar $null `
            -MaxDepth 1 `
            -CancelToken $cts.Token)

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Skipped'
        $results[0].Reason | Should -Be 'Cancelled'
    }
}

Describe 'Invoke-NestedExtractionPass reverts unverified mangled renames' {
    BeforeEach {
        $script:restoreArgs = $null

        Mock Find-NestedArchives { return @('C:\seed\asset_zip') }
        Mock Test-DirectoryHasExecutable { return $false }
        # Simulate the mangled-name heuristic matching a non-archive payload file
        # (e.g. "asset_zip") that happens to look like a mangled archive name.
        Mock Get-CanonicalArchiveName { return 'asset.zip' }
        Mock Test-Path { return $false }
        Mock Rename-Item { }
        Mock Get-EnginePlanForArchive { return @(@{ Name = '7-Zip'; Path = 'C:/7z.exe' }) }
        Mock Get-ArchiveBaseName { return 'asset' }
        Mock Resolve-OutputDir { return 'C:\seed\asset' }
        Mock Test-IsEncryptionCapable { return $false }
        Mock Remove-EmptyOutputDir { }
        Mock Get-LastEngineFailureType { return 'ExtractionFailed' }
        # The engine can never actually extract it (it isn't really an archive).
        Mock Try-EnginePassword { return $false }
        Mock Restore-MangledArchiveName {
            param($Current, $Original)
            $script:restoreArgs = @{ Current = $Current; Original = $Original }
            return $Original
        }
    }

    It 'reverts the rename and reports the original path when the renamed candidate cannot be extracted' {
        $results = @(Invoke-NestedExtractionPass `
            -SeedFolders @('C:\seed') `
            -Passwords @('') `
            -SevenZip 'C:/7z.exe' `
            -PeaZip7z $null `
            -WinRar $null `
            -MaxDepth 1)

        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Failed'
        $results[0].Archive | Should -Be 'C:\seed\asset_zip'

        $script:restoreArgs.Current | Should -Be 'C:\seed\asset.zip'
        $script:restoreArgs.Original | Should -Be 'C:\seed\asset_zip'
    }
}
