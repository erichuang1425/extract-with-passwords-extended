# PowerManagement.Tests.ps1 — behavioral tests for the keep-awake helpers.
#
# These assert the functions are safe to call (no throw) and idempotent. The
# underlying SetThreadExecutionState call has no observable return worth
# asserting, and the type-load is guarded to be a no-op off Windows.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    . $ProductionModule['PowerManagement']
    # The module logs via Write-Log (from the Logging module); stub it.
    function Write-Log { param($Message, $Level) }
}

Describe 'Keep-awake lifecycle' {
    It 'Disable-KeepAwake is a no-op when never enabled' {
        { Disable-KeepAwake } | Should -Not -Throw
    }

    It 'Enable-KeepAwake does not throw' {
        { Enable-KeepAwake } | Should -Not -Throw
    }

    It 'Enable then Disable does not throw' {
        { Enable-KeepAwake; Disable-KeepAwake } | Should -Not -Throw
    }

    It 'Enable twice does not throw (type-load guard)' {
        { Enable-KeepAwake; Enable-KeepAwake } | Should -Not -Throw
        Disable-KeepAwake
    }
}
