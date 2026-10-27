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

function Start-ARApplication {
    if (Get-Command Get-ARLastLanguage -ErrorAction SilentlyContinue) {
        try { $savedLanguage = Get-ARLastLanguage } catch { $savedLanguage = '' }
        if ($savedLanguage -and -not $script:ARLanguageArgument) { $script:ARLanguageArgument = $savedLanguage }
    }
    Initialize-ARLanguage $script:ARLanguageArgument
    $null = Restore-ARLastProfile
    if ($script:ARShadowPreference -in @('see', 'view', 'ver', 'regarder', 'siehe', 'vedere')) {
        $script:ARTarget['Mode'] = 'view'
    }
    elseif ($script:ARShadowPreference -in @('control', 'controlar', 'controle', 'kontrolle', 'controllo')) {
        $script:ARTarget['Mode'] = 'control'
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
    Start-ARApplication
}
catch {
    Write-ARError $_.Exception.Message
    exit 1
}
finally {
    Invoke-ARCleanup
}
