# Tests\Run-Tests.ps1
#
# AutoRDPwn test runner. No module dependency, no network, no elevation, no
# catalog action is executed.
#
# Build gate: the suite compiles src\ through Build.ps1 with an explicit
# -OutputPath under _sandbox\. Build.ps1 without -OutputPath overwrites the
# versioned AutoRDPwn.ps1, which is exactly the work this suite exists to protect.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
#   pwsh -NoProfile -File .\Tests\Run-Tests.ps1
#   .\Tests\Run-Tests.ps1 -Filter 'Catalog*' -Detailed
#
# Exit code: 0 when nothing failed, 1 otherwise. Skips (drift warnings) do not
# change the exit code.

[CmdletBinding()]
param(
    [string]$Filter = '*',
    [switch]$Detailed,
    [switch]$NoBuild
)

$ErrorActionPreference = 'Stop'
$script:ArTestRoot = Split-Path -Parent $PSScriptRoot
$script:ArTestSandbox = Join-Path $script:ArTestRoot '_sandbox'
$script:ArTestGenPath = Join-Path $script:ArTestSandbox 'gen.ps1'

. (Join-Path $PSScriptRoot 'TestKit.ps1')
. (Join-Path $PSScriptRoot 'ArAst.ps1')

$totalClock = [System.Diagnostics.Stopwatch]::StartNew()
$failed = 0

function Write-Section {
    param([string]$Text, [string]$Color = 'Cyan')
    Write-Host ''
    Write-Host $Text -ForegroundColor $Color
}

# --------------------------------------------------------------------------- #
# header
# --------------------------------------------------------------------------- #

$hostLabel = 'PowerShell ' + $PSVersionTable.PSVersion.ToString()
if ($PSVersionTable.ContainsKey('PSEdition')) { $hostLabel = $hostLabel + ' (' + $PSVersionTable.PSEdition + ')' }
$pester = Get-Module -ListAvailable Pester -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending | Select-Object -First 1
if ($null -eq $pester) {
    $pesterLabel = 'not installed (built-in engine)'
}
else {
    $pesterLabel = '{0} available, unused (built-in engine: Pester < 4 has no -Skip)' -f $pester.Version
}

Write-Host ''
Write-Host 'AutoRDPwn test suite' -ForegroundColor White
Write-Host ('  root   ' + $script:ArTestRoot) -ForegroundColor DarkGray
Write-Host ('  host   ' + $hostLabel) -ForegroundColor DarkGray
Write-Host ('  pester ' + $pesterLabel) -ForegroundColor DarkGray

# --------------------------------------------------------------------------- #
# build gate - always into _sandbox
# --------------------------------------------------------------------------- #

if (-not (Test-Path -LiteralPath $script:ArTestSandbox)) {
    $null = New-Item -ItemType Directory -Path $script:ArTestSandbox -Force
}

if ($NoBuild) {
    Write-Host ('  build  reused ' + $script:ArTestGenPath + ' (-NoBuild)') -ForegroundColor DarkGray
}
else {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $buildOutput = @(& (Join-Path $script:ArTestRoot 'Build.ps1') -OutputPath $script:ArTestGenPath *>&1 |
            ForEach-Object { [string]$_ })
        $clock.Stop()
        $size = 0
        if (Test-Path -LiteralPath $script:ArTestGenPath) { $size = (Get-Item -LiteralPath $script:ArTestGenPath).Length }
        Add-ArTestResult -Group 'build' -Name 'compiles src into _sandbox\gen.ps1' -Status 'Pass' -Milliseconds $clock.ElapsedMilliseconds
        Write-Host ('  build  _sandbox\gen.ps1 ({0} bytes)' -f $size) -ForegroundColor DarkGray
    }
    catch {
        $clock.Stop()
        $tail = ''
        if ($buildOutput) { $tail = ($buildOutput | Select-Object -Last 5) -join ' | ' }
        Add-ArTestResult -Group 'build' -Name 'compiles src into _sandbox\gen.ps1' -Status 'Fail' `
            -Message ($_.Exception.Message + $(if ($tail) { ' [' + $tail + ']' } else { '' })) -Milliseconds $clock.ElapsedMilliseconds
        Write-Host '  build  FAILED' -ForegroundColor Red
    }
}

# --------------------------------------------------------------------------- #
# test files
# --------------------------------------------------------------------------- #

$testFiles = @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter '*.Tests.ps1' -File |
    Where-Object { $_.Name -like $Filter } |
    Sort-Object Name)

if ($testFiles.Count -eq 0) {
    Add-ArTestResult -Group 'runner' -Name 'discovers test files' -Status 'Fail' -Message ('no *.Tests.ps1 matched filter ''' + $Filter + '''')
}
else {
    foreach ($file in $testFiles) {
        try {
            . $file.FullName
        }
        catch {
            Add-ArTestResult -Group 'runner' -Name ('loads ' + $file.Name) -Status 'Fail' `
                -Message ('the test file threw while loading, no test in it ran: ' + $_.Exception.Message)
        }
    }
}

# --------------------------------------------------------------------------- #
# legacy TUI suite (existing file, runs in its own process)
# --------------------------------------------------------------------------- #

$tuiPath = Join-Path $PSScriptRoot 'Test-Tui.ps1'
if ((Test-Path -LiteralPath $tuiPath) -and ($Filter -eq '*')) {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $hostExe = 'powershell.exe'
    try { $hostExe = (Get-Process -Id $PID).Path } catch { }
    $tuiOutput = @()
    $tuiExit = 1
    try {
        $tuiOutput = @(& $hostExe -NoProfile -ExecutionPolicy Bypass -File $tuiPath 2>&1 | ForEach-Object { [string]$_ })
        $tuiExit = $LASTEXITCODE
    }
    catch {
        $tuiOutput = @($_.Exception.Message)
    }
    $clock.Stop()
    $summary = @($tuiOutput | Where-Object { $_ -match 'checks,.*failure' } | Select-Object -Last 1)
    if ($tuiExit -eq 0 -and $summary) {
        Add-ArTestResult -Group 'legacy' -Name 'TUI suite (Test-Tui.ps1)' -Status 'Pass' -Milliseconds $clock.ElapsedMilliseconds
        Write-Host ('  legacy ' + $summary) -ForegroundColor DarkGray
    }
    else {
        $tail = ($tuiOutput | Select-Object -Last 6) -join ' | '
        Add-ArTestResult -Group 'legacy' -Name 'TUI suite (Test-Tui.ps1)' -Status 'Fail' `
            -Message ('exit code ' + $tuiExit + ': ' + $tail) -Milliseconds $clock.ElapsedMilliseconds
    }
}

# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #

$results = @(Get-ArTestResults)
$failed = @($results | Where-Object { $_.Status -eq 'Fail' }).Count
$skipped = @($results | Where-Object { $_.Status -eq 'Skip' }).Count
$passed = @($results | Where-Object { $_.Status -eq 'Pass' }).Count
$totalClock.Stop()

$groups = @($results | ForEach-Object { $_.Group } | Select-Object -Unique)

foreach ($group in $groups) {
    $groupResults = @($results | Where-Object { $_.Group -eq $group })
    $groupPassed = @($groupResults | Where-Object { $_.Status -eq 'Pass' }).Count
    $groupFailed = @($groupResults | Where-Object { $_.Status -eq 'Fail' }).Count
    $groupSkipped = @($groupResults | Where-Object { $_.Status -eq 'Skip' }).Count

    $counts = New-Object System.Collections.ArrayList
    if ($groupPassed -gt 0) { $null = $counts.Add(('{0} passed' -f $groupPassed)) }
    if ($groupFailed -gt 0) { $null = $counts.Add(('{0} failed' -f $groupFailed)) }
    if ($groupSkipped -gt 0) { $null = $counts.Add(('{0} skipped' -f $groupSkipped)) }
    $color = 'Green'
    if ($groupFailed -gt 0) { $color = 'Red' }
    elseif ($groupSkipped -gt 0) { $color = 'Yellow' }
    Write-Section ('{0} ({1})' -f $group, ($counts -join ', ')) $color

    foreach ($result in $groupResults) {
        if ($Detailed -or $result.Status -eq 'Fail') {
            if ($result.Status -eq 'Pass') { $statusColor = 'DarkGreen' } else { $statusColor = 'Red' }
            Write-Host ('  {0}  {1} ({2} ms)' -f $result.Status.ToUpperInvariant().PadRight(4), $result.Name, $result.Milliseconds) -ForegroundColor $statusColor
        }
        # Skips carry a long reason; they get their own section below.
        if ($result.Status -eq 'Fail' -and $result.Message) {
            foreach ($line in ($result.Message -split [Environment]::NewLine)) {
                Write-Host ('        ' + $line) -ForegroundColor Red
            }
        }
    }
}

if ($skipped -gt 0) {
    Write-Section 'warnings (skipped, not failures)' 'Yellow'
    foreach ($result in @($results | Where-Object { $_.Status -eq 'Skip' })) {
        Write-Host ('  [{0}] {1}' -f $result.Group, $result.Name) -ForegroundColor Yellow
        foreach ($line in ($result.Message -split [Environment]::NewLine)) {
            Write-Host ('        ' + $line) -ForegroundColor DarkYellow
        }
    }
}

if ($failed -gt 0) {
    Write-Section ('{0} failing test(s)' -f $failed) 'Red'
    foreach ($result in @($results | Where-Object { $_.Status -eq 'Fail' })) {
        Write-Host ('  [{0}] {1}' -f $result.Group, $result.Name) -ForegroundColor Red
    }
}

Write-Section ('{0} passed, {1} failed, {2} skipped in {3:n2}s' -f $passed, $failed, $skipped, $totalClock.Elapsed.TotalSeconds) `
    $(if ($failed -eq 0) { 'Green' } else { 'Red' })

Clear-ArTestTempDirectories

if ($failed -gt 0) { exit 1 }
exit 0
