function Show-ARLineLanguagePicker {
    $languages = @('English', 'Spanish', 'French', 'German', 'Italian', 'Russian', 'Portuguese')
    Write-Host ''
    for ($index = 0; $index -lt $languages.Count; $index++) {
        Write-Host (' {0}. {1}' -f ($index + 1), $languages[$index]) -ForegroundColor Gray
    }
    $defaultIndex = [Array]::IndexOf($languages, $script:ARLocaleName)
    if ($defaultIndex -lt 0) { $defaultIndex = 0 }
    $choice = Read-ARValue 'Language (1-7)' ([string]($defaultIndex + 1))
    $name = Resolve-ARLanguageName $choice
    Initialize-ARLanguage $name
    Set-ARStatus ('Language: ' + $name) 'Ok'
}

function Get-ARCatalogRows {
    $rows = New-Object System.Collections.Generic.List[object]
    if (-not (Get-Command Get-ARActionCatalog -ErrorAction SilentlyContinue)) {
        return $rows.ToArray()
    }
    $group = Get-ARText 'txt137' 'Quick actions'
    foreach ($item in @(Get-ARActionCatalog)) {
        if ($null -eq $item) { continue }
        $kind = ''
        if ($item.PSObject.Properties['Kind']) { $kind = [string]$item.Kind }
        if ($kind -eq 'Group') {
            if ($item.PSObject.Properties['Title']) { $group = [string]$item.Title }
            continue
        }
        $description = ''
        if ($item.PSObject.Properties['Description']) { $description = [string]$item.Description }
        $needsSession = $false
        if ($item.PSObject.Properties['NeedsSession']) { $needsSession = [bool]$item.NeedsSession }
        $rows.Add([pscustomobject]@{
            Id           = [string]$item.Id
            Title        = [string]$item.Title
            Description  = $description
            Handler      = [string]$item.Handler
            NeedsSession = $needsSession
            Group        = $group
        })
    }
    return $rows.ToArray()
}

function Start-ARApplication {
    param(
        [switch]$List,
        [switch]$ListJson
    )

    if ($script:ARConfigPath -ne '') {
        if (-not (Test-Path -LiteralPath $script:ARConfigPath)) {
            Write-ARError ('Config file not found: ' + $script:ARConfigPath)
            exit 1
        }
        try {
            $raw = Get-Content -LiteralPath $script:ARConfigPath -Raw -ErrorAction Stop
            $config = $raw | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-ARError 'Malformed JSON in config file.'
            exit 1
        }
        if ($config) {
            if (-not $PSBoundParameters.ContainsKey('Target') -and $config.PSObject.Properties['Target']) { $script:ARCliTarget = [string]$config.Target }
            if (-not $PSBoundParameters.ContainsKey('User') -and $config.PSObject.Properties['User']) { $script:ARCliUser = [string]$config.User }
            if (-not $PSBoundParameters.ContainsKey('Password') -and $config.PSObject.Properties['Password']) { $script:ARCliPassword = [string]$config.Password }
            if (-not $PSBoundParameters.ContainsKey('Mode') -and $config.PSObject.Properties['Mode']) { $script:ARCliMode = [string]$config.Mode }
            if (-not $PSBoundParameters.ContainsKey('lang') -and $config.PSObject.Properties['Language']) { $script:ARLanguageArgument = [string]$config.Language }
            elseif (-not $PSBoundParameters.ContainsKey('lang') -and $config.PSObject.Properties['language']) { $script:ARLanguageArgument = [string]$config.language }
        }
    }

    if (Get-Command Get-ARLastLanguage -ErrorAction SilentlyContinue) {
        try { $savedLanguage = Get-ARLastLanguage } catch { $savedLanguage = '' }
        if ($savedLanguage -and -not $script:ARLanguageArgument) { $script:ARLanguageArgument = $savedLanguage }
    }
    Initialize-ARLanguage $script:ARLanguageArgument

    # Pure output mode: nothing but the JSON document may reach stdout, and the
    # catalog needs no profile, defender or target state, so it runs before any
    # UI setup and skips the cleanup banner in the finally block.
    if ($ListJson) {
        if (-not (Get-Command Get-ARActionCatalog -ErrorAction SilentlyContinue)) {
            Write-ARError 'Action catalog not available.'
            exit 1
        }
        $catalogRows = @(Get-ARCatalogRows)
        $script:ARCleanupDone = $true
        ConvertTo-Json -InputObject $catalogRows -Depth 4
        exit 0
    }

    $null = Restore-ARLastProfile

    if ($script:ARCliTarget -ne '') { $script:ARTarget['Computer'] = $script:ARCliTarget }
    if ($script:ARCliUser -ne '') { $script:ARTarget['User'] = $script:ARCliUser }
    if ($null -ne $script:ARCliPassword) {
        $script:ARTarget['Password'] = [string]$script:ARCliPassword
    }
    if ($script:ARCliMode -ne '') {
        $m = ([string]$script:ARCliMode).Trim().ToLowerInvariant()
        if ($m -eq 'view') { $script:ARTarget['Mode'] = 'view' }
        elseif ($m -eq 'control') { $script:ARTarget['Mode'] = 'control' }
    }
    if ($script:ARShadowPreference -in @('see', 'view', 'ver', 'regarder', 'siehe', 'vedere')) {
        $script:ARTarget['Mode'] = 'view'
    }
    elseif ($script:ARShadowPreference -in @('control', 'controlar', 'controle', 'kontrolle', 'controllo')) {
        $script:ARTarget['Mode'] = 'control'
    }
    if ($PSBoundParameters.ContainsKey('Yes')) { $script:ARAssumeYes = $true }

    if ($List) {
        if (Get-Command Get-ARActionCatalog -ErrorAction SilentlyContinue) {
            Get-ARCatalogRows | Format-Table Id, Title, Handler, NeedsSession, Group -AutoSize
            exit 0
        }
        Write-ARError 'Action catalog not available.'
        exit 1
    }

    Initialize-ARDefender
    Set-ARStatus 'Ready' 'Info'

    if ($script:ARInvokedFromOption) {
        $selection = Resolve-ARSelection $script:AROptionValue
        if ($selection -like 'ACTION:*') {
            $script:ARLastFailure = ''
            Invoke-ARAction $selection.Substring(7)
            if ($script:ARLastFailure) { exit 1 }
            return
        }
        Write-ARError ('Unknown option: ' + $script:AROptionValue)
        exit 1
    }

    while ($true) {
        if ($script:ARNoGui -or [Console]::IsInputRedirected) {
            $selection = Show-ARLineMenu
            if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq 'QUIT') { break }
            if ($selection -eq 'TARGET') { Show-ARLineTargetForm; continue }
            if ($selection -eq 'PROFILES') { $null = Show-ARLineTargetPicker; continue }
            if ($selection -eq 'SAVE') { $null = Save-ARCurrentTarget; continue }
            if ($selection -eq 'LANGUAGE') { Show-ARLineLanguagePicker; continue }
            if ($selection -like 'ACTION:*') { Invoke-ARAction $selection.Substring(7); continue }
            Set-ARStatus (Get-ARText 'txt6' 'Incorrect option, try again') 'Warn'
            continue
        }
        $selection = Show-ARTui
        if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq 'QUIT') { break }
        if ($selection -eq 'TARGET') { continue }
        if ($selection -eq 'LANGUAGE') {
            $language = Show-ARLanguagePicker
            if ($language -ne '') { Initialize-ARLanguage $language }
            continue
        }
        if ($selection -like 'ACTION:*') { Invoke-ARAction $selection.Substring(7); continue }
    }
}

try {
    Start-ARApplication -List:$List -ListJson:$ListJson
}
catch {
    Write-ARError $_.Exception.Message
    exit 1
}
finally {
    Invoke-ARCleanup
}