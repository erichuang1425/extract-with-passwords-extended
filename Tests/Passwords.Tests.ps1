# Passwords.Tests.ps1 — unit tests for Modules/Passwords.ps1
#
# These functions read script-scoped configuration ($UsePasswordCache,
# $CacheFile, $PwFile, ...) and call Write-Log, so we load Config + Logging,
# point the file paths at TestDrive, and mock Write-Log.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Config']
    . $ProductionModule['Logging']
    . $ProductionModule['Passwords']
    Mock Write-Log {}
}

Describe 'Get-FileEncoding' {
    It 'detects a UTF-8 BOM' {
        $f = Join-Path $TestDrive 'utf8.txt'
        $bytes = [byte[]]@(0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes('pw')
        [IO.File]::WriteAllBytes($f, [byte[]]$bytes)
        (Get-FileEncoding -Path $f).WebName | Should -Be ([Text.Encoding]::UTF8.WebName)
    }

    It 'detects a UTF-16 LE BOM' {
        $f = Join-Path $TestDrive 'utf16le.txt'
        $bytes = [byte[]]@(0xFF, 0xFE) + [Text.Encoding]::Unicode.GetBytes('pw')
        [IO.File]::WriteAllBytes($f, [byte[]]$bytes)
        (Get-FileEncoding -Path $f).WebName | Should -Be ([Text.Encoding]::Unicode.WebName)
    }

    It 'defaults to UTF-8 when there is no BOM' {
        $f = Join-Path $TestDrive 'nobom.txt'
        [IO.File]::WriteAllBytes($f, [byte[]][Text.Encoding]::ASCII.GetBytes('plain'))
        (Get-FileEncoding -Path $f).WebName | Should -Be ([Text.Encoding]::UTF8.WebName)
    }
}

Describe 'Save-PasswordToCache / Get-CachedPasswords round-trip' {
    BeforeEach {
        Set-Variable -Name CacheFile -Value (Join-Path $TestDrive 'password-cache.txt') -Scope Script
        Set-Variable -Name UsePasswordCache -Value $true -Scope Script
        Set-Variable -Name PasswordCacheRetentionDays -Value 90 -Scope Script
        if (Test-Path -LiteralPath $CacheFile) { Remove-Item -LiteralPath $CacheFile -Force }
    }

    It 'saves a password and reads it back' {
        Save-PasswordToCache -Password 'hunter2'
        Get-CachedPasswords | Should -Contain 'hunter2'
    }

    It 'does not store duplicate passwords' {
        Save-PasswordToCache -Password 'dup'
        Save-PasswordToCache -Password 'dup'
        (@(Get-CachedPasswords) | Where-Object { $_ -eq 'dup' }).Count | Should -Be 1
    }

    It 'drops entries older than the retention window' {
        $old = (Get-Date).AddDays(-200).ToString('yyyy-MM-dd HH:mm:ss')
        $new = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Set-Content -LiteralPath $CacheFile -Value @("$old|stale", "$new|fresh") -Encoding UTF8
        $result = @(Get-CachedPasswords)
        $result | Should -Contain 'fresh'
        $result | Should -Not -Contain 'stale'
    }

    It 'returns nothing when caching is disabled' {
        Set-Variable -Name UsePasswordCache -Value $false -Scope Script
        Save-PasswordToCache -Password 'ignored'
        Get-CachedPasswords | Should -BeNullOrEmpty
    }
}

Describe 'Get-Passwords' {
    BeforeEach {
        Set-Variable -Name CacheFile -Value (Join-Path $TestDrive 'cache.txt') -Scope Script
        Set-Variable -Name PwDir -Value $TestDrive -Scope Script
        Set-Variable -Name PwFile -Value (Join-Path $TestDrive 'passwords.txt') -Scope Script
        Set-Variable -Name UsePasswordCache -Value $false -Scope Script
        Set-Variable -Name LoadAllPasswordFiles -Value $false -Scope Script
        Set-Variable -Name PasswordCacheRetentionDays -Value 90 -Scope Script
    }

    It 'loads passwords, skipping blanks and comments, and de-duplicates' {
        Set-Variable -Name TryNoPasswordFirst -Value $false -Scope Script
        Set-Content -LiteralPath $PwFile -Encoding UTF8 -Value @(
            'alpha', '# a comment', '', 'beta', 'alpha', '  gamma  '
        )
        $result = @(Get-Passwords)
        ($result -join ',') | Should -Be 'alpha,beta,gamma'
    }

    It 'prepends the empty-password slot when TryNoPasswordFirst is enabled' {
        Set-Variable -Name TryNoPasswordFirst -Value $true -Scope Script
        Set-Content -LiteralPath $PwFile -Encoding UTF8 -Value @('only')
        $result = @(Get-Passwords)
        $result[0] | Should -Be ''
        $result | Should -Contain 'only'
    }
}
