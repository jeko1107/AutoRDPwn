# Tests\Runtime.Tests.ps1
#
# Structural contracts in src\01-core.ps1. Both are read with the AST, so the
# tests stay valid while the runtime is rewritten: they assert that the work is
# still reachable, not that it is written in one particular way.

Describe 'cleanup' {

    $function = Get-ArFunctionAst -Name 'Invoke-ARCleanup'

    It 'defines Invoke-ARCleanup in src' {
        Assert-NotNull $function 'Invoke-ARCleanup is not defined in any src\*.ps1; the finally block in 03-main.ps1 would fail'
    }

    if ($null -ne $function) {
        # Not $body: It() has a $Block parameter, but sibling helpers still pass
        # $Body around, and dynamic scoping would win.
        $functionBody = $function.Ast.Body
        # The "-noclean" guard skips the branch that talks to the target. Anything
        # inside that branch must not be the only cleanup of operator-side traces.
        $guarded = @(Get-ArGuardedRanges -Ast $functionBody -ConditionPattern 'ARNoClean')

        # Without this the three tests below pass vacuously if the guard is
        # renamed or removed.
        It 'guards target cleanup behind -noclean' {
            Assert-True ($guarded.Count -gt 0) `
                'Invoke-ARCleanup has no if(-not $script:ARNoClean) branch; the -noclean contract cannot be checked'
        }

        It 'removes stored cmdkey credentials outside -noclean' {
            $found = Test-ArAstMarkerOutsideRanges -Ast $functionBody -Ranges $guarded -Matcher {
                param($node)
                ($node -is [System.Management.Automation.Language.CommandAst]) -and
                ($node.GetCommandName() -match '^cmdkey(\.exe)?$')
            }
            Assert-True $found 'cmdkey "/delete:" runs only inside the -noclean branch; stored credentials would survive Invoke-ARCleanup'
        }

        It 'restores Defender preferences outside -noclean' {
            $found = Test-ArAstMarkerOutsideRanges -Ast $functionBody -Ranges $guarded -Matcher {
                param($node)
                if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
                return ($node.GetCommandName() -match '^((Restore|Remove)-ARDefender|Remove-MpPreference)$')
            }
            Assert-True $found 'Defender exclusions are restored only inside the -noclean branch; they would outlive the session'
        }

        It 'deletes local work directories outside -noclean' {
            $found = Test-ArAstMarkerOutsideRanges -Ast $functionBody -Ranges $guarded -Matcher {
                param($node)
                if ($node -is [System.Management.Automation.Language.ForEachStatementAst]) {
                    return ($node.Condition.Extent.Text -match 'ARWorkDirs') -and ($node.Body.Extent.Text -match 'Remove-Item')
                }
                return $false
            }
            Assert-True $found 'no loop over $script:ARWorkDirs removing the directories outside the -noclean branch; temporary work directories would be left on disk'
        }

        It 'keeps cleanup idempotent' {
            $found = Test-ArAstMarkerOutsideRanges -Ast $functionBody -Ranges @() -Matcher {
                param($node)
                ($node -is [System.Management.Automation.Language.VariableExpressionAst]) -and
                ($node.VariablePath.UserPath -match 'ARCleanupDone')
            }
            Assert-True $found 'Invoke-ARCleanup no longer checks ARCleanupDone; a double call (option mode + finally) would re-run the teardown'
        }
    }
}

Describe 'option mode' {

    # -option is the non-interactive entry point. A prompt in that mode hangs a
    # CI job or an unattended run, so both input helpers must refuse to prompt.
    foreach ($name in @('Read-ARValue', 'Read-ARSecret')) {
        $functionName = $name
        It ($functionName + ' refuses to prompt in -option mode') {
            $function = Get-ArFunctionAst -Name $functionName
            Assert-NotNull $function ("{0} is not defined in any src\*.ps1" -f $functionName)
            $body = $function.Ast.Body

            $referencesFlag = @($body.FindAll({
                        param($node)
                        ($node -is [System.Management.Automation.Language.VariableExpressionAst]) -and
                        ($node.VariablePath.UserPath -match 'ARInvokedFromOption')
                    }, $true))
            Assert-True ($referencesFlag.Count -gt 0) `
                ("{0} never reads \$script:ARInvokedFromOption; -option runs would block on a prompt" -f $functionName)

            $guards = @($body.FindAll({
                        param($node)
                        if ($node -isnot [System.Management.Automation.Language.IfStatementAst]) { return $false }
                        foreach ($clause in $node.Clauses) {
                            if ($clause.Item1.Extent.Text -match 'ARInvokedFromOption') { return $true }
                        }
                        return $false
                    }, $true))
            Assert-True ($guards.Count -gt 0) `
                ("{0} reads ARInvokedFromOption but has no if() guard around it; the value is never acted on" -f $functionName)

            $throws = 0
            foreach ($guard in $guards) {
                $throws += @($guard.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.ThrowStatementAst]
                        }, $true)).Count
            }
            Assert-True ($throws -gt 0) `
                ("{0} has an ARInvokedFromOption guard that does not throw; -option mode would fall through to an interactive prompt" -f $functionName)
        }
    }
}
