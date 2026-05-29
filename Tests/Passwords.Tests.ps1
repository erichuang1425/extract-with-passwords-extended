# Passwords.Tests.ps1 — unit tests for Modules/Passwords.ps1
#
# The password helpers read script-scoped config ($UsePasswordCache, $CacheFile,
# ...) and call Write-Log. To set that state reliably under Pester 5 we load
# Config + Logging + Passwords as a single dynamic module and exercise the
# functions from InModuleScope, where $script: assignments and the functions'
# variable lookups share the module's script scope. Write-Log is mocked inside
# the module (it would otherwise append to an unset $RunLogPath). Temp files are
# created from the system temp dir inside the module scope (avoids depending on
# $TestDrive visibility or the InModuleScope -Parameters feature).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $src = @(
        (Get-Content -Raw -LiteralPath $ProductionModule['Config']),
        (Get-Content -Raw -LiteralPath $ProductionModule['Logging']),
        (Get-Content -Raw -LiteralPath $ProductionModule['Passwords'])
    ) -join "`r`n"
    New-Module -Name PwUnderTest -ScriptBlock ([scriptblock]::Create($src)) | Import-Module -Force
}

AfterAll {
    Remove-Module PwUnderTest -Force -ErrorAction SilentlyContinue
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
    It 'saves a password and reads it back' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                Save-PasswordToCache -Password 'hunter2'
                Get-CachedPasswords | Should -Contain 'hunter2'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'does not store duplicate passwords' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                Save-PasswordToCache -Password 'dup'
                Save-PasswordToCache -Password 'dup'
                (@(Get-CachedPasswords) | Where-Object { $_ -eq 'dup' }).Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'drops entries older than the retention window' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                $old = (Get-Date).AddDays(-200).ToString('yyyy-MM-dd HH:mm:ss')
                $new = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                Set-Content -LiteralPath $script:CacheFile -Value @("$old|stale", "$new|fresh") -Encoding UTF8
                $result = @(Get-CachedPasswords)
                $result | Should -Contain 'fresh'
                $result | Should -Not -Contain 'stale'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'returns nothing when caching is disabled' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $false
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                Save-PasswordToCache -Password 'ignored'
                Get-CachedPasswords | Should -BeNullOrEmpty
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Get-Passwords' {
    It 'loads passwords, skipping blanks and comments, and de-duplicates' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $false
                $script:LoadAllPasswordFiles = $false
                $script:PasswordCacheRetentionDays = 90
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PwDir = $dir
                $script:PwFile = Join-Path $dir 'passwords.txt'
                $script:TryNoPasswordFirst = $false
                Set-Content -LiteralPath $script:PwFile -Encoding UTF8 -Value @(
                    'alpha', '# a comment', '', 'beta', 'alpha', '  gamma  '
                )
                $result = @(Get-Passwords)
                ($result -join ',') | Should -Be 'alpha,beta,gamma'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'prepends the empty-password slot when TryNoPasswordFirst is enabled' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $false
                $script:LoadAllPasswordFiles = $false
                $script:PasswordCacheRetentionDays = 90
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PwDir = $dir
                $script:PwFile = Join-Path $dir 'passwords.txt'
                $script:TryNoPasswordFirst = $true
                Set-Content -LiteralPath $script:PwFile -Encoding UTF8 -Value @('only')
                $result = @(Get-Passwords)
                $result[0] | Should -Be ''
                $result | Should -Contain 'only'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

Describe 'Password cache concurrency safety' {
    It 'does not throw when CacheFile is unset (parallel-worker regression)' {
        InModuleScope PwUnderTest {
            Mock Write-Log {}
            $script:UsePasswordCache = $true
            $script:CacheFile = $null
            { Save-PasswordToCache -Password 'x' } | Should -Not -Throw
        }
    }

    It 'saves and reads back through the mutex (happy path unchanged)' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                Save-PasswordToCache -Password 'mutexpw'
                Get-CachedPasswords | Should -Contain 'mutexpw'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'repeated saves of the same password produce exactly one data line' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                1..5 | ForEach-Object { Save-PasswordToCache -Password 'same' }
                (@(Get-CachedPasswords) | Where-Object { $_ -eq 'same' }).Count | Should -Be 1
                (@(Get-Content -LiteralPath $script:CacheFile) | Where-Object { $_ -match '\|same$' }).Count | Should -Be 1
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It 'Get-CacheMutexName is stable and free of invalid characters' {
        InModuleScope PwUnderTest {
            $script:CacheFile = 'C:\some\password-cache.txt'
            $n1 = Get-CacheMutexName
            $n2 = Get-CacheMutexName
            $n1 | Should -Be $n2
            $n1 | Should -Match '^Local\\TryPwExtract_PwCache_[0-9A-F]+$'
        }
    }

    It 'Enter-CacheLock acquires and Exit-CacheLock releases (re-acquirable)' {
        InModuleScope PwUnderTest {
            $script:CacheFile = Join-Path ([IO.Path]::GetTempPath()) 'lock-probe.txt'
            $lock1 = Enter-CacheLock
            $lock1.Acquired | Should -BeTrue
            Exit-CacheLock $lock1
            # A second acquire only succeeds promptly if the first was released.
            $lock2 = Enter-CacheLock
            $lock2.Acquired | Should -BeTrue
            Exit-CacheLock $lock2
        }
    }
}

Describe 'Get-CachedPasswords malformed-line handling' {
    It 'surfaces only the password portion when the timestamp is unparseable' {
        InModuleScope PwUnderTest {
            $dir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid())
            New-Item -ItemType Directory -Path $dir | Out-Null
            try {
                Mock Write-Log {}
                $script:UsePasswordCache = $true
                $script:CacheFile = Join-Path $dir 'cache.txt'
                $script:PasswordCacheRetentionDays = 90
                Set-Content -LiteralPath $script:CacheFile -Value @('notadate|secret') -Encoding UTF8
                $result = @(Get-CachedPasswords)
                $result | Should -Contain 'secret'
                $result | Should -Not -Contain 'notadate|secret'
            } finally {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
