# PSScriptAnalyzer settings for AutoRDPwn (v6.0).
# Error and Warning findings are surfaced; only Error fails the lint job.

@{
    IncludeRules = @(
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingInvokeExpression',
        'PSAvoidGlobalVars',
        'PSUseShouldProcessForStateChangingFunctions',
        'PSAvoidUsingComputerNameHardcoded'
    )

    ExcludeRules = @(
        # The TUI writes to the console on purpose, so this one is excluded.
        'PSAvoidUsingWriteHost',
        # The project prefixes its helper functions with AR, so approved verbs are not wanted here.
        'PSUseApprovedVerbs'
    )

    Severity = @('Error', 'Warning')

    Rules = @{
        PSPlaceOpenBrace = @{ Enable = $true; OnSameLine = $true }
        PSPlaceCloseBrace = @{ Enable = $true; NewLineAfter = $true }
        PSUseConsistentIndentation = @{ Enable = $true; IndentationSize = 4; Kind = 'space' }
    }
}
