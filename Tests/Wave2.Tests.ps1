# Tests\Wave2.Tests.ps1
#
# Wave 2 contracts for the merge gate:
#
#   1. catalog: exactly one entry for 205, 206, 207, 504, 801, 802, 803, 804,
#      805, 901, 902, 903 and 904.
#   2. handlers: every wave2 id maps to its expected handler and that handler
#      is defined exactly once across src\*.ps1 (AST function definitions,
#      never grep).
#   3. locale: every Get-ARText key referenced by src resolves in
#      English.ps1, and all seven language files share the same key set.
#   4. CLI: src\01-core.ps1 declares Target, User, Password, Mode, Yes,
#      Config, List and ListJson in its param block.
#   5. no dead handlers: every Invoke-ARAttack* / Invoke-ARModule* function
#      defined in src\02-actions.ps1 is referenced by at least one catalog
#      -Handler.
#   6. cleanup: the thirteen wave-2 handlers remove C:\Windows\Temp paths
#      only inside a finally block, or the artifact went through one of the
#      registered cleanup lists ($script:ARRemoteTempDirs,
#      $script:ARRemoteTasks, $script:ARModuleFiles, $script:ARRegistryBackup,
#      $script:ARFirewallRules).
#
# Reading contract 6 the way the code is built today: a handler either deletes
# its temp path synchronously in finally (LSASS/SAM dumps) or registers the
# path with a registered list and lets the batched cleanup machinery delete it
# (shadow-copy link directory). Both are allowed. A bare Remove-Item on a
# Windows\Temp path outside those two mechanisms is a violation.
#
# Everything here is read-only: AST and raw text, src is never dot-sourced,
# no catalog action ever runs, no target is contacted. Files are read with
# [System.IO.File]::ReadAllText (BOM aware), not Get-Content -Raw, per the
# antivirus rule in STATE.md.
#
# Work still in flight is reported as a Skip whose message names what is
# missing (which worker, which file, which symbol). Code that is landed but
# wrong always fails. No assertion here is weakened to pass.

# --------------------------------------------------------------------------- #
# helpers - wave2-prefixed so they never collide with the other suite files
# --------------------------------------------------------------------------- #

# BOM-aware raw text: locale files are UTF-8 with BOM and src is UTF-8.
function Get-ArWave2RawText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# 1-based line number of a character offset in raw text. Counts \n so it is
# correct for both CRLF and LF files.
function Get-ArWave2LineFromOffset {
    param([Parameter(Mandatory = $true)][string]$Text, [Parameter(Mandatory = $true)][int]$Offset)
    if ($Offset -lt 0) { $Offset = 0 }
    if ($Offset -gt $Text.Length) { $Offset = $Text.Length }
    return (1 + [regex]::Matches($Text.Substring(0, $Offset), "`n").Count)
}

# Every definition of one function name across src\*.ps1: AST, not grep.
function Get-ArWave2Definitions {
    param([Parameter(Mandatory = $true)][string]$Name)
    $definitions = New-Object System.Collections.ArrayList
    foreach ($source in @(Get-ArSourceAsts)) {
        foreach ($definition in @($source.Ast.FindAll({
            param($node)
            ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and ($node.Name -eq $Name)
        }, $true))) {
            $null = $definitions.Add([pscustomobject]@{
                File = $source.File
                Line = [int]$definition.Extent.StartLineNumber
                Ast  = $definition
            })
        }
    }
    return @($definitions.ToArray())
}

# The ids at the center of wave 2, in contract order, with the file each
# handler is expected to land in (ownership, not an assertion).
$script:ArWave2Targets = @(
    [pscustomobject]@{ Id = '205'; Handler = 'Invoke-ARAttackLsassDump';       Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '206'; Handler = 'Invoke-ARAttackSamDump';         Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '207'; Handler = 'Invoke-ARAttackCredentialSpray'; Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '504'; Handler = 'Invoke-ARModulePersistenceKit';  Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '801'; Handler = 'Invoke-ARAttackEnableRdp';       Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '802'; Handler = 'Invoke-ARAttackDefenderExclude'; Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '803'; Handler = 'Invoke-ARAttackAmsiBypass';      Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '804'; Handler = 'Invoke-ARAttackShadowCopies';    Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '805'; Handler = 'Invoke-ARAttackEventLogClear';   Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '901'; Handler = 'Invoke-ARModuleFileExfil';       Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '902'; Handler = 'Invoke-ARModuleScreenshotLoop';  Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '903'; Handler = 'Invoke-ARModuleClipboardWatch';  Owner = 'src\02-actions.ps1' }
    [pscustomobject]@{ Id = '904'; Handler = 'Invoke-ARModuleKeyloggerFast';   Owner = 'src\02-actions.ps1' }
)

# Wave 2 adds exactly txt163..txt175 to the languages. A missing or extra key
# inside that range is in-flight work for the tui worker; anything outside the
# range is pre-existing surface and a divergence on it is a real regression.
function Test-ArWave2TextKey {
    param([Parameter(Mandatory = $true)][string]$Key)
    return ($Key -match '^txt(16[3-9]|17[0-5])$')
}

function Get-ArWave2LanguageKeys {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-ArWave2RawText -Path $Path
    return @([regex]::Matches($text, '(?m)^\s*\$txt(\d+)\s*=') |
        ForEach-Object { 'txt' + $_.Groups[1].Value } |
        Sort-Object -Unique)
}

# key -> first definition line, for failure messages that can name a line.
function Get-ArWave2LanguageKeyIndexes {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-ArWave2RawText -Path $Path
    $indexes = @{}
    foreach ($match in [regex]::Matches($text, '(?m)^\s*\$txt(\d+)\s*=') ) {
        $key = 'txt' + $match.Groups[1].Value
        if (-not $indexes.ContainsKey($key)) { $indexes[$key] = Get-ArWave2LineFromOffset -Text $text -Offset $match.Index }
    }
    return $indexes
}

# Every Get-ARText 'txtNNN' (or "txtNNN") key reference in src\*.ps1.
function Get-ArWave2TextReferences {
    $references = New-Object System.Collections.ArrayList
    $quote = [char]39       # '
    $doubleQuote = [char]34 # "
    $pattern = 'Get-ARText\s+[' + $quote + $doubleQuote + ']?(txt\d+)'
    foreach ($path in @(Get-ArSourceFilePaths)) {
        $text = Get-ArWave2RawText -Path $path
        foreach ($match in [regex]::Matches($text, $pattern)) {
            $null = $references.Add([pscustomobject]@{
                Key  = $match.Groups[1].Value
                File = (Split-Path -Leaf $path)
                Line = (Get-ArWave2LineFromOffset -Text $text -Offset $match.Index)
            })
        }
    }
    return @($references.ToArray())
}

# ----------------------------------------------------------------------------
# cleanup contract helpers
# ----------------------------------------------------------------------------

# A text fragment that references the Windows\Temp directory on the target,
# with one or more separators so C:\Windows\Temp, C:/Windows/Temp and
# C:\\Windows\\Temp all match.
function Get-ArWave2TempPathMatch {
    param([string]$Text)
    if ($null -eq $Text) { return $false }
    return ($Text -match '(?i)windows[/\\]+temp')
}

# Normalized variable name: scope prefixes dropped, lowercase.
function Get-ArWave2NamedVariable {
    param([string]$Raw)
    if ($null -eq $Raw) { return '' }
    return (($Raw -replace '^(script|global|local|private):', '').TrimStart('$').ToLowerInvariant())
}

# A param name without its sigil. Windows PowerShell 5.1 hands
# ParameterAst.Name over as a VariableExpressionAst ('$Target'); PowerShell 7
# hands it over as a plain string. Duck-typed, like Get-ArIfClauseParts.
function Get-ArWave2ParameterName {
    param([Parameter(Mandatory = $true)]$Parameter)
    $name = $Parameter.Name
    if ($name -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $name = $name.VariablePath.UserPath
    }
    return ([string]$name).TrimStart('$')
}

function Get-ArWave2AllowedListVariables {
    return @('arremotetempdirs', 'arremotetasks', 'armodulefiles', 'arregistrybackup', 'arfirewallrules')
}

# Pattern for a removal that walks a registered list directly, e.g.
#   Remove-Item -LiteralPath ($script:ARRemoteTempDirs | ...) 
function Get-ArWave2AllowedListPattern {
    return '\$(?:(?:script|global|local|private):)?(ARRemoteTempDirs|ARRemoteTasks|ARModuleFiles|ARRegistryBackup|ARFirewallRules)\b'
}

# Contract 6 for one handler AST. Returns one row per violation with the file,
# the line and the offending command text.
function Get-ArWave2CleanupViolations {
    param(
        [Parameter(Mandatory = $true)]$FunctionAst,
        [Parameter(Mandatory = $true)][string]$File
    )

    $violations = New-Object System.Collections.ArrayList

    # finally ranges ---------------------------------------------------------- #
    # Duck-typed the same way Get-ArIfClauseParts normalizes 5.1 / 7 clause
    # shapes: .Finally is a block statement node on both.
    $finallyRanges = New-Object System.Collections.ArrayList
    foreach ($try in @($FunctionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.TryStatementAst]
    }, $true))) {
        $finallyProperty = $try.PSObject.Properties['Finally']
        if ($null -eq $finallyProperty -or $null -eq $finallyProperty.Value) { continue }
        $null = $finallyRanges.Add([pscustomobject]@{
            Start = [int]$finallyProperty.Value.Extent.StartOffset
            End   = [int]$finallyProperty.Value.Extent.EndOffset
        })
    }

    # variables that carry a Windows\Temp path (assignment, one hop) ---------- #
    #   $remoteDump = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    # A variable assigned from a Join-Path (or any expression) whose text
    # mentions Windows\Temp is marked as temp-carrying.
    $tempVariables = New-Object System.Collections.ArrayList
    foreach ($assignment in @($FunctionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        if ($assignment.Left -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $variableName = Get-ArWave2NamedVariable $assignment.Left.VariablePath.UserPath
        if ([string]::IsNullOrWhiteSpace($variableName)) { continue }
        if ($null -eq $assignment.Right) { continue }
        $carriesTemp = (Get-ArWave2TempPathMatch -Text ([string]$assignment.Right.Extent.Text))
        if (-not $carriesTemp -and $assignment.Right -is [System.Management.Automation.Language.CommandAst] -and
            ([string]$assignment.Right.GetCommandName()) -ieq 'Join-Path') {
            foreach ($element in @($assignment.Right.CommandElements)) {
                if (Get-ArWave2TempPathMatch -Text ([string]$element.Extent.Text)) { $carriesTemp = $true; break }
            }
        }
        if ($carriesTemp -and ($tempVariables -notcontains $variableName)) { $null = $tempVariables.Add($variableName) }
    }

    # remote scriptblocks inherit the temp path by position ------------------- #
    #   Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock { param($path) ... }
    # marks $path temp-carrying when the bound argument at that position is a
    # temp-carrying variable or a Windows\Temp literal. A single array wrapper
    # (@($a, $b)) is not followed: rare shape, and false positives are worse
    # here than one unmapped form.
    foreach ($invoke in @($FunctionAst.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.CommandAst]) -and
        (([string]$node.GetCommandName()) -ieq 'Invoke-Command')
    }, $true))) {
        $elements = @($invoke.CommandElements)
        $argumentListAt = -1
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and
                ($element.ParameterName -ieq 'ArgumentList')) { $argumentListAt = $index; break }
        }
        if ($argumentListAt -lt 0) { continue }
        $bound = New-Object System.Collections.ArrayList
        for ($index = $argumentListAt + 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element -is [System.Management.Automation.Language.CommandParameterAst]) { break }
            if ($element -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { break }
            $null = $bound.Add($element)
        }
        if ($bound.Count -eq 0) { continue }
        $scriptBlockElement = $null
        foreach ($element in $elements) {
            if ($element -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) { $scriptBlockElement = $element; break }
        }
        if ($null -eq $scriptBlockElement) { continue }
        # Duck-typed like Get-ArIfClauseParts: 5.1 calls it .ScriptBlock.
        $scriptBlockAst = $scriptBlockElement.ScriptBlock
        if (-not ($scriptBlockAst -is [System.Management.Automation.Language.ScriptBlockAst])) {
            throw ('internal: unsupported ScriptBlockExpressionAst shape (' + $scriptBlockElement.GetType().FullName + '); refusing to lose the bound-path check silently' )
        }
        $paramBlock = $scriptBlockAst.ParamBlock
        if ($null -eq $paramBlock) { continue }
        $paramNames = @($paramBlock.Parameters | ForEach-Object { Get-ArWave2NamedVariable (Get-ArWave2ParameterName $_) })
        for ($position = 0; $position -lt @($bound.ToArray()).Count; $position++) {
            if ($position -ge $paramNames.Count) { break }
            $argument = $bound[$position]
            $carriesTemp = $false
            if ($argument -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $carriesTemp = ($tempVariables -contains (Get-ArWave2NamedVariable $argument.VariablePath.UserPath))
            }
            elseif ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                $carriesTemp = (Get-ArWave2TempPathMatch -Text ([string]$argument.Value))
            }
            if ($carriesTemp -and ($tempVariables -notcontains $paramNames[$position])) {
                $null = $tempVariables.Add($paramNames[$position])
            }
        }
    }

    # registered cleanup lists ------------------------------------------------ #
    # A variable handed to one of the registered lists (.Add, or += on the
    # list) is owned by the batched cleanup machinery from that point on.
    $allowedLists = @(Get-ArWave2AllowedListVariables)
    $registeredVariables = New-Object System.Collections.ArrayList
    foreach ($invoke in @($FunctionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]
    }, $true))) {
        if ($invoke.Member -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { continue }
        if ([string]$invoke.Member.Value -cne 'Add') { continue }
        if ($invoke.Expression -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $listName = Get-ArWave2NamedVariable $invoke.Expression.VariablePath.UserPath
        if ($allowedLists -notcontains $listName) { continue }
        foreach ($argument in @($invoke.Arguments)) {
            if ($argument -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
            $name = Get-ArWave2NamedVariable $argument.VariablePath.UserPath
            if ($name -and ($registeredVariables -notcontains $name)) { $null = $registeredVariables.Add($name) }
        }
    }
    foreach ($assignment in @($FunctionAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.AssignmentStatementAst]
    }, $true))) {
        if ($assignment.Left -isnot [System.Management.Automation.Language.MemberExpressionAst]) { continue }
        $base = $assignment.Left.Expression
        if ($base -isnot [System.Management.Automation.Language.VariableExpressionAst]) { continue }
        $listName = Get-ArWave2NamedVariable $base.VariablePath.UserPath
        if ($allowedLists -notcontains $listName) { continue }
        if ($assignment.Right -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $name = Get-ArWave2NamedVariable $assignment.Right.VariablePath.UserPath
            if ($name -and ($registeredVariables -notcontains $name)) { $null = $registeredVariables.Add($name) }
        }
    }

    # the sweep: Remove-Item and its aliases on Windows\Temp paths ------------- #
    $removeAliases = @('Remove-Item', 'ri', 'del', 'erase', 'rm')
    $removals = New-Object System.Collections.ArrayList
    foreach ($alias in $removeAliases) {
        foreach ($command in @(Get-ArCommandAsts -Ast $FunctionAst -Name $alias)) { $null = $removals.Add($command) }
    }
    $allowedListPattern = Get-ArWave2AllowedListPattern
    foreach ($command in @($removals.ToArray())) {
        $commandText = [string]$command.Extent.Text
        $targetVariables = New-Object System.Collections.ArrayList
        foreach ($variableMatch in [regex]::Matches($commandText, '\$(?:(?:script|global|local|private):)?([A-Za-z_][A-Za-z0-9_]*)')) {
            $name = $variableMatch.Groups[1].Value.ToLowerInvariant()
            if ($targetVariables -notcontains $name) { $null = $targetVariables.Add($name) }
        }
        $touchesTemp = (Get-ArWave2TempPathMatch -Text $commandText)
        if (-not $touchesTemp) {
            foreach ($name in @($targetVariables.ToArray())) {
                if ($tempVariables -contains $name) { $touchesTemp = $true; break }
            }
        }
        if (-not $touchesTemp) { continue }

        # exemption 1: inside a finally block
        if (Test-ArNodeInRanges -Node $command -Ranges @($finallyRanges.ToArray())) { continue }

        # exemption 2: registered cleanup list machinery
        $exempt = ($commandText -match $allowedListPattern)
        if (-not $exempt) {
            foreach ($name in @($targetVariables.ToArray())) {
                if ($registeredVariables -contains $name) { $exempt = $true; break }
            }
        }
        if ($exempt) { continue }

        $null = $violations.Add([pscustomobject]@{
            File    = $File
            Line    = [int]$command.Extent.StartLineNumber
            Command = ($commandText -replace '\s+', ' ').Trim()
        })
    }
    return @($violations.ToArray())
}

# --------------------------------------------------------------------------- #
# contract 1 and 2a - catalog ids and their handlers
# --------------------------------------------------------------------------- #

Describe 'wave2 catalog ids' {

    It 'declares exactly one catalog entry for every wave2 id' {
        $entries = @(Get-ArCatalogEntries)
        $problems = New-Object System.Collections.ArrayList
        foreach ($target in $script:ArWave2Targets) {
            $located = @($entries | Where-Object { $_.Id -eq $target.Id })
            if ($located.Count -eq 0) {
                $null = $problems.Add(('id {0} is not in Get-ARActionCatalog / Update-ARActionCatalog: no New-ARAction -Id ''{0}'' call anywhere in src\*.ps1' -f $target.Id))
            }
            elseif ($located.Count -gt 1) {
                $sites = (($located | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', ')
                $null = $problems.Add(('id {0} is declared {1} times in Get-ARActionCatalog / Update-ARActionCatalog (New-ARAction calls at: {2})' -f $target.Id, $located.Count, $sites))
            }
        }
        if ($problems.Count -eq 0) { return }
        throw ('wave2 catalog is incomplete: ' + ($problems -join '; '))
    }

    It 'maps every wave2 id to its expected handler' {
        $entries = @(Get-ArCatalogEntries)
        $problems = New-Object System.Collections.ArrayList
        foreach ($target in $script:ArWave2Targets) {
            $located = @($entries | Where-Object { $_.Id -eq $target.Id })
            if ($located.Count -ne 1) { continue }   # absence and duplication belong to the test above
            if ([string]$located[0].Handler -ceq $target.Handler) { continue }
            $null = $problems.Add(('{0}:{1} maps id {2} to ''{3}'', the wave2 contract expects ''{4}''' -f $located[0].File, $located[0].Line, $target.Id, $located[0].Handler, $target.Handler))
        }
        if ($problems.Count -eq 0) { return }
        throw ('wave2 ids do not map to their expected handlers: ' + ($problems -join '; '))
    }
}

# --------------------------------------------------------------------------- #
# contract 2b - each handler is defined exactly once (skip when not landed)
# --------------------------------------------------------------------------- #

Describe 'wave2 handlers' {

    foreach ($target in $script:ArWave2Targets) {
        $definitions = @(Get-ArWave2Definitions -Name $target.Handler)
        $testName = ('id {0} maps to {1} and it is defined exactly once in src\*.ps1' -f $target.Id, $target.Handler)
        if ($definitions.Count -eq 0) {
            It-Skip -Name $testName -Reason ('{0} is not defined anywhere in src\*.ps1 yet: the worker that owns {1} has not landed it. Get-ARActionCatalog / Update-ARActionCatalog already reference id {2}, so Catalog.Tests.ps1 sees the gap too' -f $target.Handler, $target.Owner, $target.Id)
            continue
        }
        It $testName {
            Assert-True ($definitions.Count -eq 1) ('{0} (id {1}) is defined {2} times in src\*.ps1: {3}' -f
                $target.Handler, $target.Id, $definitions.Count,
                (($definitions | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', '))
        }
    }
}

# --------------------------------------------------------------------------- #
# contract 3 - locale keys resolve and all seven files agree
# --------------------------------------------------------------------------- #

Describe 'wave2 locale keys' {

    $languageDirectory = Join-Path $script:ArTestRoot 'Resources\Languages'
    $languageFiles = @(Get-ChildItem -LiteralPath $languageDirectory -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    It 'ships the seven language files' {
        $names = @($languageFiles | ForEach-Object { $_.Name })
        Assert-SetEqual -Expected @('English.ps1', 'French.ps1', 'German.ps1', 'Italian.ps1', 'Portuguese.ps1', 'Russian.ps1', 'Spanish.ps1') `
            -Actual $names `
            -Message 'the wave2 locale contract needs all seven language files; a missing file makes the key-set check meaningless'
    }

    $englishPath = Join-Path $languageDirectory 'English.ps1'
    $englishKeys = @(Get-ArWave2LanguageKeys -Path $englishPath)
    $englishLines = Get-ArWave2LanguageKeyIndexes -Path $englishPath
    $references = @(Get-ArWave2TextReferences)
    $referenceKeys = @($references | ForEach-Object { $_.Key } | Sort-Object -Unique)
    $missingRefKeys = @($referenceKeys | Where-Object { $englishKeys -notcontains $_ })

    if ($missingRefKeys.Count -eq 0) {
        It 'resolves every Get-ARText key referenced by src in English.ps1' { }
    }
    else {
        $regressionKeys = @($missingRefKeys | Where-Object { -not (Test-ArWave2TextKey -Key $_) })
        if ($regressionKeys.Count -eq 0) {
            It-Skip -Name 'resolves every Get-ARText key referenced by src in English.ps1' `
                -Reason ('English.ps1 does not define wave2 keys that src already references ({0}); the tui worker, which owns src\01-core.ps1 and the languages, has not landed them yet' -f ($missingRefKeys -join ', '))
        }
        else {
            It 'resolves every Get-ARText key referenced by src in English.ps1' {
                $details = New-Object System.Collections.ArrayList
                foreach ($key in @($missingRefKeys | Sort-Object -Unique)) {
                    $first = @($references | Where-Object { $_.Key -eq $key })
                    $site = '<no reference site>'
                    if ($first.Count -gt 0) { $site = '{0}:{1}' -f $first[0].File, $first[0].Line }
                    $null = $details.Add('{0} first referenced at {1} is not defined in English.ps1' -f $key, $site)
                }
                throw ('src references keys that English.ps1 does not define: ' + ($details -join '; '))
            }
        }
    }

    foreach ($fileSystem in $languageFiles) {
        $languageFile = $fileSystem
        $keys = @(Get-ArWave2LanguageKeys -Path $languageFile.FullName)
        $lines = Get-ArWave2LanguageKeyIndexes -Path $languageFile.FullName
        $missingKeys = @($englishKeys | Where-Object { $keys -notcontains $_ })
        $extraKeys = @($keys | Where-Object { $englishKeys -notcontains $_ })
        $divergentKeys = @((@($missingKeys) + @($extraKeys)) | Sort-Object -Unique)
        $testName = 'key set matches English: {0}' -f $languageFile.Name
        if ($divergentKeys.Count -eq 0) {
            It $testName { }
            continue
        }
        $regressions = @($divergentKeys | Where-Object { -not (Test-ArWave2TextKey -Key $_) })
        if ($regressions.Count -eq 0) {
            It-Skip -Name $testName `
                -Reason ('{0} diverges from English.ps1 only on wave2 keys ({1}); the tui worker has not landed the full set yet' -f $languageFile.Name, ($divergentKeys -join ', '))
            continue
        }
        It $testName {
            $details = New-Object System.Collections.ArrayList
            foreach ($key in $missingKeys) {
                $englishLine = '<absent>'
                if ($englishLines.ContainsKey($key)) { $englishLine = $englishLines[$key] }
                $null = $details.Add('{0} is missing {1} (English.ps1 line {2})' -f $languageFile.Name, $key, $englishLine)
            }
            foreach ($key in $extraKeys) {
                $line = '<unknown>'
                if ($lines.ContainsKey($key)) { $line = $lines[$key] }
                $null = $details.Add('{0} defines {1} at line {2}, a key English.ps1 does not have' -f $languageFile.Name, $key, $line)
            }
            throw ('{0} does not share the English.ps1 key set: {1}' -f $languageFile.Name, ($details -join '; '))
        }
    }
}

# --------------------------------------------------------------------------- #
# contract 4 - CLI switches in the header param block
# --------------------------------------------------------------------------- #

Describe 'wave2 CLI switches' {

    $headerPath = Join-Path $script:ArTestRoot 'src\01-core.ps1'
    $requiredSwitches = @('Target', 'User', 'Password', 'Mode', 'Yes', 'Config', 'List', 'ListJson')

    It 'parses src\01-core.ps1 with zero errors' {
        Assert-FileExists -Path $headerPath -Message 'src\01-core.ps1 is required to reach its param block'
        $errors = @(Get-ArParseErrors -Path $headerPath)
        if ($errors.Count -eq 0) { return }
        $details = @($errors | ForEach-Object { '01-core.ps1:{0}: {1}' -f $_.Extent.StartLineNumber, $_.Message }) -join '; '
        throw ('the header does not parse, so the switch contract cannot be read from its AST: ' + $details)
    }

    $parseResult = Get-ArParseResult -Path $headerPath
    $paramBlock = $parseResult.Ast.ParamBlock
    $declaredSwitches = @()
    $paramBlockLine = 0
    if ($null -ne $paramBlock) {
        $paramBlockLine = [int]$paramBlock.Extent.StartLineNumber
        $declaredSwitches = @($paramBlock.Parameters | ForEach-Object { Get-ArWave2ParameterName $_ })
    }
    $absentSwitches = @($requiredSwitches | Where-Object { $declaredSwitches -notcontains $_ })

    if ($absentSwitches.Count -eq $requiredSwitches.Count) {
        It-Skip -Name 'declares the wave2 CLI switches' `
            -Reason ('src\01-core.ps1 declares none of {0}; the cli worker has not landed the param block switches yet' -f ($requiredSwitches -join ', '))
    }
    else {
        It 'declares the wave2 CLI switches (Target, User, Password, Mode, Yes, Config, List, ListJson)' {
            if ($absentSwitches.Count -eq 0) { return }
            throw (Format-ArAssertion -Message ('src\01-core.ps1 param block (declared at line {0}) is missing wave2 CLI switches' -f $paramBlockLine) `
                -Expected (($requiredSwitches | Sort-Object) -join ', ') `
                -Actual (($declaredSwitches | Sort-Object) -join ', ') `
                -Detail ('missing: ' + ($absentSwitches -join ', ')))
        }
    }
}

# --------------------------------------------------------------------------- #
# contract 5 - no dead attack/module handlers
# --------------------------------------------------------------------------- #

Describe 'wave2 dead handlers' {

    It 'wires every Invoke-ARAttack* and Invoke-ARModule* in 02-actions to a catalog -Handler' {
        $wired = @(@(Get-ArCatalogEntries) | ForEach-Object { [string]$_.Handler } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $dead = New-Object System.Collections.ArrayList
        foreach ($source in @(Get-ArSourceAsts)) {
            if ($source.File -ne '02-actions.ps1') { continue }
            foreach ($function in @($source.Ast.FindAll({
                param($node)
                ($node -is [System.Management.Automation.Language.FunctionDefinitionAst]) -and
                (($node.Name -like 'Invoke-ARAttack*') -or ($node.Name -like 'Invoke-ARModule*'))
            }, $true))) {
                if ($wired -notcontains $function.Name) {
                    $null = $dead.Add(('"{0}" defined at {1}:{2}' -f $function.Name, $source.File, $function.Extent.StartLineNumber))
                }
            }
        }
        if ($dead.Count -eq 0) { return }
        throw ('dead handlers: defined but no New-ARAction -Handler references them: ' + ($dead -join '; '))
    }
}

# --------------------------------------------------------------------------- #
# contract 6 - cleanup contract on the thirteen wave-2 handlers
# --------------------------------------------------------------------------- #

Describe 'wave2 cleanup contract' {

    foreach ($target in $script:ArWave2Targets) {
        $definitions = @(Get-ArWave2Definitions -Name $target.Handler)
        $testName = ('{0} (id {1}) deletes Windows\Temp paths only via finally or registered cleanup' -f $target.Handler, $target.Id)
        if ($definitions.Count -eq 0) {
            It-Skip -Name $testName -Reason ('{0} is not defined in {1} yet: the worker that owns it has not landed the handler, so nothing can be inspected for {2}' -f $target.Handler, $target.Owner, $target.Id)
            continue
        }
        It $testName {
            $definition = @(Get-ArWave2Definitions -Name $target.Handler)[0]
            $violations = @(Get-ArWave2CleanupViolations -FunctionAst $definition.Ast -File $definition.File)
            if ($violations.Count -eq 0) { return }
            $details = New-Object System.Collections.ArrayList
            foreach ($violation in $violations) {
                $null = $details.Add('{0}:{1} Remove-Item outside a finally block and outside the registered cleanup lists ($script:ARRemoteTempDirs, $script:ARRemoteTasks, $script:ARModuleFiles, $script:ARRegistryBackup, $script:ARFirewallRules): {2}' -f
                    $violation.File, $violation.Line, $violation.Command)
            }
            throw ('cleanup contract broken for {0}: {1}' -f $target.Handler, ($details -join ' | '))
        }
    }
}
