# Passwords.Tests.ps1 — unit tests for Modules/Passwords.ps1
#
# These functions read script-scoped configuration ($UsePasswordCache,
# $CacheFile, $PwFile, ...) via dynamic scope and call Write-Log. Inputs are
# set through a Set-Cfg helper defined in the same BeforeAll as the dot-sourced
# functions, so the variables land in a scope those functions can see (setting
# them with '-Scope Script' from inside an It does not reach them under
# Pester 5). File paths point at TestDrive and Write-Log is mocked.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['Config']
    . $ProductionModule['Logging']
    . $ProductionModule['Passwords']
    Mock Write-Log {}

    function Set-Cfg { param([string]$Name, $Value) Set-Variable -Name $Name -Value $Value -Scope Script }
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
        Set-Cfg CacheFile (Join-Path $TestDrive 'password-cache.txt')
        Set-Cfg UsePasswordCache $true
        Set-Cfg PasswordCacheRetentionDays 90
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
        Set-Cfg UsePasswordCache $false
        Save-PasswordToCache -Password 'ignored'
        Get-CachedPasswords | Should -BeNullOrEmpty
    }
}

Describe 'Get-Passwords' {
    BeforeEach {
        Set-Cfg CacheFile (Join-Path $TestDrive 'cache.txt')
        Set-Cfg PwDir $TestDrive
        Set-Cfg PwFile (Join-Path $TestDrive 'passwords.txt')
        Set-Cfg UsePasswordCache $false
        Set-Cfg LoadAllPasswordFiles $false
        Set-Cfg PasswordCacheRetentionDays 90
    }

    It 'loads passwords, skipping blanks and comments, and de-duplicates' {
        Set-Cfg TryNoPasswordFirst $false
        Set-Content -LiteralPath $PwFile -Encoding UTF8 -Value @(
            'alpha', '# a comment', '', 'beta', 'alpha', '  gamma  '
        )
        $result = @(Get-Passwords)
        ($result -join ',') | Should -Be 'alpha,beta,gamma'
    }

    It 'prepends the empty-password slot when TryNoPasswordFirst is enabled' {
        Set-Cfg TryNoPasswordFirst $true
        Set-Content -LiteralPath $PwFile -Encoding UTF8 -Value @('only')
        $result = @(Get-Passwords)
        $result[0] | Should -Be ''
        $result | Should -Contain 'only'
    }
}
