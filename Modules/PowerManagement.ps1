# PowerManagement.ps1 — keep the system awake during long extraction runs

# Windows SetThreadExecutionState flags. NOTE: 0x80000000 is written in decimal
# because PowerShell parses the 8-hex-digit literal 0x80000000 as a negative
# Int32 (sign bit set), which then overflows a [uint32] cast.
$script:ES_CONTINUOUS        = [uint32]2147483648   # 0x80000000
$script:ES_SYSTEM_REQUIRED   = [uint32]1            # 0x00000001
$script:ES_AWAYMODE_REQUIRED = [uint32]64           # 0x00000040

$script:KeepAwakeActive    = $false
$script:KeepAwakeAvailable = $true

function Initialize-KeepAwakeType {
    # Loads the kernel32 P/Invoke type exactly once. Returns $true if usable.
    if (-not $script:KeepAwakeAvailable) { return $false }

    # Only meaningful on Windows.
    if ($PSVersionTable.PSObject.Properties['Platform'] -and $PSVersionTable.Platform -ne 'Win32NT') {
        $script:KeepAwakeAvailable = $false
        return $false
    }

    if (([System.Management.Automation.PSTypeName]'ArchivePwExtract.Power').Type) {
        return $true
    }

    try {
        Add-Type -Namespace 'ArchivePwExtract' -Name 'Power' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern uint SetThreadExecutionState(uint esFlags);
'@
        return $true
    } catch {
        $script:KeepAwakeAvailable = $false
        try { Write-Log "Keep-awake unavailable: $($_.Exception.Message)" "WARN" } catch {}
        return $false
    }
}

function Enable-KeepAwake {
    # Ask Windows not to idle-sleep the system while extraction runs. The display
    # is intentionally NOT pinned on (no ES_DISPLAY_REQUIRED) so the screen can
    # still sleep. Safe no-op on non-Windows / older PowerShell.
    if (-not (Initialize-KeepAwakeType)) { return }

    try {
        $flags = [uint32]($script:ES_CONTINUOUS -bor $script:ES_SYSTEM_REQUIRED -bor $script:ES_AWAYMODE_REQUIRED)
        [void][ArchivePwExtract.Power]::SetThreadExecutionState($flags)
        $script:KeepAwakeActive = $true
        try { Write-Log "Keep-awake enabled (system will not idle-sleep during extraction)." } catch {}
    } catch {
        try { Write-Log "Could not enable keep-awake: $($_.Exception.Message)" "WARN" } catch {}
    }
}

function Disable-KeepAwake {
    # Clear the continuous keep-awake request, restoring normal sleep behavior.
    # Self-guarding: a no-op if keep-awake was never enabled.
    if (-not $script:KeepAwakeActive) { return }

    try {
        [void][ArchivePwExtract.Power]::SetThreadExecutionState([uint32]$script:ES_CONTINUOUS)
        try { Write-Log "Keep-awake disabled." } catch {}
    } catch {
        try { Write-Log "Could not disable keep-awake: $($_.Exception.Message)" "WARN" } catch {}
    } finally {
        $script:KeepAwakeActive = $false
    }
}
