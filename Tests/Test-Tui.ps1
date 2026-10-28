$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$tuiPath = Join-Path $root 'src\01-core.ps1'
# 01-core carries the header at the top; -noadmin keeps Test-Tui from relaunching
# itself elevated when the harness is run from a normal console.
. $tuiPath -noadmin

Import-ARLanguage -Path (Join-Path $root 'Resources\Languages\English.ps1') -AsFallback
Import-ARLanguage -Path (Join-Path $root 'Resources\Languages\English.ps1')

$script:failures = 0
$script:checks = 0

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $script:checks++
    if ($Condition) {
        Write-Host ('PASS  ' + $Name) -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host ('FAIL  ' + $Name) -ForegroundColor Red
    }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $script:checks++
    if ($Actual -eq $Expected) {
        Write-Host ('PASS  ' + $Name) -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host ('FAIL  {0} (expected {1}, got {2})' -f $Name, $Expected, $Actual) -ForegroundColor Red
    }
}

function Assert-Parses {
    param([Parameter(Mandatory = $true)][string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    $script:checks++
    if ($errors.Count -eq 0) {
        Write-Host ('PASS  parser: ' + (Split-Path -Leaf $Path)) -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host ('FAIL  parser: ' + (Split-Path -Leaf $Path)) -ForegroundColor Red
        foreach ($parseError in $errors) {
            Write-Host ('      line {0}: {1}' -f $parseError.Extent.StartLineNumber, $parseError.Message) -ForegroundColor DarkRed
        }
    }
}

Assert-Parses -Path $tuiPath
Assert-Parses -Path $PSCommandPath

$catalog = @(Get-ARActionCatalog)
$actions = @($catalog | Where-Object { $_.Kind -eq 'Action' })
$groups = @($catalog | Where-Object { $_.Kind -eq 'Group' })

Assert-Equal -Actual $actions.Count -Expected 83 -Name 'catalog has 83 actions'
Assert-Equal -Actual $groups.Count -Expected 8 -Name 'catalog has 8 groups'

$uniqueIds = @($actions | Select-Object -ExpandProperty Id -Unique)
Assert-Equal -Actual $uniqueIds.Count -Expected $actions.Count -Name 'action IDs are unique'

$missingMetadata = @($actions | Where-Object {
    [string]::IsNullOrWhiteSpace($_.Id) -or
    [string]::IsNullOrWhiteSpace($_.Title) -or
    [string]::IsNullOrWhiteSpace($_.Description) -or
    [string]::IsNullOrWhiteSpace($_.Handler)
})
Assert-Equal -Actual $missingMetadata.Count -Expected 0 -Name 'every action has id, title, description and handler'

$badId = @($actions | Where-Object { $_.Id -notmatch '^[1-8]$|^[1-9]\d\d$' })
Assert-Equal -Actual $badId.Count -Expected 0 -Name 'action IDs match the 1-8 / 3-digit scheme'

foreach ($legacyKey in @('11', '12', '13', '14', '15', '16', '17')) {
    $mapped = $script:ARLegacyMap[$legacyKey]
    $script:checks++
    if ($mapped -and (Get-ARActionById $mapped)) {
        Write-Host ('PASS  legacy option {0} maps to {1}' -f $legacyKey, $mapped) -ForegroundColor Green
    }
    else {
        $script:failures++
        Write-Host ('FAIL  legacy option {0} maps to a missing action' -f $legacyKey) -ForegroundColor Red
    }
}

Assert-Equal -Actual (Resolve-ARSelection '11') -Expected 'ACTION:101' -Name 'selection 11 resolves to 101'
Assert-Equal -Actual (Resolve-ARSelection '17') -Expected 'ACTION:701' -Name 'selection 17 resolves to 701'
Assert-Equal -Actual (Resolve-ARSelection '8') -Expected 'ACTION:8' -Name 'selection 8 resolves to quick screen'
Assert-Equal -Actual (Resolve-ARSelection '603') -Expected 'ACTION:603' -Name 'selection 603 resolves to privesc audit'
Assert-Equal -Actual (Resolve-ARSelection 'q') -Expected 'QUIT' -Name 'selection q quits'
Assert-Equal -Actual (Resolve-ARSelection 'l') -Expected 'LANGUAGE' -Name 'selection l opens language picker'
Assert-Equal -Actual (Resolve-ARSelection 't') -Expected 'TARGET' -Name 'selection t opens target editor'
Assert-Equal -Actual (Resolve-ARSelection 'p') -Expected 'PROFILES' -Name 'selection p opens saved targets'
Assert-Equal -Actual (Resolve-ARSelection 's') -Expected 'SAVE' -Name 'selection s saves the current target'
Assert-Equal -Actual (Resolve-ARSelection '999') -Expected '' -Name 'unknown selection is rejected'

$filtered = @(Get-ARFilteredCatalog -Filter 'mimikatz' | Where-Object { $_.Kind -eq 'Action' })
Assert-Equal -Actual $filtered.Count -Expected 2 -Name 'filter finds both Mimikatz actions'
$filteredTitles = ($filtered | Select-Object -ExpandProperty Title) -join ' | '
Assert-True -Condition ($filteredTitles -match 'Mimikatz') -Name 'filtered titles keep matching text'

$wrapped = @(Get-ARWrappedLines -Text ('word ' * 120) -Width 40 -MaxLines 2)
Assert-Equal -Actual $wrapped.Count -Expected 2 -Name 'wrapper honours max lines'
Assert-True -Condition (@($wrapped | Where-Object { $_.Length -gt 40 }).Count -eq 0) -Name 'wrapper never exceeds width'

$formatted = Format-ARText -Text ('x' * 200) -MaxWidth 40
Assert-True -Condition ($formatted.Length -le 40) -Name 'formatter truncates to width'
Assert-True -Condition ($formatted.EndsWith('...')) -Name 'formatter marks truncation'

$profileDirectory = Join-Path $root '_sandbox'
if (-not (Test-Path -LiteralPath $profileDirectory)) {
    New-Item -ItemType Directory -Path $profileDirectory -Force | Out-Null
}
$profilePath = Join-Path $profileDirectory ('targets-test-' + [guid]::NewGuid().ToString('N') + '.json')
$script:ARTargetProfilesPath = $profilePath
$script:ARTarget['Computer'] = '192.0.2.10'
$script:ARTarget['User'] = 'analyst'
$script:ARTarget['Password'] = 'ProfileSecret!'
$script:ARTarget['Hash'] = '0123456789abcdef0123456789abcdef'
$script:ARTarget['Domain'] = 'LAB'
$script:ARTarget['AttackerIP'] = '192.0.2.50'
$script:ARTarget['Mode'] = 'view'
$savedProfileName = Save-ARTargetProfile -Name 'lab-target'
$savedProfiles = @(Get-ARTargetProfiles)
Assert-Equal -Actual $savedProfileName -Expected 'lab-target' -Name 'target profile saves with the requested name'
Assert-Equal -Actual $savedProfiles.Count -Expected 1 -Name 'target profile store returns one entry'
Assert-True -Condition ($savedProfiles[0].PasswordProtected -ne 'ProfileSecret!') -Name 'target profile password is protected on disk'
Assert-True -Condition ($savedProfiles[0].HashProtected -ne $script:ARTarget['Hash']) -Name 'target profile hash is protected on disk'
$script:ARTarget['Computer'] = 'localhost'
$script:ARTarget['User'] = ''
$script:ARTarget['Password'] = ''
$script:ARTarget['Hash'] = ''
$script:ARTarget['Domain'] = ''
$script:ARTarget['AttackerIP'] = ''
$script:ARTarget['Mode'] = 'control'
$null = Apply-ARTargetProfile $savedProfiles[0]
Assert-Equal -Actual $script:ARTarget['Computer'] -Expected '192.0.2.10' -Name 'target profile restores the host'
Assert-Equal -Actual $script:ARTarget['Password'] -Expected 'ProfileSecret!' -Name 'target profile restores the password'
Remove-Item -LiteralPath $profilePath -Force -ErrorAction SilentlyContinue
$script:ARTargetProfilesPath = ''
$script:ARTarget['Computer'] = 'localhost'
$script:ARTarget['User'] = ''
$script:ARTarget['Password'] = ''
$script:ARTarget['Hash'] = ''
$script:ARTarget['Domain'] = ''
$script:ARTarget['AttackerIP'] = ''
$script:ARTarget['Mode'] = 'control'

$script:ARTestMode = $true
$script:ARNoClear = $true
$script:ARTestBuffer.Clear()
$script:ARSelectedId = '1'
$script:ARFilter = ''
$script:ARScroll = 0
$script:ARTarget['Computer'] = 'localhost'
$script:ARTarget['User'] = ''
$script:ARTarget['Mode'] = 'control'
Set-ARSessionState 'not connected'

foreach ($size in @(@(80, 24), @(100, 30), @(140, 40))) {
    $script:ARTestWidth = $size[0]
    $script:ARTestHeight = $size[1]
    $script:ARTestBuffer.Clear()
    Show-ARTuiScreen
    $overWidth = @($script:ARTestBuffer | Where-Object { $_.Length -gt ($size[0] - 1) })
    Assert-Equal -Actual $overWidth.Count -Expected 0 -Name ('no over-width lines at {0}x{1}' -f $size[0], $size[1])
    $joined = $script:ARTestBuffer -join "`n"
    Assert-True -Condition ($joined -match 'Target: localhost') -Name ('target panel rendered at {0}x{1}' -f $size[0], $size[1])
    Assert-True -Condition ($joined -match '\[  1\] PSexec') -Name ('selected action rendered at {0}x{1}' -f $size[0], $size[1])
}

$script:ARTestWidth = 80
$script:ARTestHeight = 24
$script:ARTestBuffer.Clear()
$script:ARSelectedId = '704'
Show-ARTuiScreen
$joined = $script:ARTestBuffer -join "`n"
Assert-True -Condition ($joined -match '\[704\]') -Name 'viewport scrolls to the last action'
Assert-Equal -Actual (@($script:ARTestBuffer | Where-Object { $_.Length -gt 79 }).Count) -Expected 0 -Name 'scrolled frame keeps width'

$script:ARFilter = 'wifi'
$script:ARSelectedId = '204'
$script:ARTestBuffer.Clear()
Show-ARTuiScreen
$joined = $script:ARTestBuffer -join "`n"
Assert-True -Condition ($joined -match '\[204\]') -Name 'filtered frame shows the matching action'
Assert-True -Condition ($joined -notmatch '\[101\]') -Name 'filtered frame hides other actions'
$script:ARFilter = ''

$script:ARTestBuffer.Clear()
$lineMenuResult = Show-ARLineMenu
Assert-Equal -Actual $lineMenuResult -Expected '' -Name 'line menu does not read input in test mode'
$joined = $script:ARTestBuffer -join "`n"
Assert-True -Condition ($joined -match '\[101\]') -Name 'line menu lists remote access actions'
Assert-True -Condition ($joined -match '\[704\]') -Name 'line menu lists the last action'

$script:ARSelectedId = ''
$script:ARTestBuffer.Clear()
$defaultTuiResult = Show-ARTui
Assert-Equal -Actual $defaultTuiResult -Expected 'TEST' -Name 'TUI opens without an initial action id'

$script:ARTestMode = $false
$script:ARTestWidth = 0
$script:ARTestHeight = 0

Write-Host ''
Write-Host ('{0} checks, {1} failure(s)' -f $script:checks, $script:failures) -ForegroundColor $(if ($script:failures -eq 0) { 'Green' } else { 'Red' })
if ($script:failures -gt 0) { exit 1 }
exit 0
