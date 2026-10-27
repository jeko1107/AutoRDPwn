# Tests\TestKit.ps1
#
# Minimal test engine for the AutoRDPwn suite.
#
# Why not Pester: Windows ships Pester 3.4.0, which has no -Skip, and this suite
# needs to report build drift as a warning instead of a hard failure. This engine
# has no module dependency, so the same file runs under Windows PowerShell 5.1
# and PowerShell 7.
#
# Contract with the runner:
#   * the runner dot-sources this file, then each *.Tests.ps1, all in one scope
#   * the runner sets $script:ArTestRoot, $script:ArTestSandbox, $script:ArTestGenPath
#   * helpers here must not emit to the pipeline unless documented

$script:ArTestResults = New-Object System.Collections.ArrayList
$script:ArTestGroup = 'general'
$script:ArTestTempPaths = New-Object System.Collections.ArrayList

# --------------------------------------------------------------------------- #
# results
# --------------------------------------------------------------------------- #

function Add-ArTestResult {
    param(
        [string]$Group,
        [string]$Name,
        [ValidateSet('Pass', 'Fail', 'Skip')][string]$Status,
        [string]$Message = '',
        [long]$Milliseconds = 0
    )
    $null = $script:ArTestResults.Add([pscustomobject]@{
        Group        = $Group
        Name         = $Name
        Status       = $Status
        Message      = $Message
        Milliseconds = $Milliseconds
    })
}

function Get-ArTestResults {
    return @($script:ArTestResults.ToArray())
}

function New-ArTestTempDirectory {
    param([string]$Prefix = 'autordpwn-tests-')
    $path = Join-Path $env:TEMP ($Prefix + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $null = New-Item -ItemType Directory -Path $path -Force
    $null = $script:ArTestTempPaths.Add($path)
    return $path
}

function Clear-ArTestTempDirectories {
    foreach ($path in @($script:ArTestTempPaths.ToArray())) {
        if ($path -and (Test-Path -LiteralPath $path)) {
            Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $script:ArTestTempPaths.Clear()
}

# --------------------------------------------------------------------------- #
# blocks
# --------------------------------------------------------------------------- #

function Describe {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Block
    )
    $previous = $script:ArTestGroup
    $script:ArTestGroup = $Name
    try { & $Block }
    finally { $script:ArTestGroup = $previous }
}

function It {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Block
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Block
        $clock.Stop()
        Add-ArTestResult -Group $script:ArTestGroup -Name $Name -Status 'Pass' -Milliseconds $clock.ElapsedMilliseconds
    }
    catch {
        $clock.Stop()
        Add-ArTestResult -Group $script:ArTestGroup -Name $Name -Status 'Fail' `
            -Message $_.Exception.Message -Milliseconds $clock.ElapsedMilliseconds
    }
}

function It-Skip {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    Add-ArTestResult -Group $script:ArTestGroup -Name $Name -Status 'Skip' -Message $Reason
}

# Warning-level test: passes when the contract holds, reports as a skip (never a
# failure) when it does not. Used for drift against in-flight work.
function It-Warn {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$Block
    )
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        & $Block
        $clock.Stop()
        Add-ArTestResult -Group $script:ArTestGroup -Name $Name -Status 'Pass' -Milliseconds $clock.ElapsedMilliseconds
    }
    catch {
        $clock.Stop()
        Add-ArTestResult -Group $script:ArTestGroup -Name $Name -Status 'Skip' `
            -Message $_.Exception.Message -Milliseconds $clock.ElapsedMilliseconds
    }
}

# --------------------------------------------------------------------------- #
# assertions - every failure names the contract, the expectation and the value
# --------------------------------------------------------------------------- #

function Format-ArAssertion {
    param([string]$Message, [string]$Expected = '', [string]$Actual = '', [string]$Detail = '')
    $lines = New-Object System.Collections.ArrayList
    $null = $lines.Add($Message)
    if ($PSBoundParameters.ContainsKey('Expected')) { $null = $lines.Add('      expected: ' + $Expected) }
    if ($PSBoundParameters.ContainsKey('Actual')) { $null = $lines.Add('      actual:   ' + $Actual) }
    if ($Detail) { $null = $lines.Add('      detail:   ' + $Detail) }
    return ($lines -join [Environment]::NewLine)
}

function Format-ArValue {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    if ($Value -is [string]) {
        if ($Value -eq '') { return '<empty string>' }
        if ($Value.Length -gt 400) { return $Value.Substring(0, 400) + '...' }
        return $Value
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value | ForEach-Object { [string]$_ })
        if ($items.Count -gt 40) {
            return ('<{0} items> ' -f $items.Count) + (($items[0..39]) -join ', ') + ', ...'
        }
        return ($items -join ', ')
    }
    return [string]$Value
}

function Assert-True {
    param($Condition, [Parameter(Mandatory = $true)][string]$Message)
    if ($Condition) { return }
    throw (Format-ArAssertion -Message $Message -Expected 'true' -Actual (Format-ArValue $Condition))
}

function Assert-False {
    param($Condition, [Parameter(Mandatory = $true)][string]$Message)
    if (-not $Condition) { return }
    throw (Format-ArAssertion -Message $Message -Expected 'false' -Actual (Format-ArValue $Condition))
}

function Assert-Equal {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    $equal = $false
    $isEnumerable = {
        param($Value)
        return ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string])
    }
    if ($null -eq $Expected -and $null -eq $Actual) { $equal = $true }
    elseif ($null -eq $Expected -or $null -eq $Actual) { $equal = $false }
    elseif ((& $isEnumerable $Expected) -and (& $isEnumerable $Actual)) {
        $left = [string]::Join([char]1, @($Expected | ForEach-Object { [string]$_ }))
        $right = [string]::Join([char]1, @($Actual | ForEach-Object { [string]$_ }))
        $equal = ($left -ceq $right)
    }
    else { $equal = ($Expected -ceq $Actual) }
    if ($equal) { return }
    throw (Format-ArAssertion -Message $Message -Expected (Format-ArValue $Expected) -Actual (Format-ArValue $Actual))
}

function Assert-Match {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Message)
    if ($null -eq $Text) { $Text = '' }
    if ($Text -match $Pattern) { return }
    throw (Format-ArAssertion -Message $Message -Expected ('match /' + $Pattern + '/') -Actual (Format-ArValue $Text))
}

function Assert-NotMatch {
    param([string]$Text, [Parameter(Mandatory = $true)][string]$Pattern, [Parameter(Mandatory = $true)][string]$Message)
    if ($null -eq $Text) { $Text = '' }
    if (-not ($Text -match $Pattern)) { return }
    throw (Format-ArAssertion -Message $Message -Expected ('no match for /' + $Pattern + '/') -Actual (Format-ArValue $Text))
}

function Assert-NotNull {
    param($Value, [Parameter(Mandatory = $true)][string]$Message)
    if ($null -ne $Value) { return }
    throw (Format-ArAssertion -Message $Message -Expected 'a value' -Actual '<null>')
}

function Assert-FileExists {
    param([Parameter(Mandatory = $true)][string]$Path, [string]$Message)
    if (-not $Message) { $Message = 'expected file to exist' }
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return }
    throw (Format-ArAssertion -Message $Message -Expected ('file ' + $Path) -Actual 'missing')
}

function Assert-SetEqual {
    param($Expected, $Actual, [Parameter(Mandatory = $true)][string]$Message)
    $expectedSet = @($Expected | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $actualSet = @($Actual | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $missing = @($expectedSet | Where-Object { $actualSet -notcontains $_ })
    $extra = @($actualSet | Where-Object { $expectedSet -notcontains $_ })
    if ($missing.Count -eq 0 -and $extra.Count -eq 0) { return }
    $detail = New-Object System.Collections.ArrayList
    if ($missing.Count -gt 0) { $null = $detail.Add('missing: ' + ($missing -join ', ')) }
    if ($extra.Count -gt 0) { $null = $detail.Add('unexpected: ' + ($extra -join ', ')) }
    throw (Format-ArAssertion -Message $Message `
            -Expected (Format-ArValue $expectedSet) -Actual (Format-ArValue $actualSet) `
            -Detail ($detail -join '; '))
}
