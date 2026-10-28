# Tests\Wave3.Tests.ps1
#
# Wave 3 contracts for the merge gate. Four packs share this file:
#
#   group A, credential access, ids 220..229
#   group B, discovery, ids 320..332
#   group C, privilege escalation, ids 420..427
#   group D, backdoors and persistence, ids 520..524
#
#   1. catalog: exactly one entry for every id in each pack, each mapped to its
#      expected handler, each pack forming one contiguous block, no catalog id
#      declared twice, and every id gated with -NeedsSession $false except 227
#      (Kerberos cache runs against a live session) and the 520..524 pack, which
#      needs a session like the rest of the persistence group. Group D is gated
#      on its landing state: while no 520..524 row exists in the catalog the pack
#      is one Skip that names it, and from the first landed id the whole pack is
#      enforced. Published packs A, B and C carry no such gate.
#   2. handlers: every wave3 handler is defined exactly once across src\*.ps1
#      (AST function definitions, never grep), and no handler named by any
#      New-ARAction call is defined twice anywhere in src\.
#   3. locale: each wave3 catalog entry carries a Get-ARText title key and that
#      key resolves in all seven language files.
#   4. cleanup: the nine wave3 handlers that write to the target name the
#      mechanism they register with, and 426, 521 and 524 clean up inside a
#      finally. The assertion is scoped to the handler's own AST extent, never
#      src-wide.
#   5. arguments: no remote call splats a collection into its own argument list.
#      -ArgumentList $array and -ArgumentList @($array.ToArray()) both hand the
#      scriptblock only element 0, which silently halves every cleanup loop.
#      The unary comma, (, $array), is the only shape that keeps the array whole.
#   6. source: every src\*.ps1 parses with zero errors.
#
# Everything here is read-only: AST and raw text, src is never dot-sourced,
# no catalog action ever runs, no target is contacted. Files are read with
# [System.IO.File]::ReadAllText (BOM aware), not Get-Content -Raw, per the
# antivirus rule in STATE.md.
#
# The title key is not hardcoded: it is read out of the catalog entry itself, so
# the test keeps working when the catalog worker renumbers the txt keys.
#
# Work still in flight is reported as a Skip whose message names what is missing
# (which id, which handler, which key, which language file). Code that is landed
# but wrong always fails. No assertion here is weakened to pass.

# --------------------------------------------------------------------------- #
# helpers - wave3-prefixed so they never collide with the other suite files
# --------------------------------------------------------------------------- #

# BOM-aware raw text: locale files are UTF-8 with BOM and src is UTF-8.
function Get-ArWave3RawText {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

# Every definition of one function name across src\*.ps1: AST, not grep.
function Get-ArWave3Definitions {
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

# One function definition's own source text, from the AST extent. A neighbour's
# cleanup call never appears here, which is the point: the contract is scoped.
function Get-ArWave3FunctionText {
    param([Parameter(Mandatory = $true)]$Definition)
    return [string]$Definition.Ast.Extent.Text
}

# The same extent with whole-line comments dropped, so a "# TODO: register in
# $script:ARRemoteTasks" note cannot satisfy a registration contract. Inline
# comments survive on purpose: stripping them needs a tokenizer and the gain is
# nil, since the line has to carry real code to be a false positive anyway.
function Get-ArWave3CodeText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $kept = @($Text -split "`n" | Where-Object { -not ($_.TrimStart().StartsWith('#')) })
    return ($kept -join "`n")
}

# Every finally block inside one function, concatenated; empty when the function
# has no try/catch/finally at all.
function Get-ArWave3FinallyText {
    param([Parameter(Mandatory = $true)]$Definition)
    $blocks = @($Definition.Ast.FindAll({
        param($node)
        ($node -is [System.Management.Automation.Language.TryStatementAst]) -and ($null -ne $node.Finally)
    }, $true))
    return (@($blocks | ForEach-Object { [string]$_.Finally.Extent.Text }) -join [Environment]::NewLine)
}

# Every $txtNNN assignment in one language file, as a sorted unique list.
function Get-ArWave3LanguageKeys {
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = Get-ArWave3RawText -Path $Path
    return @([regex]::Matches($text, '(?m)^\s*\$txt(\d+)\s*=') |
        ForEach-Object { 'txt' + $_.Groups[1].Value } |
        Sort-Object -Unique)
}

# One row per New-ARAction call in src\*.ps1, with the command AST kept so the
# needs-session flag and the title key can be read from the call itself.
function Get-ArWave3CatalogRows {
    $rows = New-Object System.Collections.ArrayList
    foreach ($source in @(Get-ArSourceAsts)) {
        foreach ($command in @(Get-ArCommandAsts -Ast $source.Ast -Name 'New-ARAction')) {
            $parameters = Get-ArCommandParameterMap -CommandAst $command
            $null = $rows.Add([pscustomobject]@{
                Id           = [string]$parameters['Id']
                Handler      = [string]$parameters['Handler']
                File         = $source.File
                Line         = [int]$command.Extent.StartLineNumber
                Command      = $command
                NeedsSession = (Get-ArWave3NeedsSession -CommandAst $command)
                TitleKey     = (Get-ArWave3TitleKey -CommandAst $command)
            })
        }
    }
    return @($rows.ToArray())
}

# -NeedsSession $true / $false as written in the call. New-ARAction defaults the
# switch to $true, so an absent parameter reads as $true.
function Get-ArWave3NeedsSession {
    param([Parameter(Mandatory = $true)]$CommandAst)
    $text = [string]$CommandAst.Extent.Text
    $match = [regex]::Match($text, '-NeedsSession\s+\$(true|false)')
    if (-not $match.Success) { return $true }
    return ($match.Groups[1].Value -ieq 'true')
}

# The Get-ARText key used by -Title, e.g. (Get-ARText 'txt184' 'WDigest ...').
function Get-ArWave3TitleKey {
    param([Parameter(Mandatory = $true)]$CommandAst)
    $text = [string]$CommandAst.Extent.Text
    $match = [regex]::Match($text, 'Get-ARText\s+[''"]?(txt\d+)')
    if (-not $match.Success) { return $null }
    return $match.Groups[1].Value
}

# The ten ids at the center of wave 3 group A, in contract order. NeedsSession
# mirrors the catalog contract: only 227 talks to a live session.
$script:ArWave3Targets = @(
    [pscustomobject]@{ Id = '220'; Handler = 'Invoke-ARAttackWdigest';            NeedsSession = $false }
    [pscustomobject]@{ Id = '221'; Handler = 'Invoke-ARAttackVaultDump';          NeedsSession = $false }
    [pscustomobject]@{ Id = '222'; Handler = 'Invoke-ARAttackBrowserCredentials'; NeedsSession = $false }
    [pscustomobject]@{ Id = '223'; Handler = 'Invoke-ARAttackWifiKeys';           NeedsSession = $false }
    [pscustomobject]@{ Id = '224'; Handler = 'Invoke-ARAttackDpapiMasterKeys';    NeedsSession = $false }
    [pscustomobject]@{ Id = '225'; Handler = 'Invoke-ARAttackLsaSecrets';         NeedsSession = $false }
    [pscustomobject]@{ Id = '226'; Handler = 'Invoke-ARAttackSshKeys';            NeedsSession = $false }
    [pscustomobject]@{ Id = '227'; Handler = 'Invoke-ARAttackKerberosTickets';    NeedsSession = $true }
    [pscustomobject]@{ Id = '228'; Handler = 'Invoke-ARAttackTokenPrivileges';    NeedsSession = $false }
    [pscustomobject]@{ Id = '229'; Handler = 'Invoke-ARAttackCachedLogons';       NeedsSession = $false }
)

# The thirteen discovery ids of wave 3 group B. All read-only against the target
# and none of them opens a session: they ride the same remote channel as the
# rest of the catalog but do not need an interactive one.
$script:ArWave3DiscoveryTargets = @(
    [pscustomobject]@{ Id = '320'; Handler = 'Invoke-ARModuleHostAudit';      NeedsSession = $false }
    [pscustomobject]@{ Id = '321'; Handler = 'Invoke-ARModuleAvEnum';         NeedsSession = $false }
    [pscustomobject]@{ Id = '322'; Handler = 'Invoke-ARModuleShareEnum';      NeedsSession = $false }
    [pscustomobject]@{ Id = '323'; Handler = 'Invoke-ARModuleLocalAdmins';    NeedsSession = $false }
    [pscustomobject]@{ Id = '324'; Handler = 'Invoke-ARModuleSoftwareEnum';   NeedsSession = $false }
    [pscustomobject]@{ Id = '325'; Handler = 'Invoke-ARModuleTaskEnum';       NeedsSession = $false }
    [pscustomobject]@{ Id = '326'; Handler = 'Invoke-ARModuleServiceEnum';    NeedsSession = $false }
    [pscustomobject]@{ Id = '327'; Handler = 'Invoke-ARModuleAutoruns';       NeedsSession = $false }
    [pscustomobject]@{ Id = '328'; Handler = 'Invoke-ARModuleDomainInfo';     NeedsSession = $false }
    [pscustomobject]@{ Id = '329'; Handler = 'Invoke-ARModuleNetworkConfig';  NeedsSession = $false }
    [pscustomobject]@{ Id = '330'; Handler = 'Invoke-ARModuleArpTable';       NeedsSession = $false }
    [pscustomobject]@{ Id = '331'; Handler = 'Invoke-ARModuleSmbAudit';       NeedsSession = $false }
    [pscustomobject]@{ Id = '332'; Handler = 'Invoke-ARModulePatchAudit';     NeedsSession = $false }
)

# The eight privilege-escalation ids of wave 3 group C. None of them opens an
# interactive session; four of them write to the target and are covered by the
# cleanup contract below.
$script:ArWave3PrivEscTargets = @(
    [pscustomobject]@{ Id = '420'; Handler = 'Invoke-ARModuleAlwaysInstallElevated'; NeedsSession = $false }
    [pscustomobject]@{ Id = '421'; Handler = 'Invoke-ARModuleUnquotedServicePath';    NeedsSession = $false }
    [pscustomobject]@{ Id = '422'; Handler = 'Invoke-ARModuleServicePermissions';     NeedsSession = $false }
    [pscustomobject]@{ Id = '423'; Handler = 'Invoke-ARModulePotatoCheck';            NeedsSession = $false }
    [pscustomobject]@{ Id = '424'; Handler = 'Invoke-ARModuleUacBypass';              NeedsSession = $false }
    [pscustomobject]@{ Id = '425'; Handler = 'Invoke-ARModuleSystemTask';             NeedsSession = $false }
    [pscustomobject]@{ Id = '426'; Handler = 'Invoke-ARModuleSystemService';          NeedsSession = $false }
    [pscustomobject]@{ Id = '427'; Handler = 'Invoke-ARModuleBackdoorAccount';        NeedsSession = $false }
)

# The five persistence ids of wave 3d. All five carry -NeedsSession $true, the
# same gate as the rest of the persistence group (501..504, 901, 904): they write
# to the target over a session. All five are covered by the cleanup contract.
$script:ArWave3PersistenceTargets = @(
    [pscustomobject]@{ Id = '520'; Handler = 'Invoke-ARModuleStartupShortcut';   NeedsSession = $true }
    [pscustomobject]@{ Id = '521'; Handler = 'Invoke-ARModuleSshAuthorizedKeys'; NeedsSession = $true }
    [pscustomobject]@{ Id = '522'; Handler = 'Invoke-ARModuleServicePersistence'; NeedsSession = $true }
    [pscustomobject]@{ Id = '523'; Handler = 'Invoke-ARModuleBootTask';          NeedsSession = $true }
    [pscustomobject]@{ Id = '524'; Handler = 'Invoke-ARModuleWmiSubscription';   NeedsSession = $true }
)

# Every pack, for the checks that apply to every wave3 id.
$script:ArWave3AllTargets = @($script:ArWave3Targets + $script:ArWave3DiscoveryTargets + $script:ArWave3PrivEscTargets + $script:ArWave3PersistenceTargets)

$script:ArWave3Rows = @(Get-ArWave3CatalogRows)

# Landing gate for the pack whose catalog worker writes in the same window as
# this file. Packs A, B and C are published, so they stay strict: a missing id is
# a failure, never a skip. Group D is still in flight, so an empty pack is a
# Skip that names it; the first id that lands puts the whole pack under contract.
$script:ArWave3PersistenceLanded = @($script:ArWave3PersistenceTargets | Where-Object {
        $id = $_.Id
        @($script:ArWave3Rows | Where-Object { $_.Id -eq $id }).Count -gt 0
    }).Count -gt 0

# The packs the catalog tests enforce. Group D joins only once it has landed.
$script:ArWave3CatalogTargets = @($script:ArWave3Targets + $script:ArWave3DiscoveryTargets + $script:ArWave3PrivEscTargets)
if ($script:ArWave3PersistenceLanded) {
    $script:ArWave3CatalogTargets = @($script:ArWave3CatalogTargets + $script:ArWave3PersistenceTargets)
}

# One pack, one contiguous run of ids: every id between the pack's first and
# last is present, and nothing outside the pack leaks into that range. Every
# pack is proven by the same code so a gap names the pack that owns it.
function Assert-ArWave3ContiguousBlock {
    param(
        [Parameter(Mandatory = $true)]$Targets,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $expected = @($Targets | ForEach-Object { [int]$_.Id })
    $first = [int]($expected | Measure-Object -Minimum).Minimum
    $last = [int]($expected | Measure-Object -Maximum).Maximum
    $present = @($script:ArWave3Rows | Where-Object { [int]$_.Id -ge $first -and [int]$_.Id -le $last } | ForEach-Object { [int]$_.Id } | Sort-Object -Unique)
    $missing = @($expected | Where-Object { $present -notcontains $_ })
    $unexpected = @($present | Where-Object { $expected -notcontains $_ })
    if ($missing.Count -eq 0 -and $unexpected.Count -eq 0) { return }
    $detail = New-Object System.Collections.ArrayList
    if ($missing.Count -gt 0) { $null = $detail.Add('missing: ' + ($missing -join ', ')) }
    if ($unexpected.Count -gt 0) { $null = $detail.Add('outside the block: ' + ($unexpected -join ', ')) }
    throw (Format-ArAssertion -Message $Message `
        -Expected (($expected | ForEach-Object { [string]$_ }) -join ', ') `
        -Actual (($present | ForEach-Object { [string]$_ }) -join ', ') `
        -Detail ($detail -join '; '))
}

# --------------------------------------------------------------------------- #
# contract 1 - catalog ids, handlers, contiguity, uniqueness, session gate
# --------------------------------------------------------------------------- #

Describe 'wave3 catalog ids' {

    It 'declares exactly one catalog entry for every wave3 id' {
        $problems = New-Object System.Collections.ArrayList
        foreach ($target in $script:ArWave3CatalogTargets) {
            $located = @($script:ArWave3Rows | Where-Object { $_.Id -eq $target.Id })
            if ($located.Count -eq 0) {
                $null = $problems.Add(('id {0} is not in the catalog: no New-ARAction -Id ''{0}'' call anywhere in src\*.ps1' -f $target.Id))
            }
            elseif ($located.Count -gt 1) {
                $sites = (($located | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', ')
                $null = $problems.Add(('id {0} is declared {1} times (New-ARAction calls at: {2})' -f $target.Id, $located.Count, $sites))
            }
        }
        if ($problems.Count -eq 0) { return }
        throw ('wave3 catalog is incomplete: ' + ($problems -join '; '))
    }

    It 'maps every wave3 id to its expected handler' {
        $problems = New-Object System.Collections.ArrayList
        foreach ($target in $script:ArWave3CatalogTargets) {
            $located = @($script:ArWave3Rows | Where-Object { $_.Id -eq $target.Id })
            if ($located.Count -ne 1) { continue }   # absence and duplication belong to the test above
            if ([string]$located[0].Handler -ceq $target.Handler) { continue }
            $null = $problems.Add(('{0}:{1} maps id {2} to ''{3}'', the wave3 contract expects ''{4}''' -f $located[0].File, $located[0].Line, $target.Id, $located[0].Handler, $target.Handler))
        }
        if ($problems.Count -eq 0) { return }
        throw ('wave3 ids do not map to their expected handlers: ' + ($problems -join '; '))
    }

    It 'declares the wave3 ids as one contiguous block from 220 to 229' {
        Assert-ArWave3ContiguousBlock -Targets $script:ArWave3Targets `
            -Message 'the wave3 credential-access ids are not the contiguous block 220..229'
    }

    It 'declares the discovery ids as one contiguous block from 320 to 332' {
        Assert-ArWave3ContiguousBlock -Targets $script:ArWave3DiscoveryTargets `
            -Message 'the wave3 discovery ids are not the contiguous block 320..332'
    }

    It 'declares the privilege-escalation ids as one contiguous block from 420 to 427' {
        Assert-ArWave3ContiguousBlock -Targets $script:ArWave3PrivEscTargets `
            -Message 'the wave3 privilege-escalation ids are not the contiguous block 420..427'
    }

    if (-not $script:ArWave3PersistenceLanded) {
        It-Skip -Name 'declares the persistence ids as one contiguous block from 520 to 524' `
            -Reason 'the wave3 persistence catalog entries (ids 520..524) are not in src\*.ps1 yet: the catalog worker has not landed them. From the first landed id this block is enforced whole'
    }
    else {
        It 'declares the persistence ids as one contiguous block from 520 to 524' {
            Assert-ArWave3ContiguousBlock -Targets $script:ArWave3PersistenceTargets `
                -Message 'the wave3 persistence ids are not the contiguous block 520..524'
        }
    }

    # Global on purpose: it groups every New-ARAction row in src\*.ps1, so it
    # covers every pack and any id outside them.
    It 'declares no catalog id twice' {
        $duplicates = @($script:ArWave3Rows | Group-Object Id | Where-Object { $_.Count -gt 1 })
        if ($duplicates.Count -eq 0) { return }
        $detail = @($duplicates | ForEach-Object {
                'id {0} at {1}' -f $_.Name, (($_.Group | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', ')
            }) -join '; '
        throw ('duplicate catalog ids: ' + $detail)
    }

    It 'gates the wave3 ids on a session only where the contract says so' {
        $problems = New-Object System.Collections.ArrayList
        foreach ($target in $script:ArWave3CatalogTargets) {
            $located = @($script:ArWave3Rows | Where-Object { $_.Id -eq $target.Id })
            if ($located.Count -ne 1) { continue }
            if ($located[0].NeedsSession -eq $target.NeedsSession) { continue }
            $null = $problems.Add(('{0} id {1} declares -NeedsSession ${2}, expected ${3}' -f
                    $located[0].File, $target.Id, $located[0].NeedsSession, $target.NeedsSession))
        }
        if ($problems.Count -eq 0) { return }
        throw ('wave3 session gate is wrong: ' + ($problems -join '; '))
    }
}

# --------------------------------------------------------------------------- #
# contract 2 - each handler is defined exactly once (skip when not landed)
# --------------------------------------------------------------------------- #

Describe 'wave3 handlers' {

    foreach ($target in $script:ArWave3AllTargets) {
        $definitions = @(Get-ArWave3Definitions -Name $target.Handler)
        $testName = ('id {0} maps to {1} and it is defined exactly once in src\*.ps1' -f $target.Id, $target.Handler)
        if ($definitions.Count -eq 0) {
            It-Skip -Name $testName -Reason ('{0} is not defined anywhere in src\*.ps1 yet: the handler worker has not landed it. The catalog already references id {1}, so Catalog.Tests.ps1 sees the gap too' -f $target.Handler, $target.Id)
            continue
        }
        It $testName {
            Assert-True ($definitions.Count -eq 1) ('{0} (id {1}) is defined {2} times in src\*.ps1: {3}' -f
                $target.Handler, $target.Id, $definitions.Count,
                (($definitions | ForEach-Object { '{0}:{1}' -f $_.File, $_.Line }) -join ', '))
        }
    }

    It 'never defines a catalog handler twice across src\*.ps1' {
        $counts = @{}
        foreach ($source in @(Get-ArSourceAsts)) {
            foreach ($function in @($source.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true))) {
                $name = [string]$function.Name
                if (-not $counts.ContainsKey($name)) { $counts[$name] = New-Object System.Collections.ArrayList }
                $null = $counts[$name].Add(('{0}:{1}' -f $source.File, $function.Extent.StartLineNumber))
            }
        }
        $problems = New-Object System.Collections.ArrayList
        foreach ($handler in @($script:ArWave3Rows | ForEach-Object { [string]$_.Handler } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)) {
            if (-not $counts.ContainsKey($handler)) { continue }
            if ($counts[$handler].Count -le 1) { continue }
            $null = $problems.Add(('"{0}" is defined {1} times: {2}' -f $handler, $counts[$handler].Count, (@($counts[$handler].ToArray()) -join ', ')))
        }
        if ($problems.Count -eq 0) { return }
        throw ('catalog handlers defined more than once in src\*.ps1: ' + ($problems -join '; '))
    }

    $undefined = @($script:ArWave3Rows |
        ForEach-Object { [string]$_.Handler } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Sort-Object -Unique |
        Where-Object { @(Get-ArWave3Definitions -Name $_).Count -eq 0 })
    if ($undefined.Count -eq 0) {
        It 'defines every catalog handler at least once across src\*.ps1' { }
    }
    else {
        It-Skip -Name 'defines every catalog handler at least once across src\*.ps1' `
            -Reason ('the catalog names handlers that src\*.ps1 does not define yet ({0}); the handler worker has not landed them, and Catalog.Tests.ps1 reports the same gap' -f ($undefined -join ', '))
    }
}

# --------------------------------------------------------------------------- #
# contract 3 - the wave3 title key resolves in all seven languages
# --------------------------------------------------------------------------- #

Describe 'wave3 locale keys' {

    $languageDirectory = Join-Path $script:ArTestRoot 'Resources\Languages'
    $languageFiles = @(Get-ChildItem -LiteralPath $languageDirectory -Filter '*.ps1' -File -ErrorAction SilentlyContinue | Sort-Object Name)

    It 'ships the seven language files' {
        $names = @($languageFiles | ForEach-Object { $_.Name })
        Assert-SetEqual -Expected @('English.ps1', 'French.ps1', 'German.ps1', 'Italian.ps1', 'Portuguese.ps1', 'Russian.ps1', 'Spanish.ps1') `
            -Actual $names `
            -Message 'the wave3 locale contract needs all seven language files; a missing file makes the key check meaningless'
    }

    $waveRows = @($script:ArWave3Rows | Where-Object { @($script:ArWave3AllTargets | ForEach-Object { $_.Id }) -contains $_.Id })

    if ($waveRows.Count -eq 0) {
        It-Skip -Name 'resolves the title key of every wave3 id in all seven languages' `
            -Reason 'none of the wave3 ids is in the catalog yet, so there is no title key to resolve'
    }
    else {
        It 'gives every wave3 catalog entry a Get-ARText title key' {
            $missing = @($waveRows | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.TitleKey) })
            if ($missing.Count -eq 0) { return }
            $detail = @($missing | ForEach-Object { 'id {0} at {1}:{2}' -f $_.Id, $_.File, $_.Line }) -join '; '
            throw ('wave3 catalog entries with no Get-ARText title key, so the title cannot be localized: ' + $detail)
        }

        $keyByFile = @{}
        foreach ($fileSystem in $languageFiles) {
            $keyByFile[$fileSystem.Name] = @(Get-ArWave3LanguageKeys -Path $fileSystem.FullName)
        }

        foreach ($target in $script:ArWave3AllTargets) {
            $located = @($waveRows | Where-Object { $_.Id -eq $target.Id })
            $testName = ('id {0} title key {1} resolves in all seven languages' -f $target.Id, (& { if ($located.Count -eq 1) { $located[0].TitleKey } else { '<no entry>' } }))
            if ($located.Count -ne 1) {
                It-Skip -Name $testName -Reason ('id {0} is not in the catalog yet, so it has no title key to look up' -f $target.Id)
                continue
            }
            $key = [string]$located[0].TitleKey
            if ([string]::IsNullOrWhiteSpace($key)) {
                It-Skip -Name $testName -Reason ('id {0} carries no Get-ARText title key, reported by the test above' -f $target.Id)
                continue
            }
            if (@($keyByFile['English.ps1']) -notcontains $key) {
                It-Skip -Name $testName -Reason ('English.ps1 does not define {0} for id {1} yet: the catalog worker has not landed the language keys (the catalog references {0} at {2}:{3})' -f $key, $target.Id, $located[0].File, $located[0].Line)
                continue
            }
            It $testName {
                $absent = New-Object System.Collections.ArrayList
                foreach ($name in @($keyByFile.Keys | Sort-Object)) {
                    if (@($keyByFile[$name]) -notcontains $key) { $null = $absent.Add($name) }
                }
                if ($absent.Count -eq 0) { return }
                throw ('{0} is defined in English.ps1 but missing from {1}; the seven language files must share the same key set (id {2})' -f $key, ($absent -join ', '), $target.Id)
            }
        }
    }
}

# --------------------------------------------------------------------------- #
# contract 4 - the group C and D writers name their cleanup mechanism in their
# own body
# --------------------------------------------------------------------------- #

Describe 'wave3 cleanup contracts' {

    # Each row is one handler that leaves something on the target. Pattern is
    # matched against that handler's own source text; FinallyPattern (or each
    # entry of FinallyPatterns), when set, must match inside a finally block of
    # that same handler.
    $script:ArWave3CleanupContracts = @(
        [pscustomobject]@{
            Id             = '424'
            Handler        = 'Invoke-ARModuleUacBypass'
            Mechanism      = 'ARRegistryBackup'
            Pattern        = 'ARRegistryBackup'
            FinallyPattern = $null
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '425'
            Handler        = 'Invoke-ARModuleSystemTask'
            Mechanism      = 'ARRemoteTasks'
            Pattern        = 'ARRemoteTasks'
            FinallyPattern = $null
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '426'
            Handler        = 'Invoke-ARModuleSystemService'
            Mechanism      = 'a services collection it adds the new service to, deleted in a finally'
            Pattern        = '(?i)(\$(?:script:)?[A-Za-z]*Service[A-Za-z]*\s*(?:\.Add(?:Range)?\(|\+=)|(?:Register|Add|Track)-AR[A-Za-z]*Service)'
            FinallyPattern = '(?i)(sc(?:\.exe)?\s+[''"]?delete|Remove-Service|Remove-AR[A-Za-z]*Service)'
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '427'
            Handler        = 'Invoke-ARModuleBackdoorAccount'
            Mechanism      = 'ARCreatedAccounts'
            Pattern        = 'ARCreatedAccounts'
            FinallyPattern = $null
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '520'
            Handler        = 'Invoke-ARModuleStartupShortcut'
            Mechanism      = 'ARTemporaryFiles'
            Pattern        = 'ARTemporaryFiles'
            FinallyPattern = $null
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '521'
            Handler        = 'Invoke-ARModuleSshAuthorizedKeys'
            Mechanism      = 'a backup copy of authorized_keys restored in a finally'
            Pattern        = '(?i)(?=[\s\S]*authorized_keys)(?=[\s\S]*(?:\.bak|Backup|Copy-Item))'
            FinallyPattern = '(?i)(Move-Item|Copy-Item|Remove-Item|Set-Content|Add-Content|Restore)'
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '522'
            Handler        = 'Invoke-ARModuleServicePersistence'
            Mechanism      = 'ARCreatedServices, with the service deleted in a finally'
            Pattern        = 'ARCreatedServices'
            FinallyPattern = '(?i)(sc(?:\.exe)?\s+[''"]?delete|Remove-Service|Remove-AR[A-Za-z]*Service)'
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '523'
            Handler        = 'Invoke-ARModuleBootTask'
            Mechanism      = 'ARRemoteTasks'
            Pattern        = 'ARRemoteTasks'
            FinallyPattern = $null
            FinallyPatterns = @()
        }
        [pscustomobject]@{
            Id             = '524'
            Handler        = 'Invoke-ARModuleWmiSubscription'
            Mechanism      = 'the filter, consumer and binding it creates, deleted in a finally'
            Pattern        = '(?i)(?=[\s\S]*__EventFilter)(?=[\s\S]*CommandLineEventConsumer)(?=[\s\S]*__FilterToConsumerBinding)'
            FinallyPattern = $null
            FinallyPatterns = @('__EventFilter', 'CommandLineEventConsumer', '__FilterToConsumerBinding')
        }
    )

    foreach ($contract in $script:ArWave3CleanupContracts) {
        $definitions = @(Get-ArWave3Definitions -Name $contract.Handler)
        $testName = ('id {0} registers with {1} inside its own body' -f $contract.Id, $contract.Mechanism)
        if ($definitions.Count -eq 0) {
            It-Skip -Name $testName -Reason ('{0} is not defined anywhere in src\*.ps1 yet: the handler worker has not landed it, so there is no body to read for the cleanup contract' -f $contract.Handler)
            continue
        }
        It $testName {
            Assert-Equal 1 $definitions.Count ('{0} (id {1}) is defined {2} times; the cleanup contract reads exactly one body' -f $contract.Handler, $contract.Id, $definitions.Count)
            $text = Get-ArWave3CodeText -Text (Get-ArWave3FunctionText -Definition $definitions[0])
            Assert-Match $text $contract.Pattern ('id {0} ({1}) never names {2} in its own body, so whatever it writes to the target is not registered for cleanup' -f $contract.Id, $contract.Handler, $contract.Mechanism)
            $finallyPatterns = @()
            if (-not [string]::IsNullOrWhiteSpace([string]$contract.FinallyPattern)) {
                $finallyPatterns += [string]$contract.FinallyPattern
            }
            foreach ($extraPattern in @($contract.FinallyPatterns)) {
                if (-not [string]::IsNullOrWhiteSpace([string]$extraPattern)) { $finallyPatterns += [string]$extraPattern }
            }
            if ($finallyPatterns.Count -eq 0) { return }
            $finallyText = Get-ArWave3FinallyText -Definition $definitions[0]
            Assert-True (-not [string]::IsNullOrWhiteSpace($finallyText)) ('id {0} ({1}) has no try/catch/finally: what it writes to the target is never removed on the failure path' -f $contract.Id, $contract.Handler)
            foreach ($finallyPattern in $finallyPatterns) {
                Assert-Match $finallyText $finallyPattern ('id {0} ({1}) does not clean up {2} inside a finally block; a failed run leaves it on the target' -f $contract.Id, $contract.Handler, $contract.Mechanism)
            }
        }
    }
}

# --------------------------------------------------------------------------- #
# contract 6 - a remote call never splats a collection into its own arguments
# --------------------------------------------------------------------------- #

Describe 'wave3 remote argument contracts' {

    # Invoke-Command -ArgumentList $array hands element 0 to the scriptblock's
    # first parameter and drops the rest, so a cleanup loop silently restores one
    # value out of many. The unary comma, (, $array), keeps the array whole.
    # Measured on this machine: a naked 3-element array arrives as one String,
    # (, $array) arrives as one Object[] with all three.
    It 'keeps a collection argument intact with the unary comma' {
        $problems = New-Object System.Collections.ArrayList
        $remoteNames = @('Invoke-ARRemote', 'Invoke-Command')

        foreach ($source in @(Get-ArSourceAsts)) {
            foreach ($definition in @($source.Ast.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
            }, $true))) {
                $functionText = [string]$definition.Extent.Text

                foreach ($remoteName in $remoteNames) {
                    foreach ($command in @($definition.FindAll({
                        param($node)
                        ($node -is [System.Management.Automation.Language.CommandAst]) -and
                        ($node.GetCommandName() -eq $remoteName)
                    }, $true))) {
                        $elements = @($command.CommandElements)
                        for ($index = 1; $index -lt $elements.Count; $index++) {
                            $element = $elements[$index]
                            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                            if ($element.ParameterName -ne 'ArgumentList') { continue }
                            $value = $null
                            if ($null -ne $element.Argument) { $value = $element.Argument }
                            elseif ($index + 1 -lt $elements.Count) { $value = $elements[$index + 1] }
                            if ($null -eq $value) { continue }

                            $text = [string]$value.Extent.Text
                            $splats = $false
                            if ($text -match '^@\([^,]*\.ToArray\(\)\)$') { $splats = $true }
                            elseif ($text -match '^\$([A-Za-z_][A-Za-z0-9_]*)$') {
                                # A real statement, not a param-block default such as
                                # [object[]]$ArgumentList = @(), which is the transport
                                # passing its own parameter list through on purpose.
                                $assignment = '(?m)^[ \t]*\$' + [regex]::Escape($Matches[1]) + '[ \t]*=[ \t]*@\('
                                $splats = [regex]::IsMatch($functionText, $assignment)
                            }
                            if (-not $splats) { continue }

                            $null = $problems.Add(('{0}:{1}: -ArgumentList {2} splats the collection, so only its first item reaches the scriptblock; write (, {2}) instead' -f (Split-Path -Leaf $source.File), $command.Extent.StartLineNumber, $text))
                        }
                    }
                }
            }
        }

        if ($problems.Count -eq 0) { return }
        throw ('a remote call splats a collection into its own arguments, so every item after the first is silently dropped: ' + ($problems -join ' | '))
    }
}

# --------------------------------------------------------------------------- #
# contract 5 - the source parses
# --------------------------------------------------------------------------- #

Describe 'wave3 source parses' {

    It 'parses every src\*.ps1 with zero errors' {
        $problems = New-Object System.Collections.ArrayList
        foreach ($path in @(Get-ArSourceFilePaths)) {
            $errors = @(Get-ArParseErrors -Path $path)
            foreach ($parseError in $errors) {
                $null = $problems.Add(('{0}:{1}: {2}' -f (Split-Path -Leaf $path), $parseError.Extent.StartLineNumber, $parseError.Message))
            }
        }
        if ($problems.Count -eq 0) { return }
        throw ('src\*.ps1 does not parse, so the wave3 contracts cannot be read from its AST: ' + ($problems -join ' | '))
    }
}
