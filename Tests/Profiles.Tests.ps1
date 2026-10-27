# Tests\Profiles.Tests.ps1
#
# Contract: the target profile store (targets.json) and the last-used pointer
# (last.json) round-trip the documented fields and fail closed on bad data.
#
# All fixtures live in $env:TEMP. The real Resources\Tools\targets.json is never
# read, written or deleted by this suite.
#
# The record validators below are re-implementations of the data contract, not
# imports of src code: the point is to pin the on-disk format independently of
# how Save-ARTargetProfile happens to be written today.

function Test-ArProfileRecord {
    param($Profile)
    $errors = New-Object System.Collections.ArrayList
    if ($null -eq $Profile) { return @('record is null') }
    $required = @('Name', 'Computer', 'User', 'PasswordProtected', 'HashProtected', 'Domain', 'AttackerIP', 'Mode')
    foreach ($field in $required) {
        if ($null -eq $Profile.PSObject.Properties[$field]) { $null = $errors.Add("missing field '$field'") }
    }
    if ($errors.Count -gt 0) { return @($errors.ToArray()) }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.Name)) { $null = $errors.Add("field 'Name' is empty") }
    if ([string]::IsNullOrWhiteSpace([string]$Profile.Computer)) { $null = $errors.Add("field 'Computer' is empty") }
    $mode = [string]$Profile.Mode
    if (@('control', 'view') -notcontains $mode) {
        $null = $errors.Add("field 'Mode' is '$mode', expected 'control' or 'view'")
    }
    foreach ($field in @('User', 'PasswordProtected', 'HashProtected', 'Domain', 'AttackerIP')) {
        if ($Profile.$field -isnot [string]) { $null = $errors.Add("field '$field' is not a string") }
    }
    return @($errors.ToArray())
}

function Test-ArLastProfileRecord {
    param($Last, $Profiles)
    $errors = New-Object System.Collections.ArrayList
    if ($null -eq $Last) { return @('record is null') }
    foreach ($field in @('Name', 'Saved')) {
        if ($null -eq $Last.PSObject.Properties[$field]) { $null = $errors.Add("missing field '$field'") }
    }
    if ($errors.Count -gt 0) { return @($errors.ToArray()) }
    $name = [string]$Last.Name
    if ([string]::IsNullOrWhiteSpace($name)) { $null = $errors.Add("field 'Name' is empty") }
    if ([string]$Last.Saved -notmatch '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$') {
        $null = $errors.Add("field 'Saved' is '$($Last.Saved)', expected 'yyyy-MM-dd HH:mm:ss'")
    }
    $known = @($Profiles | ForEach-Object { [string]$_.Name })
    if ($known -inotcontains $name) {
        $null = $errors.Add("last.json points at '$name', which is not in targets.json")
    }
    return @($errors.ToArray())
}

Describe 'profiles' {

    $tempDir = New-ArTestTempDirectory
    $profilesPath = Join-Path $tempDir 'targets.json'
    $lastPath = Join-Path $tempDir 'last.json'
    $utf8 = New-Object System.Text.UTF8Encoding($false)

    $fixture = @(
        [pscustomobject]@{
            Name              = 'lab-01 - usuario'
            Computer          = 'lab-01'
            User              = 'usuario'
            PasswordProtected = '01000000d08c9ddf0115d1118c7a00c04fc297eb'
            HashProtected     = ''
            Domain            = 'LAB'
            AttackerIP        = '10.0.0.5'
            Mode              = 'control'
        },
        [pscustomobject]@{
            Name              = 'lab-02'
            Computer          = '10.0.0.9'
            User              = ''
            PasswordProtected = ''
            HashProtected     = 'aad3b435b51404eeaad3b435b51404ee'
            Domain            = ''
            AttackerIP        = ''
            Mode              = 'view'
        }
    )
    $lastFixture = [pscustomobject]@{ Name = 'lab-02'; Saved = '2026-10-27 09:41:05' }

    [System.IO.File]::WriteAllText($profilesPath, (ConvertTo-Json -InputObject $fixture -Depth 5), $utf8)
    [System.IO.File]::WriteAllText($lastPath, (ConvertTo-Json -InputObject $lastFixture -Depth 5), $utf8)

    It 'fixture is written outside the repository' {
        Assert-True (-not $profilesPath.StartsWith($script:ArTestRoot, [System.StringComparison]::OrdinalIgnoreCase)) `
            ("the profile fixture must never touch the real store, got " + $profilesPath)
        Assert-FileExists -Path $profilesPath -Message 'targets.json fixture was not written'
        Assert-FileExists -Path $lastPath -Message 'last.json fixture was not written'
    }

    It 'targets.json keeps the documented fields' {
        # ConvertFrom-Json emits an array as a single pipeline object on 5.1, so
        # assign first and wrap after; @(...) around the call would nest it.
        $loaded = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
        $loaded = @($loaded)
        Assert-Equal -Expected 2 -Actual $loaded.Count -Message 'targets.json fixture did not round-trip two profiles'
        $errors = @($loaded | ForEach-Object { Test-ArProfileRecord -Profile $_ } | ForEach-Object { $_ })
        if ($errors.Count -eq 0) { return }
        throw ('profile records break the on-disk contract: ' + ($errors -join '; '))
    }

    It 'Mode accepts only control or view' {
        $bad = [pscustomobject]@{
            Name = 'bad'; Computer = 'lab-03'; User = ''; PasswordProtected = ''
            HashProtected = ''; Domain = ''; AttackerIP = ''; Mode = 'admin'
        }
        $errors = @(Test-ArProfileRecord -Profile $bad)
        Assert-True ($errors.Count -gt 0) 'a profile with Mode=admin passed validation; the control|view contract is not enforced'
        Assert-Match -Text ($errors -join '; ') -Pattern 'Mode' -Message 'validator rejected the record but did not name the Mode field'
    }

    It 'last.json points at an existing profile' {
        $loaded = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
        $loaded = @($loaded)
        $last = Get-Content -LiteralPath $lastPath -Raw | ConvertFrom-Json
        $errors = @(Test-ArLastProfileRecord -Last $last -Profiles $loaded)
        if ($errors.Count -eq 0) { return }
        throw ('last.json breaks the on-disk contract: ' + ($errors -join '; '))
    }

    It 'last.json rejects a dangling profile name' {
        $loaded = Get-Content -LiteralPath $profilesPath -Raw | ConvertFrom-Json
        $loaded = @($loaded)
        $dangling = [pscustomobject]@{ Name = 'deleted-profile'; Saved = '2026-10-27 09:41:05' }
        $errors = @(Test-ArLastProfileRecord -Last $dangling -Profiles $loaded)
        Assert-True ($errors.Count -gt 0) 'last.json pointing at a removed profile passed validation; restore would silently do nothing'
        Assert-Match -Text ($errors -join '; ') -Pattern 'not in targets\.json' -Message 'validator missed the dangling reference'
    }

    It 'protected secrets survive a protect/unprotect round trip' {
        . (Get-ArFunctionSource -Name 'Protect-ARTargetSecret')
        . (Get-ArFunctionSource -Name 'Unprotect-ARTargetSecret')
        $secret = 'Sup3r-S3cret!'
        $protected = Protect-ARTargetSecret -Value $secret
        Assert-True (-not [string]::IsNullOrEmpty($protected)) 'Protect-ARTargetSecret returned an empty string for a non-empty secret'
        Assert-True ($protected -ne $secret) 'Protect-ARTargetSecret stored the secret in clear text; targets.json would leak it'
        Assert-Equal -Expected $secret -Actual (Unprotect-ARTargetSecret -Value $protected) `
            -Message 'Unprotect-ARTargetSecret did not return the original password'
        Assert-Equal -Expected '' -Actual (Unprotect-ARTargetSecret -Value 'not-a-dpapi-blob') `
            -Message 'Unprotect-ARTargetSecret must fail closed and return empty for a corrupt blob'
    }

    It 'profile reader returns the saved records' {
        . (Get-ArFunctionSource -Name 'Get-ARTargetProfilesPath')
        . (Get-ArFunctionSource -Name 'Get-ARTargetProfiles')
        $saved = $script:ARTargetProfilesPath
        try {
            $script:ARTargetProfilesPath = $profilesPath
            $loaded = @(Get-ARTargetProfiles)
            Assert-Equal -Expected 2 -Actual $loaded.Count -Message 'Get-ARTargetProfiles did not return the two saved profiles'
            Assert-SetEqual -Expected @('lab-01 - usuario', 'lab-02') -Actual @($loaded | ForEach-Object { $_.Name }) `
                -Message 'Get-ARTargetProfiles returned the wrong profile names'
        }
        finally { $script:ARTargetProfilesPath = $saved }
    }

    It 'profile reader fails closed on corrupt json' {
        . (Get-ArFunctionSource -Name 'Get-ARTargetProfilesPath')
        . (Get-ArFunctionSource -Name 'Get-ARTargetProfiles')
        $corruptPath = Join-Path $tempDir 'corrupt.json'
        [System.IO.File]::WriteAllText($corruptPath, '{ not json', $utf8)
        $saved = $script:ARTargetProfilesPath
        try {
            $script:ARTargetProfilesPath = $corruptPath
            $loaded = @(Get-ARTargetProfiles)
            Assert-Equal -Expected 0 -Actual $loaded.Count -Message 'Get-ARTargetProfiles threw or returned records for a corrupt file; it must return an empty list'
        }
        finally { $script:ARTargetProfilesPath = $saved }
    }
}
