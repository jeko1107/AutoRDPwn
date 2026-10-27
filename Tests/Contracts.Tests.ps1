# Tests\Contracts.Tests.ps1
#
# Static contracts for the v6.0 hardening work: target cleanup, MSI uninstall,
# stored credentials, firewall registration, cleanup hooks, exit codes, TUI input
# safety, language persistence, the screen route and the version stamp.
#
# Every check reads src\*.ps1, Resources\Scripts\Invoke-StealthScreen.ps1 or the
# repository files as text/AST. Nothing here loads src\, runs a catalog action or
# touches the network, so the suite stays valid while the files are edited.
#
# Each failure names the file, the pattern and the regression it guards.

# --------------------------------------------------------------------------- #
# helpers - local to this file, same style as Regressions.Tests.ps1
# --------------------------------------------------------------------------- #

function Get-ArContractText {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    return (Get-Content -LiteralPath $Path -Raw)
}

function Get-ArContractLines {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path)
}

# Zero-based indexes of the lines matching a pattern.
function Get-ArContractPatternIndexes {
    param([string[]]$Lines, [Parameter(Mandatory = $true)][string]$Pattern)
    $indexes = New-Object System.Collections.ArrayList
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $Pattern) { $null = $indexes.Add($index) }
    }
    return @($indexes.ToArray())
}

# True when a function/scriptblock contains an if (Get-Command <Name>) guard whose
# branch calls <Name>. Structural, so a renamed local alias does not fool it.
function Test-ArContractGuardedCall {
    param([Parameter(Mandatory = $true)]$Body, [Parameter(Mandatory = $true)][string]$CommandName)
    $statements = @($Body.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.IfStatementAst]
            }, $true))
    foreach ($statement in $statements) {
        foreach ($clause in @($statement.Clauses)) {
            $parts = Get-ArIfClauseParts -Clause $clause
            if ($null -eq $parts.Condition) { continue }
            if ($parts.Condition.Extent.Text -notmatch 'Get-Command') { continue }
            if ($parts.Condition.Extent.Text -notmatch [regex]::Escape($CommandName)) { continue }
            foreach ($inner in @($parts.Statements)) {
                if ($null -eq $inner) { continue }
                foreach ($call in @($inner.FindAll({
                                param($node)
                                $node -is [System.Management.Automation.Language.CommandAst]
                            }, $true))) {
                    if ($call.GetCommandName() -eq $CommandName) { return $true }
                }
            }
        }
    }
    return $false
}

# First if-statement whose condition matches a pattern. The condition text is
# read through Get-ArIfClauseParts so PS 5.1 and PS 7 clause shapes both work.
function Get-ArContractIfStatement {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][string]$ConditionPattern)
    foreach ($node in @($Ast.FindAll({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.IfStatementAst]
                }, $true))) {
        foreach ($clause in @($node.Clauses)) {
            $parts = Get-ArIfClauseParts -Clause $clause
            if ($null -ne $parts.Condition -and $parts.Condition.Extent.Text -match $ConditionPattern) {
                return $node
            }
        }
    }
    return $null
}

# Variable names whose value comes from a Read-* command, followed transitively
# through $value = $answer.Trim()-style assignments. Used to prove the menu no
# longer casts raw input with [int].
function Get-ArContractReadDerivedNames {
    param([Parameter(Mandatory = $true)]$Ast)
    $derived = New-Object 'System.Collections.Generic.HashSet[string]'
    $assignments = @($Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst]
            }, $true))
    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($assignment in $assignments) {
            if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $name = $assignment.Left.VariablePath.UserPath
            if ($derived.Contains($name)) { continue }
            $isRead = $false
            foreach ($command in @($assignment.Right.FindAll({
                            param($node)
                            $node -is [System.Management.Automation.Language.CommandAst]
                        }, $true))) {
                if ($command.GetCommandName() -match '^Read-') { $isRead = $true; break }
            }
            if (-not $isRead) {
                foreach ($variable in @($assignment.Right.FindAll({
                                param($node)
                                $node -is [System.Management.Automation.Language.VariableExpressionAst]
                            }, $true))) {
                    if ($derived.Contains($variable.VariablePath.UserPath)) { $isRead = $true; break }
                }
            }
            if ($isRead) {
                $null = $derived.Add($name)
                $changed = $true
            }
        }
    }
    return @($derived)
}

# FunctionDefinitionAst count for one name across src\*.ps1, with the files.
function Get-ArContractDefinitionCount {
    param([Parameter(Mandatory = $true)][string]$Name)
    $target = $Name
    $count = 0
    $files = New-Object System.Collections.ArrayList
    foreach ($source in @(Get-ArSourceAsts)) {
        $matches = @($source.Ast.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $target)
                }, $true))
        if ($matches.Count -eq 0) { continue }
        $count += $matches.Count
        $null = $files.Add($source.File)
    }
    return [pscustomobject]@{ Count = $count; Files = @($files.ToArray()) }
}

# Innermost function that contains a line. A resolver follows the nearest
# assignment in the same function, so a same-named variable in another function
# higher in the file cannot answer for it.
function Get-ArContractScope {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][int]$Line)
    $scope = $Ast
    $size = [int]$Ast.Extent.EndOffset - [int]$Ast.Extent.StartOffset
    foreach ($node in @($Ast.FindAll({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.FunctionDefinitionAst]
                }, $true))) {
        if ([int]$node.Extent.StartLineNumber -gt $Line) { continue }
        if ([int]$node.Extent.EndLineNumber -lt $Line) { continue }
        $nodeSize = [int]$node.Extent.EndOffset - [int]$node.Extent.StartOffset
        if ($nodeSize -lt $size) { $scope = $node; $size = $nodeSize }
    }
    return $scope
}

# Rule name held by an expression: a literal, a Get-ARText lookup, a [string] cast
# or a variable. $null means the name is computed and cannot be proven equal to a
# registration, which the caller reports as a failure.
function Get-ArContractRuleNameValue {
    param($Ast, $Expression, [int]$Line, [int]$Depth = 0)
    if ($null -eq $Expression) { return $null }
    if ($Depth -gt 8) { return $null }

    # $x = 'literal' parses as a command expression around the string.
    if ($Expression -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return (Get-ArContractRuleNameValue -Ast $Ast -Expression $Expression.Expression -Line $Line -Depth ($Depth + 1))
    }

    # $x = Get-ARText 'key' 'literal' parses as a one-element pipeline.
    if ($Expression -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($Expression.PipelineElements)
        if ($elements.Count -ne 1) { return $null }
        return (Get-ArContractRuleNameValue -Ast $Ast -Expression $elements[0] -Line $Line -Depth ($Depth + 1))
    }

    if ($Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [string]$Expression.Value
    }

    if ($Expression -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        return (Get-ArContractRuleNameValue -Ast $Ast -Expression $Expression.Child -Line $Line -Depth ($Depth + 1))
    }

    if ($Expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return (Get-ArContractRuleNameVariable -Ast $Ast -Name $Expression.VariablePath.UserPath -Line $Line -Depth ($Depth + 1))
    }

    # Get-ARText 'Pwn6' 'RDP session agent' resolves to its last string argument,
    # the English fallback the target actually writes into the rule.
    if ($Expression -is [System.Management.Automation.Language.CommandAst]) {
        if ($Expression.GetCommandName() -ne 'Get-ARText') { return $null }
        $literals = New-Object System.Collections.ArrayList
        foreach ($element in @($Expression.CommandElements | Select-Object -Skip 1)) {
            if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $null = $literals.Add([string]$element.Value) }
        }
        if ($literals.Count -eq 0) { return $null }
        return [string]$literals[$literals.Count - 1]
    }

    return $null
}

# Value of $Name as seen at a line: the nearest preceding assignment in the same
# function, else the Invoke-Command -ArgumentList value bound to a param block.
function Get-ArContractRuleNameVariable {
    param($Ast, [Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)][int]$Line, [int]$Depth = 0)
    if ($Depth -gt 8) { return $null }
    $scope = Get-ArContractScope -Ast $Ast -Line $Line

    $nearest = $null
    foreach ($node in @($scope.FindAll({
                    param($inner)
                    $inner -is [System.Management.Automation.Language.AssignmentStatementAst]
                }, $true))) {
        if ($node.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        if ($node.Left.VariablePath.UserPath -ne $Name) { continue }
        if ([int]$node.Extent.StartLineNumber -ge $Line) { continue }
        if ($null -eq $nearest) { $nearest = $node; continue }
        if ([int]$node.Extent.StartLineNumber -gt [int]$nearest.Extent.StartLineNumber) { $nearest = $node }
    }
    if ($null -ne $nearest) {
        return (Get-ArContractRuleNameValue -Ast $Ast -Expression $nearest.Right -Line ([int]$nearest.Extent.StartLineNumber) -Depth ($Depth + 1))
    }

    # Remote blocks take the rule name as param($msi, $rule, $roots) from the
    # surrounding Invoke-Command -ArgumentList, position for position.
    foreach ($block in @($Ast.FindAll({
                    param($inner)
                    ($inner -is [System.Management.Automation.Language.ScriptBlockAst]) -and
                    ($null -ne $inner.ParamBlock) -and
                    ([int]$inner.Extent.StartLineNumber -lt $Line) -and
                    ([int]$inner.Extent.EndLineNumber -ge $Line)
                }, $true))) {
        $parameters = @($block.ParamBlock.Parameters)
        $position = -1
        for ($cursor = 0; $cursor -lt $parameters.Count; $cursor++) {
            if ($parameters[$cursor].Name.VariablePath.UserPath -ne $Name) { continue }
            $position = $cursor
            break
        }
        if ($position -lt 0) { continue }

        $caller = $null
        foreach ($node in @($scope.FindAll({
                        param($inner)
                        ($inner -is [System.Management.Automation.Language.CommandAst]) -and
                        ($inner.GetCommandName() -eq 'Invoke-Command')
                    }, $true))) {
            if ([int]$node.Extent.StartOffset -gt [int]$block.Extent.StartOffset) { continue }
            if ([int]$node.Extent.EndOffset -lt [int]$block.Extent.EndOffset) { continue }
            if ($null -eq $caller) { $caller = $node; continue }
            if ([int]$node.Extent.EndOffset -lt [int]$caller.Extent.EndOffset) { $caller = $node }
        }
        if ($null -eq $caller) { continue }

        $arguments = New-Object System.Collections.ArrayList
        $elements = @($caller.CommandElements)
        for ($cursor = 0; $cursor -lt $elements.Count; $cursor++) {
            $element = $elements[$cursor]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            if ($element.ParameterName -ne 'ArgumentList') { continue }
            $value = $element.Argument
            if ($null -eq $value -and ($cursor + 1) -lt $elements.Count) { $value = $elements[$cursor + 1] }
            if ($null -eq $value) { break }
            if ($value -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                foreach ($item in @($value.Elements)) { $null = $arguments.Add($item) }
            }
            else { $null = $arguments.Add($value) }
            break
        }
        if ($position -ge $arguments.Count) { continue }
        return (Get-ArContractRuleNameValue -Ast $Ast -Expression $arguments[$position] -Line ([int]$caller.Extent.StartLineNumber) -Depth ($Depth + 1))
    }

    return $null
}

# --------------------------------------------------------------------------- #
# target registry backup
# --------------------------------------------------------------------------- #

Describe 'target registry backup' {

    $runtimePath = Join-Path $script:ArTestRoot 'src\20-runtime.ps1'
    $runtimeText = Get-ArContractText -Path $runtimePath
    $backupValues = @('AllowRemoteRPC', 'SecurityLayer', 'LocalAccountTokenFilterPolicy', 'AllowEncryptionOracle')

    It 'declares the backup list in src\20-runtime.ps1' {
        Assert-Match -Text $runtimeText -Pattern '\$script:ARRegistryBackup\s*=' `
            -Message 'src\20-runtime.ps1 no longer declares $script:ARRegistryBackup; cleanup cannot replay the registry values the shadow engine writes'
    }

    It 'captures at least four registry values through the backup helper' {
        $shadow = Get-ArFunctionAst -Name 'Invoke-ARShadowEngine'
        Assert-NotNull $shadow 'Invoke-ARShadowEngine is missing from src; the registry backup has no writer to observe'
        $body = $shadow.Ast.Body

        # The capture path: a Save/Record/Capture/Backup helper, and a call before
        # the first New-ItemProperty, so the previous state exists before the write.
        $capturePattern = '(?i)^(Save|Record|Capture|Backup)-AR[A-Za-z]*(Value|Registry|Setting|State)$'
        $captures = @($body.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst]) -and
                    ($node.GetCommandName() -match $capturePattern)
                }, $true))
        Assert-True ($captures.Count -gt 0) `
            'src\20-runtime.ps1 captures no registry value before writing (no Save/Record/Capture/Backup-AR*Value call)'
        $writes = @($body.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst]) -and
                    ($node.GetCommandName() -eq 'New-ItemProperty')
                }, $true))
        Assert-True ($writes.Count -gt 0) 'src\20-runtime.ps1 writes no registry value with New-ItemProperty'
        Assert-True ([int]$captures[0].Extent.StartOffset -lt [int]$writes[0].Extent.StartOffset) `
            'the registry capture call sits after the first New-ItemProperty; the previous value is overwritten before it is recorded'

        # Every recorded entry must land in the session list, not a local one.
        Assert-Match -Text $body.Extent.Text -Pattern '\$script:ARRegistryBackup\.Add\(' `
            -Message 'the shadow engine records registry state in a local list; $script:ARRegistryBackup stays empty and cleanup has nothing to replay'

        # At least four of the contract values go through a capturing writer.
        $writerPattern = '(?i)^(Set|Write)-AR[A-Za-z]*(Dword|Value|Registry|Setting)$'
        $writers = @($body.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst]) -and
                    ($node.GetCommandName() -match $writerPattern)
                }, $true))
        Assert-True ($writers.Count -ge 4) `
            ('src\20-runtime.ps1 has {0} capturing writer call(s); at least four registry values must be recorded before they are written' -f $writers.Count)
        $writerText = (@($writers | ForEach-Object { $_.Extent.Text }) -join [Environment]::NewLine)
        foreach ($value in $backupValues) {
            Assert-Match -Text $writerText -Pattern ([regex]::Escape($value)) `
                -Message ('{0} is not written through a capturing writer; its previous state is lost on cleanup' -f $value)
        }
    }

    It 'replays the backup in Remove-ARTargetArtifacts' {
        $cleanup = Get-ArFunctionAst -Name 'Remove-ARTargetArtifacts'
        Assert-NotNull $cleanup 'Remove-ARTargetArtifacts is missing from src; target registry changes would survive the session'
        $text = $cleanup.Ast.Body.Extent.Text
        Assert-Match -Text $text -Pattern '\$script:ARRegistryBackup' `
            -Message 'Remove-ARTargetArtifacts never reads $script:ARRegistryBackup; the recorded registry values are never restored'
        Assert-Match -Text $text -Pattern 'Remove-ItemProperty' `
            -Message 'Remove-ARTargetArtifacts has no Remove-ItemProperty; values that did not exist before the run are left behind'
        Assert-Match -Text $text -Pattern '(?s)-not\s+\$\w+\.Existed.{0,1200}Remove-ItemProperty' `
            -Message 'Remove-ARTargetArtifacts does not gate Remove-ItemProperty on Existed; it would delete values that were present before the run'
    }
}

# --------------------------------------------------------------------------- #
# installed MSI products
# --------------------------------------------------------------------------- #

Describe 'installed products' {

    $runtimePath = Join-Path $script:ArTestRoot 'src\20-runtime.ps1'
    $runtimeText = Get-ArContractText -Path $runtimePath

    It 'declares $script:ARInstalledProducts in src\20-runtime.ps1' {
        Assert-Match -Text $runtimeText -Pattern '\$script:ARInstalledProducts\s*=' `
            -Message 'src\20-runtime.ps1 no longer declares $script:ARInstalledProducts; an MSI installed during the run is never uninstalled'
    }

    It 'uninstalls tracked products with msiexec /x' {
        $cleanup = Get-ArFunctionAst -Name 'Remove-ARTargetArtifacts'
        Assert-NotNull $cleanup 'Remove-ARTargetArtifacts is missing from src; the MSI uninstall step cannot run'
        $text = $cleanup.Ast.Body.Extent.Text
        Assert-Match -Text $text -Pattern '\$script:ARInstalledProducts' `
            -Message 'Remove-ARTargetArtifacts never reads $script:ARInstalledProducts; RDPWrap and other MSIs survive cleanup'
        Assert-Match -Text $text -Pattern '(?i)msiexec(\.exe)?[^\r\n]*[/-]x\b' `
            -Message 'Remove-ARTargetArtifacts does not run msiexec /x; the installed product stays on the target'
    }
}

# --------------------------------------------------------------------------- #
# stored cmdkey credential
# --------------------------------------------------------------------------- #

Describe 'stored credential' {

    $shadow = Get-ArFunctionAst -Name 'Invoke-ARShadowEngine'
    $cleanup = Get-ArFunctionAst -Name 'Invoke-ARCleanup'

    It 'tracks cmdkey /add before the credential is stored' {
        Assert-NotNull $shadow 'Invoke-ARShadowEngine is missing from src; cmdkey tracking cannot be checked'
        $lines = @($shadow.Ast.Body.Extent.Text -split "\r?\n")
        $track = @(Get-ArContractPatternIndexes -Lines $lines -Pattern 'ARCmdKeyTargets\.Add')
        $add = @(Get-ArContractPatternIndexes -Lines $lines -Pattern 'cmdkey(\.exe)?\s+"/add')
        Assert-True ($track.Count -gt 0) 'Invoke-ARShadowEngine stores a cmdkey credential without adding it to $script:ARCmdKeyTargets'
        Assert-True ($add.Count -gt 0) 'Invoke-ARShadowEngine no longer calls cmdkey /add; the tracking check would pass vacuously'
        Assert-True ($track[0] -lt $add[0]) `
            '$script:ARCmdKeyTargets.Add runs after cmdkey /add; an interrupted add leaves an untracked credential'
    }

    It 'deletes the credential in a finally when the add fails' {
        Assert-NotNull $shadow 'Invoke-ARShadowEngine is missing from src; the cmdkey failure path cannot be checked'
        $tries = @($shadow.Ast.Body.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.TryStatementAst]
                }, $true))
        $found = $false
        foreach ($try in $tries) {
            if ($null -eq $try.Finally) { continue }
            if ($try.Body.Extent.Text -notmatch 'cmdkey') { continue }
            if ($try.Body.Extent.Text -notmatch '/add') { continue }
            if ($try.Finally.Extent.Text -match '/delete') { $found = $true; break }
        }
        Assert-True $found 'cmdkey /add has no try/finally that runs cmdkey /delete; a failed add leaves the credential stored'
    }

    It 'deletes the credential during Invoke-ARCleanup' {
        Assert-NotNull $cleanup 'Invoke-ARCleanup is missing from src; stored credentials would outlive the session'
        Assert-Match -Text $cleanup.Ast.Body.Extent.Text -Pattern 'cmdkey(\.exe)?[^\r\n]*"/delete' `
            -Message 'Invoke-ARCleanup has no cmdkey /delete; the credential stored for the target survives cleanup'
    }
}

# --------------------------------------------------------------------------- #
# firewall registration
# --------------------------------------------------------------------------- #

Describe 'firewall registration' {

    # Cleanup replays rule NAMES, and one name may cover several add lines (udp +
    # tcp for the RDP session agent). The contract is therefore name-level: every
    # added name must be registered, and every registration must name a rule that
    # is actually added. Line proximity proves neither direction.
    $addPattern = 'advfirewall\s+firewall\s+add\s+rule'
    $registrationPattern = '\$script:ARFirewallRules\s*\.\s*Add\s*\('
    $addSites = New-Object System.Collections.ArrayList
    $addNames = New-Object System.Collections.ArrayList
    $registeredNames = New-Object System.Collections.ArrayList
    $unresolved = New-Object System.Collections.ArrayList

    foreach ($path in @(Get-ArSourceFilePaths)) {
        $file = Split-Path -Leaf $path
        $lines = @(Get-ArContractLines -Path $path)
        $ast = (Get-ArParseResult -Path $path).Ast

        foreach ($index in @(Get-ArContractPatternIndexes -Lines $lines -Pattern $addPattern)) {
            $lineNumber = $index + 1
            $null = $addSites.Add(('{0}:{1} {2}' -f $file, $lineNumber, $lines[$index].Trim()))
            $quoted = [regex]::Match($lines[$index], 'name\s*=\s*"([^"]*)"')
            if (-not $quoted.Success) {
                $null = $unresolved.Add(('{0}:{1} adds a rule with no name= argument' -f $file, $lineNumber))
                continue
            }
            $value = $quoted.Groups[1].Value
            $name = $null
            if ($value -match '^\$([A-Za-z_][A-Za-z0-9_]*)$') {
                $name = Get-ArContractRuleNameVariable -Ast $ast -Name $Matches[1] -Line $lineNumber
            }
            elseif ($value -notmatch '\$') {
                $name = $value
            }
            if ($null -eq $name) {
                $null = $unresolved.Add(('{0}:{1} name="{2}" does not resolve to a literal rule name' -f $file, $lineNumber, $value))
                continue
            }
            $null = $addNames.Add([pscustomobject]@{ Name = $name; Site = ('{0}:{1}' -f $file, $lineNumber) })
        }

        foreach ($index in @(Get-ArContractPatternIndexes -Lines $lines -Pattern $registrationPattern)) {
            $lineNumber = $index + 1
            $match = [regex]::Match($lines[$index], '\$script:ARFirewallRules\s*\.\s*Add\s*\(\s*([^)]*?)\s*\)')
            if (-not $match.Success) {
                $null = $unresolved.Add(('{0}:{1} has an ARFirewallRules.Add this check cannot read' -f $file, $lineNumber))
                continue
            }
            $argument = $match.Groups[1].Value
            $name = $null
            if ($argument -match '^\$([A-Za-z_][A-Za-z0-9_]*)$') {
                $name = Get-ArContractRuleNameVariable -Ast $ast -Name $Matches[1] -Line $lineNumber
            }
            elseif ($argument -match "^'(.*)'$") { $name = $Matches[1] }
            elseif ($argument -match '^"(.*)"$') { $name = $Matches[1] }
            if ($null -eq $name) {
                $null = $unresolved.Add(('{0}:{1} ARFirewallRules.Add({2}) does not resolve to a literal rule name' -f $file, $lineNumber, $argument))
                continue
            }
            $null = $registeredNames.Add([pscustomobject]@{ Name = $name; Site = ('{0}:{1}' -f $file, $lineNumber) })
        }
    }

    It 'registers every firewall rule name it adds' {
        # Guard against a vacuous run: no adds means the sets below compare nothing.
        Assert-True ($addSites.Count -gt 0) `
            'src\*.ps1 contains no "advfirewall firewall add rule"; the registration contract cannot be checked'
        Assert-Equal 0 $unresolved.Count `
            ('firewall rule names that do not resolve to a literal, so cleanup cannot be proven: ' + (@($unresolved) -join '; '))

        $addedSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($entry in @($addNames)) { $null = $addedSet.Add($entry.Name) }
        $registeredSet = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($entry in @($registeredNames)) { $null = $registeredSet.Add($entry.Name) }

        $missing = New-Object System.Collections.ArrayList
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($entry in @($addNames)) {
            if ($registeredSet.Contains($entry.Name)) { continue }
            if (-not $seen.Add($entry.Name)) { continue }
            $null = $missing.Add(('{0} added at {1} is never added to $script:ARFirewallRules' -f $entry.Name, $entry.Site))
        }
        Assert-Equal 0 $missing.Count `
            ('added firewall rule name(s) that cleanup never deletes: ' + ($missing -join '; '))

        $stale = New-Object System.Collections.ArrayList
        $seen = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($entry in @($registeredNames)) {
            if ($addedSet.Contains($entry.Name)) { continue }
            if (-not $seen.Add($entry.Name)) { continue }
            $null = $stale.Add(('{0} registered at {1} is never added by an advfirewall rule' -f $entry.Name, $entry.Site))
        }
        Assert-Equal 0 $stale.Count `
            ('$script:ARFirewallRules entries with no matching add rule: ' + ($stale -join '; '))

        # Both subsets are proven above, so an empty add set or an empty
        # registration set fails instead of passing on nothing.
        Assert-True ($registeredSet.Count -gt 0) `
            'no rule name is registered in $script:ARFirewallRules; every added rule would outlive the session'
    }
}

# --------------------------------------------------------------------------- #
# cleanup hooks
# --------------------------------------------------------------------------- #

Describe 'cleanup hooks' {

    $cleanup = Get-ArFunctionAst -Name 'Invoke-ARCleanup'

    It 'calls the operator port proxy reset behind a Get-Command guard' {
        Assert-NotNull $cleanup 'Invoke-ARCleanup is missing from src; operator port proxies are never reset'
        $calls = @(Get-ArCommandAsts -Ast $cleanup.Ast.Body -Name 'Reset-AROperatorPortProxies')
        Assert-True ($calls.Count -gt 0) 'Invoke-ARCleanup never calls Reset-AROperatorPortProxies; netsh portproxy entries survive the session'
        $guarded = Test-ArContractGuardedCall -Body $cleanup.Ast.Body -CommandName 'Reset-AROperatorPortProxies'
        Assert-True $guarded 'Reset-AROperatorPortProxies is called without an if (Get-Command ...) guard; a partial build without 40-modules throws during cleanup'
    }

    It 'calls the module artifact cleanup behind a Get-Command guard' {
        Assert-NotNull $cleanup 'Invoke-ARCleanup is missing from src; module artifacts are never removed'
        $calls = @(Get-ArCommandAsts -Ast $cleanup.Ast.Body -Name 'Remove-ARModuleArtifacts')
        Assert-True ($calls.Count -gt 0) 'Invoke-ARCleanup never calls Remove-ARModuleArtifacts; module files survive the session'
        $guarded = Test-ArContractGuardedCall -Body $cleanup.Ast.Body -CommandName 'Remove-ARModuleArtifacts'
        Assert-True $guarded 'Remove-ARModuleArtifacts is called without an if (Get-Command ...) guard; a partial build without 40-modules throws during cleanup'
    }

    It 'defines both hooks once, in src\40-modules.ps1' {
        foreach ($name in @('Reset-AROperatorPortProxies', 'Remove-ARModuleArtifacts')) {
            $definition = Get-ArContractDefinitionCount -Name $name
            Assert-Equal 1 $definition.Count ('{0} is defined {1} time(s) in src; the cleanup hook must exist exactly once' -f $name, $definition.Count)
            Assert-Equal '40-modules.ps1' ($definition.Files -join ', ') ('{0} is not defined in src\40-modules.ps1; Invoke-ARCleanup would skip it' -f $name)
        }
    }
}

# --------------------------------------------------------------------------- #
# exit codes
# --------------------------------------------------------------------------- #

Describe 'exit codes' {

    $mainPath = Join-Path $script:ArTestRoot 'src\50-main.ps1'
    $mainText = Get-ArContractText -Path $mainPath

    It 'src\50-main.ps1 exits non-zero when -option fails' {
        Assert-Match -Text $mainText -Pattern '\bexit\s+1\b' `
            -Message 'src\50-main.ps1 never exits 1; a failed -option run reports success to the caller'
        Assert-Match -Text $mainText -Pattern '\$script:ARLastFailure' `
            -Message 'src\50-main.ps1 never reads $script:ARLastFailure; a failed action cannot set the exit code'
    }

    It 'Invoke-ARAction records the failure message in its catch' {
        $action = Get-ArFunctionAst -Name 'Invoke-ARAction'
        Assert-NotNull $action 'Invoke-ARAction is missing from src; the failure flag cannot be set'
        $found = $false
        foreach ($try in @($action.Ast.Body.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true))) {
            foreach ($catch in @($try.CatchClauses)) {
                if ($catch.Body.Extent.Text -match 'ARLastFailure\s*=') { $found = $true; break }
            }
            if ($found) { break }
        }
        Assert-True $found 'Invoke-ARAction swallows the exception without setting $script:ARLastFailure; -option exits 0 after a failed action'
    }
}

# --------------------------------------------------------------------------- #
# TUI input safety
# --------------------------------------------------------------------------- #

Describe 'TUI input safety' {

    $tuiPath = Join-Path $script:ArTestRoot 'src\10-tui.ps1'
    $tuiText = Get-ArContractText -Path $tuiPath
    $tuiAst = (Get-ArParseResult -Path $tuiPath).Ast

    It 'parses menu input with [int]::TryParse' {
        $uses = [regex]::Matches($tuiText, '\[int\]::TryParse').Count
        Assert-True ($uses -ge 3) `
            ('src\10-tui.ps1 uses [int]::TryParse {0} time(s); at least three numeric menu paths must parse without throwing' -f $uses)
    }

    It 'never casts raw Read-* input with [int]' {
        $derived = @(Get-ArContractReadDerivedNames -Ast $tuiAst)
        $offenders = New-Object System.Collections.ArrayList
        foreach ($cast in @($tuiAst.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.ConvertExpressionAst]
                    }, $true))) {
            if ($cast.Type.TypeName.Name -ne 'int') { continue }
            $child = $cast.Child
            if ($child -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            if ($derived -notcontains $child.VariablePath.UserPath) { continue }
            $null = $offenders.Add(('line {0}: {1}' -f $cast.Extent.StartLineNumber, $cast.Extent.Text.Trim()))
        }
        Assert-Equal 0 $offenders.Count `
            ('src\10-tui.ps1 casts raw Read-* menu input with [int]: ' + ($offenders -join '; ') +
                '; a non-numeric entry throws instead of being reparsed')
    }
}

# --------------------------------------------------------------------------- #
# language persistence
# --------------------------------------------------------------------------- #

Describe 'language persistence' {

    $tuiPath = Join-Path $script:ArTestRoot 'src\10-tui.ps1'
    $tuiText = Get-ArContractText -Path $tuiPath

    It 'defines Get-ARLastLanguage once, in src\10-tui.ps1' {
        $definition = Get-ArContractDefinitionCount -Name 'Get-ARLastLanguage'
        Assert-Equal 1 $definition.Count ('Get-ARLastLanguage is defined {0} time(s) in src; the startup language lookup needs exactly one definition' -f $definition.Count)
        Assert-Equal '10-tui.ps1' ($definition.Files -join ', ') 'Get-ARLastLanguage is not defined in src\10-tui.ps1; Start-ARApplication cannot restore the language'
    }

    It 'defines Set-ARLastLanguage once, in src\10-tui.ps1' {
        $definition = Get-ArContractDefinitionCount -Name 'Set-ARLastLanguage'
        Assert-Equal 1 $definition.Count ('Set-ARLastLanguage is defined {0} time(s) in src; the language picker needs exactly one definition' -f $definition.Count)
        Assert-Equal '10-tui.ps1' ($definition.Files -join ', ') 'Set-ARLastLanguage is not defined in src\10-tui.ps1; the language choice is never saved'
    }

    It 'merges Language into the existing last.json instead of overwriting it' {
        $setter = Get-ArFunctionAst -Name 'Set-ARLastLanguage'
        Assert-NotNull $setter 'Set-ARLastLanguage is missing from src\10-tui.ps1'
        $body = $setter.Ast.Body
        $text = $body.Extent.Text
        Assert-Match -Text $text -Pattern 'Language' `
            -Message 'Set-ARLastLanguage does not write a Language property; the saved locale never survives a restart'

        # Read before write: either the function reads last.json itself or it goes
        # through the Get-ARLastState reader. Both keep the Name/Saved keys.
        $read = @($body.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst]) -and
                    ($node.GetCommandName() -match '^(Get-ARLastState|Get-Content)$')
                }, $true))
        $write = @($body.FindAll({
                    param($node)
                    ($node -is [System.Management.Automation.Language.CommandAst]) -and
                    ($node.GetCommandName() -match '^(Save-ARLastState|Set-Content|Out-File)$')
                }, $true))
        Assert-True ($read.Count -gt 0) 'Set-ARLastLanguage never reads last.json/Get-ARLastState before writing; it overwrites Name and Saved'
        Assert-True ($write.Count -gt 0) 'Set-ARLastLanguage never writes last.json; the language is lost on exit'
        Assert-True ([int]$read[0].Extent.StartOffset -lt [int]$write[0].Extent.StartOffset) `
            'Set-ARLastLanguage writes last.json before reading it; the merge becomes an overwrite'

        if ($text -match 'Get-ARLastState') {
            $reader = Get-ArFunctionAst -Name 'Get-ARLastState'
            Assert-NotNull $reader 'Set-ARLastLanguage calls Get-ARLastState, which src does not define'
            $readerText = $reader.Ast.Body.Extent.Text
            Assert-Match -Text $readerText -Pattern 'Get-Content' `
                -Message 'Get-ARLastState never calls Get-Content; last.json is not merged'
            Assert-Match -Text $readerText -Pattern 'ConvertFrom-Json' `
                -Message 'Get-ARLastState never parses the existing last.json; unknown properties are dropped'
        }
    }

    It 'returns the persisted language from Get-ARLastLanguage' {
        $getter = Get-ArFunctionAst -Name 'Get-ARLastLanguage'
        Assert-NotNull $getter 'Get-ARLastLanguage is missing from src\10-tui.ps1'
        $text = $getter.Ast.Body.Extent.Text
        Assert-Match -Text $text -Pattern 'Language' `
            -Message 'Get-ARLastLanguage never reads the Language property; the saved locale is ignored at startup'
        Assert-True ($text -match 'Get-ARLastState' -or $text -match 'Get-Content') `
            'Get-ARLastLanguage reads no state and no file; it cannot return the saved locale'
    }
}

# --------------------------------------------------------------------------- #
# screen route (Resources\Scripts\Invoke-StealthScreen.ps1)
# --------------------------------------------------------------------------- #

Describe 'screen route' {

    $stealthPath = Join-Path $script:ArTestRoot 'Resources\Scripts\Invoke-StealthScreen.ps1'
    $stealthText = Get-ArContractText -Path $stealthPath
    $stealthAst = $null
    if (Test-Path -LiteralPath $stealthPath) { $stealthAst = (Get-ArParseResult -Path $stealthPath).Ast }

    It 'opens the firewall before Start-RemotePayload in the view branch' {
        Assert-FileExists -Path $stealthPath -Message 'Resources\Scripts\Invoke-StealthScreen.ps1 is missing'
        $view = Get-ArContractIfStatement -Ast $stealthAst -ConditionPattern "Mode\s+-eq\s+'view'"
        Assert-NotNull $view 'Invoke-StealthScreen.ps1 has no if ($Mode -eq ''view'') branch'
        $viewText = $view.Extent.Text
        $rule = $viewText.IndexOf('advfirewall firewall add rule')
        $start = $viewText.IndexOf('Start-RemotePayload')
        Assert-True ($rule -ge 0) 'the view branch never adds its firewall rule; the first connection blocks on the Windows firewall prompt'
        Assert-True ($start -ge 0) 'the view branch never calls Start-RemotePayload; the frame server is never staged'
        Assert-True ($rule -lt $start) `
            'the view branch stages the payload before it opens the firewall; the victim sees the Defender firewall prompt'
    }

    It 'wraps stage, probe and view in try/finally with the teardown in finally' {
        $view = Get-ArContractIfStatement -Ast $stealthAst -ConditionPattern "Mode\s+-eq\s+'view'"
        Assert-NotNull $view 'Invoke-StealthScreen.ps1 has no if ($Mode -eq ''view'') branch'
        $found = $false
        foreach ($try in @($view.FindAll({
                        param($node)
                        $node -is [System.Management.Automation.Language.TryStatementAst]
                    }, $true))) {
            if ($null -eq $try.Finally) { continue }
            if ($try.Body.Extent.Text -notmatch 'Start-RemotePayload') { continue }
            $finally = $try.Finally.Extent.Text
            if ($finally -match 'firewall\s+delete\s+rule' -and $finally -match '(schtasks\.exe\s+/delete|Unregister-ScheduledTask)') {
                $found = $true
                break
            }
        }
        Assert-True $found `
            'the view branch has no try { stage/probe/view } finally { task + rule teardown }; an error or ESC leaves a scheduled task and an open port'
    }

    It 'has no legacy VNC or payload.bin leftovers' {
        foreach ($pattern in @('Invoke-Vnc', 'VNCViewer', 'payload\.bin')) {
            Assert-NotMatch -Text $stealthText -Pattern $pattern `
                -Message ('Invoke-StealthScreen.ps1 still references /' + $pattern + '/; the retired VNC path is back')
        }
    }

    It 'captures the Start-RemotePayload return value in -Mode shot' {
        $shot = Get-ArContractIfStatement -Ast $stealthAst -ConditionPattern "Mode\s+-eq\s+'shot'"
        Assert-NotNull $shot 'Invoke-StealthScreen.ps1 has no if ($Mode -eq ''shot'') branch'
        Assert-Match -Text $shot.Extent.Text -Pattern '(?m)^\s*(\$staged|\$null)\s*=\s*Start-RemotePayload\b' `
            -Message 'the shot branch leaks the Start-RemotePayload object to the pipeline; the caller receives a task object instead of a clean exit'
    }
}

# --------------------------------------------------------------------------- #
# version stamp
# --------------------------------------------------------------------------- #

Describe 'version' {

    $headerPath = Join-Path $script:ArTestRoot 'src\00-header.ps1'
    $headerText = Get-ArContractText -Path $headerPath
    $readmeText = Get-ArContractText -Path (Join-Path $script:ArTestRoot 'README.md')

    It 'src\00-header.ps1 sets version 6.0' {
        Assert-Match -Text $headerText -Pattern '\$script:ARVersion\s*=\s*''6\.0''' `
            -Message 'src\00-header.ps1 does not set $script:ARVersion = ''6.0''; the build stamps the old version'
    }

    It 'the window title drops the old author handle' {
        $titleLine = @(Get-ArContractLines -Path $headerPath | Where-Object { $_ -match 'WindowTitle' })
        Assert-True ($titleLine.Count -gt 0) 'src\00-header.ps1 no longer sets a window title'
        Assert-Match -Text $titleLine[0] -Pattern 'v6\.0' `
            -Message 'the window title does not say v6.0'
        Assert-NotMatch -Text $titleLine[0] -Pattern 'JoelGMSec' `
            -Message 'the window title still credits @JoelGMSec, the retired handle'
    }

    It 'README.md announces v6.0' {
        Assert-FileExists -Path (Join-Path $script:ArTestRoot 'README.md') -Message 'README.md is missing from the repository root'
        Assert-Match -Text $readmeText -Pattern 'v6\.0' `
            -Message 'README.md contains no v6.0 version marker'
    }
}
