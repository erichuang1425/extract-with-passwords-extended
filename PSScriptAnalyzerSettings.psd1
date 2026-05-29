@{
    # PSScriptAnalyzer configuration for extract-with-passwords-extended.
    #
    # This is an interactive console tool, so some default rules are excluded
    # by design rather than "fixed":
    #   - PSAvoidUsingWriteHost: Write-Host is the intended UI surface.
    #   - PSUseApprovedVerbs: existing public function names (Sanitize-, Redact-,
    #     Try-, Extract-, ...) are part of the tool's established API.
    #   - PSUseShouldProcessForStateChangingFunctions: the tool is not a module
    #     of reusable cmdlets and does not implement -WhatIf/-Confirm.
    #
    # The Severity filter is intentionally NOT set: restricting it drops
    # ParseError records (and 'ParseError' is not a valid -Severity value),
    # so the analyzer returns all severities and the CI gate decides what
    # blocks. CI fails on ParseError/Error findings; Warnings/Information are
    # reported but non-blocking for now (tightening is a planned follow-up).

    ExcludeRules = @(
        'PSAvoidUsingWriteHost',
        'PSUseApprovedVerbs',
        'PSUseShouldProcessForStateChangingFunctions',
        # Singular-noun guidance conflicts with several established names.
        'PSUseSingularNouns'
    )
}
