# Tests\ArAst.ps1
#
# Read-only helpers shared by the suite. Everything here works on the PowerShell
# AST: the tests never load src\*.ps1, never touch the network and never run a
# catalog action. That keeps the suite valid while src\*.ps1 is being edited.
#
# Parsed files are cached for the lifetime of one runner invocation.

$script:ArAstCache = @{}

function Get-ArRepositoryRoot {
    return (Split-Path -Parent $PSScriptRoot)
}

# All first-party PowerShell files. _sandbox\ is a scratch directory shared with
# other tooling, so only the generated build is taken from it; everything else in
# the repository is parsed, tracked or not.
function Get-ArTestPowerShellFiles {
    $root = $script:ArTestRoot
    $sandbox = $script:ArTestSandbox
    $files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        Where-Object {
            if ($sandbox -and $_.FullName.StartsWith($sandbox, [System.StringComparison]::OrdinalIgnoreCase)) {
                return ($_.Name -eq 'gen.ps1')
            }
            return $true
        } |
        Sort-Object FullName)
    foreach ($file in $files) {
        [pscustomobject]@{
            Name         = $file.Name
            FullName     = $file.FullName
            RelativePath = $file.FullName.Substring($root.Length).TrimStart('\', '/')
            Length       = $file.Length
        }
    }
}

function Get-ArSourceFilePaths {
    $root = $script:ArTestRoot
    return @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File -ErrorAction SilentlyContinue |
        Sort-Object Name | ForEach-Object { $_.FullName })
}

function Get-ArParseResult {
    param([Parameter(Mandatory = $true)][string]$Path)
    $key = [System.IO.Path]::GetFullPath($Path).ToLowerInvariant()
    if ($script:ArAstCache.ContainsKey($key)) { return $script:ArAstCache[$key] }
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    $result = [pscustomobject]@{
        Path   = $Path
        Ast    = $ast
        Tokens = @($tokens)
        Errors = @($errors)
    }
    $script:ArAstCache[$key] = $result
    return $result
}

function Get-ArParseErrors {
    param([Parameter(Mandatory = $true)][string]$Path)
    return @((Get-ArParseResult -Path $Path).Errors)
}

function Get-ArSourceAsts {
    $list = New-Object System.Collections.ArrayList
    foreach ($path in @(Get-ArSourceFilePaths)) {
        $parsed = Get-ArParseResult -Path $path
        $null = $list.Add([pscustomobject]@{
            File = Split-Path -Leaf $path
            Path = $path
            Ast  = $parsed.Ast
        })
    }
    return @($list.ToArray())
}

# Returns @{ Ast; File } or $null. Searches src\*.ps1 only, so a definition that
# only exists in the generated AutoRDPwn.ps1 counts as missing.
function Get-ArFunctionAst {
    param([Parameter(Mandatory = $true)][string]$Name)
    foreach ($source in @(Get-ArSourceAsts)) {
        $functions = @($source.Ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true))
        if ($functions.Count -gt 0) {
            return [pscustomobject]@{ Ast = $functions[0]; File = $source.File }
        }
    }
    return $null
}

function Get-ArFunctionNames {
    $names = New-Object System.Collections.ArrayList
    foreach ($source in @(Get-ArSourceAsts)) {
        $functions = @($source.Ast.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        }, $true))
        foreach ($function in $functions) { $null = $names.Add($function.Name) }
    }
    return @($names | Sort-Object -Unique)
}

function Get-ArCommandAsts {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][string]$Name)
    $matches = @($Ast.FindAll({
        param($node)
        if ($node -isnot [System.Management.Automation.Language.CommandAst]) { return $false }
        return ($node.GetCommandName() -eq $Name)
    }, $true))
    return $matches
}

# Literal string for a constant argument, $null when the argument is dynamic.
function Get-ArLiteralString {
    param($Node)
    if ($null -eq $Node) { return $null }
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return [string]$Node.Value }
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) { return [string]$Node.Value }
    if ($Node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) { return [string]$Node.Extent.Text }
    return $null
}

# Maps -Parameter value pairs of one command call. Unbound switches map to $true.
function Get-ArCommandParameterMap {
    param([Parameter(Mandatory = $true)]$CommandAst)
    $map = @{}
    $elements = @($CommandAst.CommandElements)
    for ($index = 1; $index -lt $elements.Count; $index++) {
        $element = $elements[$index]
        if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
        $name = $element.ParameterName
        if ($null -ne $element.Argument) {
            $map[$name] = Get-ArLiteralString -Node $element.Argument
            continue
        }
        $next = $null
        if ($index + 1 -lt $elements.Count) { $next = $elements[$index + 1] }
        if ($null -eq $next) { $map[$name] = $true; continue }
        if ($next -is [System.Management.Automation.Language.CommandParameterAst]) { $map[$name] = $true; continue }
        # $-prefixed values and expressions are dynamic; keep null rather than guessing.
        $map[$name] = Get-ArLiteralString -Node $next
        if ($null -eq $map[$name] -and $next -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $map[$name] = $null
        }
    }
    return $map
}

# Every New-ARAction call in src\*.ps1, as data. This is the catalog contract:
# ids, handlers and where they were declared.
function Get-ArCatalogEntries {
    $entries = New-Object System.Collections.ArrayList
    foreach ($source in @(Get-ArSourceAsts)) {
        foreach ($command in @(Get-ArCommandAsts -Ast $source.Ast -Name 'New-ARAction')) {
            $parameters = Get-ArCommandParameterMap -CommandAst $command
            $null = $entries.Add([pscustomobject]@{
                Id      = [string]$parameters['Id']
                Handler = [string]$parameters['Handler']
                File    = $source.File
                Line    = $command.Extent.StartLineNumber
            })
        }
    }
    return @($entries.ToArray())
}

# IfStatementAst.Clauses is a Tuple<PipelineBaseAst, StatementBlockAst> on
# Windows PowerShell 5.1 and an IfStatementClauseAst on PowerShell 7. Normalise
# both shapes; reading the wrong one yields null offsets and a vacuous test.
function Get-ArIfClauseParts {
    param([Parameter(Mandatory = $true)]$Clause)
    $condition = $null
    $statements = @()
    if ($null -ne $Clause.PSObject.Properties['Item1']) {
        $condition = $Clause.Item1
        $statements = @($Clause.Item2.Statements)
    }
    elseif ($null -ne $Clause.PSObject.Properties['Condition']) {
        $condition = $Clause.Condition
        $statements = @($Clause.Statements)
    }
    else {
        # Loud, not silent: an unknown clause shape would make the guarded-range
        # tests below pass without checking anything.
        throw ('internal: unsupported IfStatementAst clause shape (' + $Clause.GetType().FullName + ')')
    }
    return [pscustomobject]@{ Condition = $condition; Statements = $statements }
}

# Statement ranges owned by the branch whose condition matches a pattern.
# Used to prove that cleanup work sits outside the "-noclean" guard.
function Get-ArGuardedRanges {
    param([Parameter(Mandatory = $true)]$Ast, [Parameter(Mandatory = $true)][string]$ConditionPattern)
    $ranges = New-Object System.Collections.ArrayList
    $statements = @($Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.IfStatementAst]
    }, $true))
    foreach ($statement in $statements) {
        $matched = $false
        $parts = @($statement.Clauses | ForEach-Object { Get-ArIfClauseParts -Clause $_ })
        foreach ($part in $parts) {
            if ($null -ne $part.Condition -and $part.Condition.Extent.Text -match $ConditionPattern) { $matched = $true }
        }
        if (-not $matched) { continue }
        foreach ($part in $parts) {
            foreach ($inner in @($part.Statements)) {
                if ($null -eq $inner) { continue }
                $null = $ranges.Add([pscustomobject]@{ Start = [int]$inner.Extent.StartOffset; End = [int]$inner.Extent.EndOffset })
            }
        }
        if ($null -ne $statement.ElseClause) {
            foreach ($inner in @($statement.ElseClause.Statements)) {
                if ($null -eq $inner) { continue }
                $null = $ranges.Add([pscustomobject]@{ Start = [int]$inner.Extent.StartOffset; End = [int]$inner.Extent.EndOffset })
            }
        }
    }
    foreach ($range in @($ranges.ToArray())) {
        if ($null -eq $range.Start -or $range.End -eq 0) {
            throw ('internal: guarded range has no offset (AST shape changed?), refusing to run a vacuous check')
        }
    }
    return @($ranges.ToArray())
}

function Test-ArNodeInRanges {
    param($Node, $Ranges)
    $start = $Node.Extent.StartOffset
    foreach ($range in @($Ranges)) {
        if ($start -ge $range.Start -and $start -le $range.End) { return $true }
    }
    return $false
}

# True when at least one node matching the predicate sits outside every range.
function Test-ArAstMarkerOutsideRanges {
    param([Parameter(Mandatory = $true)]$Ast, $Ranges, [Parameter(Mandatory = $true)][scriptblock]$Matcher)
    foreach ($node in @($Ast.FindAll({ param($inner) $true }, $true))) {
        if (-not (& $Matcher $node)) { continue }
        if (-not (Test-ArNodeInRanges -Node $node -Ranges $Ranges)) { return $true }
    }
    return $false
}

# Returns a scriptblock that defines a function from src\*.ps1, without running
# the file it lives in. Dot-source it to define the function in the caller scope:
#   . (Get-ArFunctionSource -Name 'Protect-ARTargetSecret')
function Get-ArFunctionSource {
    param([Parameter(Mandatory = $true)][string]$Name)
    $found = Get-ArFunctionAst -Name $Name
    if ($null -eq $found) { throw ("function '{0}' is not defined in any src\*.ps1" -f $Name) }
    return [scriptblock]::Create($found.Ast.Extent.Text)
}
