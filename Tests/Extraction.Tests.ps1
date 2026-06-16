# Extraction.Tests.ps1 — unit tests for the error classifier in Modules/Extraction.ps1
#
# Only the pure-logic classification functions are exercised here
# (Get-ExtractionErrorType / Get-LastEngineFailureType). The engine
# detection/invocation functions require a real 7-Zip/WinRAR and are not tested.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Extraction']
}

Describe 'Get-ExtractionErrorType' {
    It 'classifies a user-cancelled engine process' {
        (Get-ExtractionErrorType -ExitCode -997 -Output @()).Type | Should -Be 'Cancelled'
    }

    It 'classifies a timeout exit code' {
        (Get-ExtractionErrorType -ExitCode -998 -Output @()).Type | Should -Be 'Timeout'
    }

    It 'classifies success' {
        (Get-ExtractionErrorType -ExitCode 0 -Output @()).Type | Should -Be 'Success'
    }

    It 'classifies a missing engine from process-error output' {
        (Get-ExtractionErrorType -ExitCode -999 -Output @('The system cannot find the file specified')).Type | Should -Be 'MissingEngine'
    }

    It 'classifies a generic process error' {
        (Get-ExtractionErrorType -ExitCode -999 -Output @('boom')).Type | Should -Be 'ProcessError'
    }

    It 'classifies a wrong password' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('ERROR: Wrong password')).Type | Should -Be 'WrongPassword'
    }

    It 'classifies a missing volume' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('Cannot find volume')).Type | Should -Be 'MissingVolume'
    }

    It 'classifies a permission error' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('Access is denied')).Type | Should -Be 'PermissionDenied'
    }

    It 'classifies a corrupt archive' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('Unexpected end of archive')).Type | Should -Be 'CorruptArchive'
    }

    It 'treats CRC failure on a known-encrypted archive as a wrong password' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('CRC Failed') -ArchiveKnownEncrypted $true).Type | Should -Be 'WrongPassword'
    }

    It 'treats CRC failure on an unencrypted archive as corruption' {
        (Get-ExtractionErrorType -ExitCode 2 -Output @('CRC Failed') -ArchiveKnownEncrypted $false).Type | Should -Be 'CorruptArchive'
    }

    It 'falls back to Unknown for unrecognized output' {
        (Get-ExtractionErrorType -ExitCode 7 -Output @('something weird')).Type | Should -Be 'Unknown'
    }
}

Describe 'Get-LastEngineFailureType' {
    It 'returns nothing when no engine result has been recorded' {
        $script:LastEngineResult = $null
        Get-LastEngineFailureType | Should -BeNullOrEmpty
    }

    It 'classifies from the recorded engine result' {
        $script:LastEngineResult = @{ ExitCode = -998; Output = @() }
        Get-LastEngineFailureType | Should -Be 'Timeout'
    }

    It 'passes the encrypted hint through to the classifier' {
        $script:LastEngineResult = @{ ExitCode = 2; Output = @('CRC Failed') }
        Get-LastEngineFailureType -ArchiveKnownEncrypted $true | Should -Be 'WrongPassword'
    }
}

Describe 'Try-EnginePassword cancellation guard' {
    BeforeAll {
        # Try-EnginePassword logs via Write-Log and consults the global
        # $TryExtractEvenIfTestFails / $CleanFailedAttemptOutput switches.
        function Write-Log { param($Message, $Level) }
        $script:TryExtractEvenIfTestFails = $true
        $script:CleanFailedAttemptOutput = $false
    }

    It 'does not start a fallback 7z extraction when the token is already cancelled' {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()

        # Simulate the test process being killed by the cancel/skip token.
        Mock Test-With7z { return $false }
        Mock Extract-With7z { return $true }

        $result = Try-EnginePassword -EngineName '7-Zip' -EnginePath 'C:/7-Zip/7z.exe' `
            -Archive 'a.7z' -Password 'x' -OutputDir 'C:/out' -CanClearFailedOutput $false `
            -Timeout 0 -CancelToken $cts.Token

        $result | Should -BeFalse
        Should -Invoke Extract-With7z -Times 0 -Exactly
    }

    It 'does not start a fallback WinRAR extraction when the token is already cancelled' {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()

        Mock Test-WithWinRar { return $false }
        Mock Extract-WithWinRar { return $true }

        $result = Try-EnginePassword -EngineName 'WinRAR' -EnginePath 'C:/WinRAR/WinRAR.exe' `
            -Archive 'a.rar' -Password 'x' -OutputDir 'C:/out' -CanClearFailedOutput $false `
            -Timeout 0 -CancelToken $cts.Token

        $result | Should -BeFalse
        Should -Invoke Extract-WithWinRar -Times 0 -Exactly
    }
}

Describe 'Try-EnginePassword compound-tar cancellation cleanup' {
    BeforeAll {
        function Write-Log { param($Message, $Level) }
        # Stubs for the cross-module helpers Try-EnginePassword calls on the
        # compound-tar path, so they can be mocked here.
        function Test-IsCompoundTarArchive { param($Archive) $true }
        function Expand-CompoundTarResidue { return $true }
        function Clear-AttemptOutput { param($OutputDir) }
        $script:TryExtractEvenIfTestFails = $true
        $script:CleanFailedAttemptOutput = $true
    }

    It 'clears partial output when Skip/Cancel interrupts residue expansion' {
        $cts = New-Object System.Threading.CancellationTokenSource
        $cts.Cancel()

        Mock Test-With7z { return $true }
        Mock Extract-With7z { return $true }
        Mock Test-IsCompoundTarArchive { return $true }
        # Forwarded cancel token makes the inner residue expansion fail.
        Mock Expand-CompoundTarResidue { return $false }
        Mock Clear-AttemptOutput {}

        $result = Try-EnginePassword -EngineName '7-Zip' -EnginePath 'C:/7-Zip/7z.exe' `
            -Archive 'a.tar.zst' -Password 'x' -OutputDir 'C:/out' -CanClearFailedOutput $true `
            -Timeout 0 -CancelToken $cts.Token

        $result | Should -BeFalse
        Should -Invoke Clear-AttemptOutput -Times 1 -Exactly
    }

    It 'leaves the recovered outer layer in place for a genuine partial extraction' {
        # Not cancelled: residue expansion fails on its own merits.
        Mock Test-With7z { return $true }
        Mock Extract-With7z { return $true }
        Mock Test-IsCompoundTarArchive { return $true }
        Mock Expand-CompoundTarResidue { return $false }
        Mock Clear-AttemptOutput {}

        $result = Try-EnginePassword -EngineName '7-Zip' -EnginePath 'C:/7-Zip/7z.exe' `
            -Archive 'a.tar.zst' -Password 'x' -OutputDir 'C:/out' -CanClearFailedOutput $true `
            -Timeout 0

        $result | Should -BeFalse
        Should -Invoke Clear-AttemptOutput -Times 0 -Exactly
    }
}

Describe 'Get-EngineName' {
    It 'maps engine executables to display names' -ForEach @(
        @{ Path = 'C:/WinRAR/UnRAR.exe'; Expected = 'UnRAR' }
        @{ Path = 'C:/WinRAR/Rar.exe';   Expected = 'Rar' }
        @{ Path = 'C:/WinRAR/WinRAR.exe'; Expected = 'WinRAR' }
        @{ Path = 'C:/7-Zip/7z.exe';      Expected = '7-Zip' }
        @{ Path = 'C:/PeaZip/res/bin/7z/7z.exe'; Expected = 'PeaZip bundled 7z' }
    ) {
        Get-EngineName -Path $Path | Should -Be $Expected
    }

    It 'returns None for an empty path' {
        Get-EngineName -Path '' | Should -Be 'None'
    }
}

Describe 'Test-EngineWorks (WinRAR GUI)' {
    It 'treats a present WinRAR.exe as working without launching it' {
        $dummy = Join-Path $TestDrive 'WinRAR.exe'
        New-Item -ItemType File -Force -Path $dummy | Out-Null
        Test-EngineWorks -EnginePath $dummy | Should -BeTrue
    }

    It 'returns false for a missing path' {
        Test-EngineWorks -EnginePath '' | Should -BeFalse
    }
}

Describe 'Get-EnginePlanForArchive WinRAR fallback' {
    BeforeAll {
        # Get-EnginePlanForArchive needs Test-IsRarLike (ArchiveUtils) and the
        # engine-enable config switches.
        . $ProductionModule['ArchiveUtils']
        $script:UseSevenZip = $true
        $script:UseWinRarFallback = $true
        $script:UsePeaZipBundled7zFallback = $true

        # Fake WinRAR install dir with both the console and GUI binaries.
        $script:wrDir = Join-Path $TestDrive 'WinRAR'
        New-Item -ItemType Directory -Force -Path $script:wrDir | Out-Null
        $script:unrar = Join-Path $script:wrDir 'UnRAR.exe'
        $script:winrarGui = Join-Path $script:wrDir 'WinRAR.exe'
        New-Item -ItemType File -Force -Path $script:unrar | Out-Null
        New-Item -ItemType File -Force -Path $script:winrarGui | Out-Null
    }

    It 'uses console UnRAR for a RAR archive and does not pull in the GUI' {
        $paths = @((Get-EnginePlanForArchive -Archive 'a.rar' -SevenZip $null -PeaZip7z $null -WinRar $script:unrar) | ForEach-Object { $_.Path })
        $paths | Should -Contain $script:unrar
        $paths | Should -Not -Contain $script:winrarGui
    }

    It 'falls back to the sibling WinRAR.exe for a ZIP when no 7-Zip/PeaZip is available' {
        $paths = @((Get-EnginePlanForArchive -Archive 'a.zip' -SevenZip $null -PeaZip7z $null -WinRar $script:unrar) | ForEach-Object { $_.Path })
        $paths | Should -Contain $script:winrarGui
    }

    It 'does not add WinRAR.exe for a ZIP when 7-Zip is available' {
        $paths = @((Get-EnginePlanForArchive -Archive 'a.zip' -SevenZip 'C:/7-Zip/7z.exe' -PeaZip7z $null -WinRar $script:unrar) | ForEach-Object { $_.Path })
        $paths | Should -Not -Contain $script:winrarGui
        $paths | Should -Contain 'C:/7-Zip/7z.exe'
    }
}
