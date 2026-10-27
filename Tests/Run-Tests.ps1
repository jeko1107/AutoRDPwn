$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0
$checks = 0

function Check-True {
    param([bool]$Condition, [string]$Name)
    $script:checks++
    if ($Condition) { Write-Host ('PASS  ' + $Name) -ForegroundColor Green }
    else { $script:failures++; Write-Host ('FAIL  ' + $Name) -ForegroundColor Red }
}

function Check-Equal {
    param($Actual, $Expected, [string]$Name)
    Check-True -Condition ($Actual -eq $Expected) -Name $Name
}

function Test-Parser {
    param([string]$Path)
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors) | Out-Null
    return @($errors)
}

Write-Host 'TUI checks' -ForegroundColor Cyan
$tuiOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Tests\Test-Tui.ps1') 2>&1
$tuiOutput | ForEach-Object { Write-Host $_ }
Check-Equal -Actual $LASTEXITCODE -Expected 0 -Name 'TUI test suite exits cleanly'
Check-True -Condition (($tuiOutput -join "`n") -match '44 checks, 0 failure') -Name 'TUI test suite reports 44 passing checks'

Write-Host 'Parser checks' -ForegroundColor Cyan
$sourceParts = @(
    'src\00-header.ps1',
    'src\10-tui.ps1',
    'src\20-runtime.ps1',
    'src\30-attacks.ps1',
    'src\40-modules.ps1',
    'src\50-main.ps1'
)
foreach ($part in $sourceParts) {
    $path = Join-Path $root $part
    Check-True -Condition (Test-Path -LiteralPath $path) -Name ('source exists: ' + $part)
    $errors = Test-Parser -Path $path
    Check-Equal -Actual $errors.Count -Expected 0 -Name ('parser clean: ' + $part)
}
foreach ($language in Get-ChildItem -LiteralPath (Join-Path $root 'Resources\Languages') -Filter '*.ps1') {
    $errors = Test-Parser -Path $language.FullName
    Check-Equal -Actual $errors.Count -Expected 0 -Name ('parser clean: ' + $language.Name)
}
$stealthScreenPath = Join-Path $root 'Resources\Scripts\Invoke-StealthScreen.ps1'
$errors = Test-Parser -Path $stealthScreenPath
Check-Equal -Actual $errors.Count -Expected 0 -Name 'parser clean: Invoke-StealthScreen.ps1'

Write-Host 'Build checks' -ForegroundColor Cyan
$buildOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'Build.ps1') 2>&1
$buildOutput | ForEach-Object { Write-Host $_ }
Check-Equal -Actual $LASTEXITCODE -Expected 0 -Name 'build exits cleanly'
$generated = Join-Path $root 'AutoRDPwn.ps1'
Check-True -Condition (Test-Path -LiteralPath $generated) -Name 'generated file exists'
$errors = Test-Parser -Path $generated
Check-Equal -Actual $errors.Count -Expected 0 -Name 'generated file parses cleanly'
$generatedText = Get-Content -LiteralPath $generated -Raw
Check-True -Condition ($generatedText.Length -gt 100000) -Name 'generated file keeps the full payload'
Check-True -Condition ($generatedText -notmatch 'Write-ARText') -Name 'no stale Write-ARText references'
Check-True -Condition ($generatedText -notmatch 'ExclusionProcess') -Name 'Defender process exclusions are not used'
Check-True -Condition ($generatedText -match '\$script:ARHashUserName') -Name 'Pass-the-Hash tracks its temporary account'
Check-True -Condition ($generatedText -notmatch 'ARHashUserCreated') -Name 'Pass-the-Hash does not use the old account flag'
Check-True -Condition ($generatedText -match '\$remoteMsi\s*=\s*Copy-ARFileToTarget') -Name 'RDPWrap uses the copied MSI path'
Check-True -Condition ($generatedText -match 'AutoRDPwnVnc_') -Name 'VNC server stages its payload on the target'
Check-True -Condition ($generatedText -match '\$script:ARRemoteTempDirs\.Add') -Name 'remote temporary directories are tracked'
Check-True -Condition ($generatedText -match 'AutoRDPwn_') -Name 'remote background jobs are tagged for cleanup'
$stealthText = Get-Content -LiteralPath $stealthScreenPath -Raw
Check-True -Condition ($stealthText -notmatch 'ExclusionProcess') -Name 'Stealth Screen does not add a process exclusion'

Write-Host 'Catalog checks' -ForegroundColor Cyan
. (Join-Path $root 'src\10-tui.ps1')
Import-ARLanguage -Path (Join-Path $root 'Resources\Languages\English.ps1') -AsFallback
Import-ARLanguage -Path (Join-Path $root 'Resources\Languages\English.ps1')
$catalog = @(Get-ARActionCatalog)
$actions = @($catalog | Where-Object { $_.Kind -eq 'Action' })
$groups = @($catalog | Where-Object { $_.Kind -eq 'Group' })
Check-Equal -Actual $actions.Count -Expected 34 -Name 'catalog exposes 34 actions'
Check-Equal -Actual $groups.Count -Expected 7 -Name 'catalog exposes 7 groups'
$ids = @($actions | ForEach-Object { $_.Id })
Check-Equal -Actual @($ids | Sort-Object -Unique).Count -Expected 34 -Name 'action IDs are unique'
$byId = @{}
foreach ($action in $actions) { $byId[$action.Id] = $action }
Check-Equal -Actual $byId['401'].NeedsTarget -Expected $false -Name 'RDP caching is marked local-only for target'
Check-Equal -Actual $byId['401'].NeedsSession -Expected $false -Name 'RDP caching is marked local-only for session'
Check-True -Condition ($byId['104'].Description -match 'target listens') -Name 'netcat direct description matches target bind'
Check-True -Condition ($byId['105'].Description -match 'target connects back') -Name 'netcat reverse description matches target callback'
$handlerNames = @($actions | ForEach-Object { $_.Handler } | Sort-Object -Unique)
$missingHandlers = @()
foreach ($handler in $handlerNames) {
    if ($generatedText -notmatch ('(?m)^\s*function\s+' + [regex]::Escape($handler) + '\b')) { $missingHandlers += $handler }
}
Check-Equal -Actual $missingHandlers.Count -Expected 0 -Name 'every catalog handler is defined'
Check-True -Condition ($generatedText -match '(?m)^\s*function\s+Start-ARApplication\b') -Name 'main entry point is present'
Check-True -Condition ($generatedText -match '(?m)^\s*function\s+Invoke-ARShadowEngine\b') -Name 'shadow engine is present'

Write-Host 'Language checks' -ForegroundColor Cyan
$languageFiles = @(Get-ChildItem -LiteralPath (Join-Path $root 'Resources\Languages') -Filter '*.ps1')
$languageSets = @{}
foreach ($language in $languageFiles) {
    $keys = @(Select-String -Path $language.FullName -Pattern '^\s*\$txt(\d+)\s*=' | ForEach-Object { 'txt' + $_.Matches[0].Groups[1].Value })
    $languageSets[$language.Name] = $keys
    Check-Equal -Actual $keys.Count -Expected 130 -Name ('language has 130 text keys: ' + $language.Name)
    Check-True -Condition ($keys -contains 'txt125') -Name ('language has txt125: ' + $language.Name)
    Check-True -Condition ($keys -contains 'txt126') -Name ('language has txt126: ' + $language.Name)
    Check-True -Condition ($keys -contains 'txt130') -Name ('language has txt130: ' + $language.Name)
}
$englishKeys = $languageSets['English.ps1']
foreach ($languageName in $languageSets.Keys) {
    $difference = @(Compare-Object $englishKeys $languageSets[$languageName])
    Check-Equal -Actual $difference.Count -Expected 0 -Name ('language keys match English: ' + $languageName)
}
$tuiText = Get-Content -LiteralPath (Join-Path $root 'src\10-tui.ps1') -Raw
$runtimeText = Get-Content -LiteralPath (Join-Path $root 'src\20-runtime.ps1') -Raw
$attackText = Get-Content -LiteralPath (Join-Path $root 'src\30-attacks.ps1') -Raw
$moduleText = Get-Content -LiteralPath (Join-Path $root 'src\40-modules.ps1') -Raw
$references = @([regex]::Matches(($tuiText + $runtimeText + $attackText + $moduleText), "Get-ARText\s+'?(txt\d+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$missingKeys = @($references | Where-Object { $englishKeys -notcontains $_ })
Check-Equal -Actual $missingKeys.Count -Expected 0 -Name 'every referenced text key exists in English'

Write-Host ''
Write-Host ('{0} checks, {1} failure(s)' -f $checks, $failures) -ForegroundColor $(if ($failures -eq 0) { 'Green' } else { 'Red' })
if ($failures -gt 0) { exit 1 }
exit 0
