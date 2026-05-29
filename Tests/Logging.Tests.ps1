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
