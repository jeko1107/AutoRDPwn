$script:ARLocaleName = 'English'
$script:ARStrings = @{}
$script:ARFallbackStrings = @{}
$script:ARTarget = @{
    Computer   = 'localhost'
    User       = ''
    Password   = ''
    Hash       = ''
    Domain     = ''
    AttackerIP = ''
    Mode       = 'control'
}
$script:ARStatus = @{ Text = 'Ready'; Kind = 'Info' }
$script:ARScroll = 0
$script:ARSelectedId = ''
$script:ARFilter = ''
$script:ARSessionState = 'not connected'
$script:ARTestMode = $false
$script:ARNoClear = $false
$script:ARTestWidth = 0
$script:ARTestHeight = 0
$script:ARTestBuffer = New-Object System.Collections.Generic.List[string]
$script:ARLegacyMap = @{
    '11' = '101'
    '12' = '201'
    '13' = '301'
    '14' = '401'
    '15' = '501'
    '16' = '601'
    '17' = '701'
}

function Import-ARLanguage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AsFallback
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Language file not found: $Path"
    }
    $captured = & {
        . $Path
        Get-Variable -Name 'txt*', 'Pwn*' -ErrorAction SilentlyContinue
    }
    $strings = @{}
    foreach ($item in $captured) {
        if ($null -ne $item -and $item.Name) {
            $strings[$item.Name] = [string]$item.Value
        }
    }
    if ($AsFallback) {
        $script:ARFallbackStrings = $strings
    }
    else {
        $script:ARStrings = $strings
    }
}

function Get-ARText {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Default = ''
    )
    if ($script:ARStrings.ContainsKey($Key)) {
        return $script:ARStrings[$Key]
    }
    if ($script:ARFallbackStrings.ContainsKey($Key)) {
        return $script:ARFallbackStrings[$Key]
    }
    return $Default
}

function Set-ARLanguageName {
    param([Parameter(Mandatory = $true)][string]$Name)
    $script:ARLocaleName = $Name
}

function Set-ARStatus {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [ValidateSet('Info', 'Ok', 'Warn', 'Error')][string]$Kind = 'Info'
    )
    $script:ARStatus = @{ Text = $Text; Kind = $Kind }
}

function Set-ARSessionState {
    param([string]$State)
    if ($null -eq $State -or $State -eq '') {
        $script:ARSessionState = 'not connected'
    }
    else {
        $script:ARSessionState = $State
    }
}

function Format-ARText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxWidth
    )
    if ($MaxWidth -lt 1) { return '' }
    if ($null -eq $Text) { return '' }
    $flat = ($Text -replace '[\r\n\t]+', ' ').Trim()
    if ($flat.Length -le $MaxWidth) { return $flat }
    if ($MaxWidth -le 3) { return $flat.Substring(0, $MaxWidth) }
    return $flat.Substring(0, $MaxWidth - 3) + '...'
}

function Get-ARWrappedLines {
    param(
        [AllowNull()][string]$Text,
        [int]$Width,
        [int]$MaxLines
    )
    $result = New-Object System.Collections.Generic.List[string]
    if ($Width -lt 4 -or $MaxLines -lt 1) { return @() }
    if ($null -eq $Text) { return @() }
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat -eq '') { return @() }
    $words = $flat -split ' '
    $line = ''
    $truncated = $false
    foreach ($word in $words) {
        if ($word.Length -gt $Width) {
            if ($line -ne '') {
                $result.Add($line)
                $line = ''
                if ($result.Count -ge $MaxLines) { $truncated = $true; break }
            }
            $result.Add($word.Substring(0, $Width))
            if ($result.Count -ge $MaxLines) { $truncated = $true; break }
            continue
        }
        if ($line -eq '') {
            $candidate = $word
        }
        else {
            $candidate = $line + ' ' + $word
        }
        if ($candidate.Length -le $Width) {
            $line = $candidate
        }
        else {
            $result.Add($line)
            if ($result.Count -ge $MaxLines) { $truncated = $true; break }
            $line = $word
        }
    }
    if ($result.Count -lt $MaxLines -and $line -ne '') {
        $result.Add($line)
    }
    elseif ($line -ne '') {
        $truncated = $true
    }
    if ($truncated -and $result.Count -gt 0) {
        $last = $result[$result.Count - 1]
        if ($last.Length -gt ($Width - 3)) {
            $last = $last.Substring(0, $Width - 3)
        }
        $result[$result.Count - 1] = $last + '...'
    }
    return $result.ToArray()
}

function Get-ARConsoleWidth {
    if ($script:ARTestMode -and $script:ARTestWidth -gt 0) { return $script:ARTestWidth }
    $width = 100
    try {
        if ([Console]::WindowWidth -gt 0) { $width = [Console]::WindowWidth }
    }
    catch { }
    if ($width -lt 60) { $width = 60 }
    return $width
}

function Get-ARConsoleHeight {
    if ($script:ARTestMode -and $script:ARTestHeight -gt 0) { return $script:ARTestHeight }
    $height = 30
    try {
        if ([Console]::WindowHeight -gt 0) { $height = [Console]::WindowHeight }
    }
    catch { }
    if ($height -lt 20) { $height = 20 }
    return $height
}

function Clear-ARScreen {
    if ($script:ARTestMode) { return }
    if ($script:ARNoClear) { return }
    Clear-Host
}

function Write-ARLine {
    param(
        [AllowEmptyString()][string]$Text = '',
        [string]$Color = 'Gray',
        [string]$Background = ''
    )
    if ($script:ARTestMode) {
        $script:ARTestBuffer.Add($Text)
        return
    }
    if ($Background -ne '') {
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $Background
    }
    else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Test-ARIsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function New-ARAction {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][string]$Handler,
        [bool]$NeedsTarget = $true,
        [bool]$NeedsSession = $true
    )
    return [pscustomobject]@{
        Kind         = 'Action'
        Id           = $Id
        Title        = $Title
        Description  = $Description
        Handler      = $Handler
        NeedsTarget  = $NeedsTarget
        NeedsSession = $NeedsSession
    }
}

function New-ARGroup {
    param([Parameter(Mandatory = $true)][string]$Title)
    return [pscustomobject]@{
        Kind  = 'Group'
        Title = $Title
    }
}

function Get-ARActionCatalog {
    $items = New-Object System.Collections.Generic.List[object]

    $items.Add((New-ARAction -Id '1' -Title 'PSexec (SMB)' -Description 'Copy and start the payload with PSexec over SMB, then open the shadow session.' -Handler 'Invoke-ARAttackPSexec' -NeedsSession $false))
    $items.Add((New-ARAction -Id '2' -Title 'Pass the Hash (SMB)' -Description 'Authenticate with an NTLM hash through SMBExec and start the payload.' -Handler 'Invoke-ARAttackPassTheHash' -NeedsSession $false))
    $items.Add((New-ARAction -Id '3' -Title 'Windows Management Instrumentation (WMI)' -Description 'Create the remote process through CIM/WMI with optional credentials.' -Handler 'Invoke-ARAttackWmi' -NeedsSession $false))
    $items.Add((New-ARAction -Id '4' -Title 'Windows Remote Management (WinRM)' -Description 'Run the payload through a WinRM session with optional credentials.' -Handler 'Invoke-ARAttackWinRm' -NeedsSession $false))
    $items.Add((New-ARAction -Id '5' -Title 'Windows Remote Assistance (WinRS)' -Description 'Run the payload with WinRS and then open the shadow session.' -Handler 'Invoke-ARAttackWinRs' -NeedsSession $false))
    $items.Add((New-ARAction -Id '6' -Title 'Local Session Hijacking (TSCon)' -Description 'Attach the current console to another local session with tscon.' -Handler 'Invoke-ARAttackTscon' -NeedsTarget $false -NeedsSession $false))
    $items.Add((New-ARAction -Id '7' -Title 'Remote Desktop Execution (RDP)' -Description 'Start the payload through SharpRDP and then open the shadow session.' -Handler 'Invoke-ARAttackRdp' -NeedsSession $false))
    $items.Add((New-ARAction -Id '8' -Title (Get-ARText 'txt121' 'Quick Screen (Stealth VNC)') -Description (Get-ARText 'txt122' 'Watch or control the target screen without the user noticing') -Handler 'Invoke-ARAttackQuickScreen'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt17' 'Remote Access')))
    $items.Add((New-ARAction -Id '101' -Title 'Named Pipe Remote Shell (SMB)' -Description (Get-ARText 'txt95' 'Remote shell through a named pipe over SMB port 445') -Handler 'Invoke-ARModulePipeShell'))
    $items.Add((New-ARAction -Id '102' -Title (Get-ARText 'txt39' 'Semi-interactive console (WinRS)') -Description (Get-ARText 'txt96' 'Remote console over WinRM port 5985 using direct PowerShell') -Handler 'Invoke-ARModuleWinRsConsole'))
    $items.Add((New-ARAction -Id '103' -Title 'PowerShell HTTP-RevShell (HTTP/S)' -Description (Get-ARText 'txt97' 'Reverse shell that dials back over HTTP/S, crosses proxies') -Handler 'Invoke-ARModuleHttpRevShell'))
    $items.Add((New-ARAction -Id '104' -Title (Get-ARText 'txt51' 'Netcat console (direct connection)') -Description (Get-ARText 'txt99' 'The target listens and you connect to it') -Handler 'Invoke-ARModuleNetcatDirect'))
    $items.Add((New-ARAction -Id '105' -Title (Get-ARText 'txt52' 'Netcat console (reverse connection)') -Description (Get-ARText 'txt98' 'You listen and the target connects back to you') -Handler 'Invoke-ARModuleNetcatReverse'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt50' 'Passwords and hashes')))
    $items.Add((New-ARAction -Id '201' -Title (Get-ARText 'txt9' 'Extract local hashes with Mimikatz') -Description (Get-ARText 'txt100' 'Dump local account password hashes from the SAM registry hive') -Handler 'Invoke-ARModuleMimikatzSam'))
    $items.Add((New-ARAction -Id '202' -Title (Get-ARText 'txt10' 'Extract system passwords with Mimikatz') -Description (Get-ARText 'txt101' 'Extract plaintext passwords from the memory of authenticated processes') -Handler 'Invoke-ARModuleMimikatzLogon'))
    $items.Add((New-ARAction -Id '203' -Title (Get-ARText 'txt49' 'Obtain browsers passwords with SharpWeb') -Description (Get-ARText 'txt102' 'Recover passwords saved in Chrome, Firefox and other browsers') -Handler 'Invoke-ARModuleSharpWeb'))
    $items.Add((New-ARAction -Id '204' -Title (Get-ARText 'txt59' 'Recover Wi-Fi passwords') -Description (Get-ARText 'txt103' 'Show the keys of saved WiFi networks in clear text') -Handler 'Invoke-ARModuleWifiKeys'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt125' 'Networking / Pivoting')))
    $items.Add((New-ARAction -Id '301' -Title 'TCP Port Scan' -Description (Get-ARText 'txt104' 'Multi-threaded TCP port scan of the target') -Handler 'Invoke-ARModulePortScan' -NeedsSession $false))
    $items.Add((New-ARAction -Id '302' -Title 'Native Port Forwarding' -Description (Get-ARText 'txt105' 'Forward ports with netsh, inbound locally or remote pivoting') -Handler 'Invoke-ARModulePortForward'))
    $items.Add((New-ARAction -Id '303' -Title 'PowerShell Web Server' -Description (Get-ARText 'txt106' 'Serve files from the target with a PowerShell web server') -Handler 'Invoke-ARModuleWebServer'))
    $items.Add((New-ARAction -Id '304' -Title 'Network Creds Scanner' -Description (Get-ARText 'txt107' 'Test a password or NTLM hash against a CIDR range via SMB/WMI') -Handler 'Invoke-ARModuleCredScan' -NeedsSession $false))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt126' 'Remote Desktop Forensics')))
    $items.Add((New-ARAction -Id '401' -Title (Get-ARText 'txt11' 'Rebuild the image cache') -Description (Get-ARText 'txt129' 'Recover the RDP session history cached on this computer') -Handler 'Invoke-ARModuleRdpCaching' -NeedsTarget $false -NeedsSession $false))
    $items.Add((New-ARAction -Id '402' -Title (Get-ARText 'txt127' 'List local users and groups') -Description (Get-ARText 'txt109' 'List every user with SID, groups and last logon details') -Handler 'Invoke-ARModuleListUsers'))
    $items.Add((New-ARAction -Id '403' -Title (Get-ARText 'txt128' 'Extract session credentials (SessionGopher)') -Description (Get-ARText 'txt110' 'Extract credentials stored by PuTTY, SuperPuTTY, FileZilla and WinSCP') -Handler 'Invoke-ARModuleSessionGopher'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt64' 'Backdoors and persistence')))
    $items.Add((New-ARAction -Id '501' -Title 'Sticky Keys Hacking' -Description (Get-ARText 'txt111' 'Replace sethc.exe so a SYSTEM console opens from the login screen') -Handler 'Invoke-ARModuleStickyKeys'))
    $items.Add((New-ARAction -Id '502' -Title 'Metasploit Reverse Shell' -Description (Get-ARText 'txt112' 'Deploy a persistent Metasploit reverse shell on the target') -Handler 'Invoke-ARModuleMetasploit'))
    $items.Add((New-ARAction -Id '503' -Title 'Remote Keylogger' -Description (Get-ARText 'txt113' 'Log every keystroke typed on the target console') -Handler 'Invoke-ARModuleKeylogger'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt68' 'Privilege escalation')))
    $items.Add((New-ARAction -Id '601' -Title (Get-ARText 'txt70' 'Get operating system information') -Description (Get-ARText 'txt114' 'Full enumeration of privesc surface and local misconfigurations') -Handler 'Invoke-ARModuleChachi'))
    $items.Add((New-ARAction -Id '602' -Title (Get-ARText 'txt71' 'Search vulnerabilities with Sherlock') -Description (Get-ARText 'txt115' 'Scan the system for known kernel and service vulnerabilities') -Handler 'Invoke-ARModuleSherlock'))
    $items.Add((New-ARAction -Id '603' -Title (Get-ARText 'txt130' 'Privilege escalation audit') -Description (Get-ARText 'txt116' 'Audit services, tasks, permissions and patches for escalation paths') -Handler 'Invoke-ARModulePrivescCheck'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt69' 'Other modules')))
    $items.Add((New-ARAction -Id '701' -Title (Get-ARText 'txt18' 'Deactivate system logs') -Description (Get-ARText 'txt117' 'Wipe event logs without stopping the EventLog service') -Handler 'Invoke-ARModulePhant0m'))
    $items.Add((New-ARAction -Id '702' -Title (Get-ARText 'txt62' 'Remote VNC Server (legacy)') -Description (Get-ARText 'txt118' 'Open an invisible VNC to watch and control the target screen') -Handler 'Invoke-ARModuleVncServer'))
    $items.Add((New-ARAction -Id '703' -Title (Get-ARText 'txt67' 'External script execution') -Description (Get-ARText 'txt119' 'Run any external PowerShell script or function on the target') -Handler 'Invoke-ARModuleExternalScript'))
    $items.Add((New-ARAction -Id '704' -Title (Get-ARText 'txt79' 'Change user with RunAs') -Description (Get-ARText 'txt120' 'Validate credentials and launch processes as another user') -Handler 'Invoke-ARModuleRunAs' -NeedsTarget $false -NeedsSession $false))

    return $items.ToArray()
}

function Get-ARActionById {
    param([Parameter(Mandatory = $true)][string]$Id)
    foreach ($item in Get-ARActionCatalog) {
        if ($item.Kind -eq 'Action' -and $item.Id -eq $Id) {
            return $item
        }
    }
    return $null
}

function Get-ARFilteredCatalog {
    param([string]$Filter = '')
    $catalog = @(Get-ARActionCatalog)
    if ($null -eq $Filter -or $Filter.Trim() -eq '') {
        return $catalog
    }
    $needle = $Filter.Trim().ToLowerInvariant()
    $result = New-Object System.Collections.Generic.List[object]
    $pendingGroup = $null
    $groupAdded = $false
    foreach ($item in $catalog) {
        if ($item.Kind -eq 'Group') {
            $pendingGroup = $item
            $groupAdded = $false
            continue
        }
        $haystack = ($item.Id + ' ' + $item.Title + ' ' + $item.Description).ToLowerInvariant()
        if ($haystack.Contains($needle)) {
            if ($pendingGroup -and -not $groupAdded) {
                $result.Add($pendingGroup)
                $groupAdded = $true
            }
            $result.Add($item)
        }
    }
    return $result.ToArray()
}

function Resolve-ARSelection {
    param([string]$Selection)
    $value = ''
    if ($null -ne $Selection) { $value = $Selection.Trim() }
    if ($value -eq '') { return '' }
    $upper = $value.ToUpperInvariant()
    if ($upper -in @('Q', 'QUIT', 'X', 'EXIT')) { return 'QUIT' }
    if ($upper -in @('L', 'LANG', 'LANGUAGE')) { return 'LANGUAGE' }
    if ($upper -in @('T', 'TARGET')) { return 'TARGET' }
    if ($value -match '^1[1-7]$') {
        $mapped = $script:ARLegacyMap[$value]
        if ($mapped) { return 'ACTION:' + $mapped }
        return ''
    }
    $action = Get-ARActionById $value
    if ($action) { return 'ACTION:' + $action.Id }
    return ''
}

function Move-ARSelection {
    param([int]$Delta)
    $rows = @(Get-ARFilteredCatalog -Filter $script:ARFilter | Where-Object { $_.Kind -eq 'Action' })
    if ($rows.Count -eq 0) { return }
    $ids = @($rows | ForEach-Object { $_.Id })
    $index = [Array]::IndexOf($ids, $script:ARSelectedId)
    if ($index -lt 0) { $index = 0 }
    else { $index = $index + $Delta }
    if ($index -lt 0) { $index = $ids.Count - 1 }
    if ($index -ge $ids.Count) { $index = 0 }
    $script:ARSelectedId = $ids[$index]
}

function Move-ARSelectionPage {
    param([int]$Pages)
    $rows = @(Get-ARFilteredCatalog -Filter $script:ARFilter | Where-Object { $_.Kind -eq 'Action' })
    if ($rows.Count -eq 0) { return }
    $ids = @($rows | ForEach-Object { $_.Id })
    $index = [Array]::IndexOf($ids, $script:ARSelectedId)
    if ($index -lt 0) { $index = 0 }
    $step = [Math]::Max(5, (Get-ARConsoleHeight) - 15)
    $index = $index + ($Pages * $step)
    if ($index -lt 0) { $index = 0 }
    if ($index -ge $ids.Count) { $index = $ids.Count - 1 }
    $script:ARSelectedId = $ids[$index]
}

function Get-ARTargetUserLabel {
    if ($script:ARTarget['User']) { return $script:ARTarget['User'] }
    return [Environment]::UserName
}

function Get-ARTargetAttackerLabel {
    if ($script:ARTarget['AttackerIP']) { return $script:ARTarget['AttackerIP'] }
    return 'auto'
}

function Show-ARTuiScreen {
    param(
        [string]$Prompt = ''
    )
    $width = Get-ARConsoleWidth
    $height = Get-ARConsoleHeight
    $inner = $width - 1
    $listHeight = [Math]::Max(5, $height - 12)
    $catalog = @(Get-ARFilteredCatalog -Filter $script:ARFilter)
    $selectedIndex = -1
    for ($i = 0; $i -lt $catalog.Count; $i++) {
        if ($catalog[$i].Kind -eq 'Action' -and $catalog[$i].Id -eq $script:ARSelectedId) {
            $selectedIndex = $i
            break
        }
    }
    if ($selectedIndex -lt 0) {
        for ($i = 0; $i -lt $catalog.Count; $i++) {
            if ($catalog[$i].Kind -eq 'Action') {
                $script:ARSelectedId = $catalog[$i].Id
                $selectedIndex = $i
                break
            }
        }
    }
    if ($selectedIndex -ge 0) {
        if ($selectedIndex -lt $script:ARScroll) { $script:ARScroll = $selectedIndex }
        if ($selectedIndex -ge ($script:ARScroll + $listHeight)) {
            $script:ARScroll = $selectedIndex - $listHeight + 1
        }
    }
    $maxScroll = [Math]::Max(0, $catalog.Count - $listHeight)
    if ($script:ARScroll -gt $maxScroll) { $script:ARScroll = $maxScroll }
    if ($script:ARScroll -lt 0) { $script:ARScroll = 0 }

    Clear-ARScreen
    $adminLabel = if (Test-ARIsAdmin) { 'yes' } else { 'no' }
    $header = 'AutoRDPwn v5.2  |  Shadow Attack Framework  |  {0}  |  admin: {1}' -f $script:ARLocaleName, $adminLabel
    Write-ARLine (Format-ARText $header $inner) 'Yellow'
    Write-ARLine ('-' * $inner) 'DarkGray'
    $targetLine = 'Target: {0}  |  User: {1}  |  Mode: {2}  |  Session: {3}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode'], $script:ARSessionState
    Write-ARLine (Format-ARText $targetLine $inner) 'Gray'
    Write-ARLine ('-' * $inner) 'DarkGray'

    for ($row = 0; $row -lt $listHeight; $row++) {
        $index = $script:ARScroll + $row
        if ($index -ge $catalog.Count) {
            Write-ARLine ''
            continue
        }
        $item = $catalog[$index]
        if ($item.Kind -eq 'Group') {
            Write-ARLine (Format-ARText ('  -- {0} --' -f $item.Title) $inner) 'Blue'
            continue
        }
        $selected = $item.Id -eq $script:ARSelectedId
        $marker = if ($selected) { '>' } else { ' ' }
        $text = Format-ARText (' {0} [{1,3}] {2}' -f $marker, $item.Id, $item.Title) $inner
        if ($selected) {
            Write-ARLine $text 'Black' 'Gray'
        }
        else {
            Write-ARLine $text 'Gray'
        }
    }

    Write-ARLine ('-' * $inner) 'DarkGray'
    $selectedAction = Get-ARActionById $script:ARSelectedId
    if ($selectedAction) {
        Write-ARLine (Format-ARText (' {0}  [{1}]' -f $selectedAction.Title, $selectedAction.Id) $inner) 'White'
        $descriptionLines = @(Get-ARWrappedLines -Text $selectedAction.Description -Width ($width - 3) -MaxLines 2)
        for ($i = 0; $i -lt 2; $i++) {
            if ($i -lt $descriptionLines.Count) {
                Write-ARLine (' ' + $descriptionLines[$i]) 'Gray'
            }
            else {
                Write-ARLine ''
            }
        }
    }
    else {
        Write-ARLine ' No action selected' 'DarkGray'
        Write-ARLine ''
        Write-ARLine ''
    }

    $statusColor = switch ($script:ARStatus['Kind']) {
        'Ok' { 'Green' }
        'Warn' { 'Yellow' }
        'Error' { 'Red' }
        default { 'DarkGray' }
    }
    Write-ARLine (Format-ARText (' ' + $script:ARStatus['Text']) $inner) $statusColor

    if ($Prompt -ne '') {
        Write-ARLine (Format-ARText (' ' + $Prompt) $inner) 'Yellow'
    }
    else {
        $footer = ' Up/Down move  Enter run  T target  / search  L language  F1 help  Q quit'
        if ($script:ARFilter -ne '') {
            $footer = ' Filter: ' + $script:ARFilter + '  |  Esc clear  | ' + $footer.Trim()
        }
        Write-ARLine (Format-ARText $footer $inner) 'DarkGray'
    }
}

function Show-ARHelp {
    Clear-ARScreen
    $width = Get-ARConsoleWidth
    $inner = $width - 1
    Write-ARLine (Format-ARText 'AutoRDPwn help' $inner) 'Yellow'
    Write-ARLine ('-' * $inner) 'DarkGray'
    Write-ARLine ' Up / Down        move through actions' 'Gray'
    Write-ARLine ' PgUp / PgDn      move a page at a time' 'Gray'
    Write-ARLine ' Home / End      jump to the first or last action' 'Gray'
    Write-ARLine ' Enter           run the selected action' 'Gray'
    Write-ARLine ' T               edit target, credentials and mode' 'Gray'
    Write-ARLine ' /               filter actions by text' 'Gray'
    Write-ARLine ' L               change language' 'Gray'
    Write-ARLine ' Esc             clear the filter or close a dialog' 'Gray'
    Write-ARLine ' Q / X           quit' 'Gray'
    Write-ARLine ''
    Write-ARLine ' Legacy -option values 11..17 map to the first action of each old module group.' 'DarkGray'
    Write-ARLine ''
    Write-ARLine ' Press any key to return' 'Green'
    if (-not $script:ARTestMode) {
        try { $null = [Console]::ReadKey($true) } catch { }
    }
}

function Show-ARTargetFormScreen {
    param([int]$Index)
    $width = Get-ARConsoleWidth
    $inner = $width - 1
    $fields = @(
        @{ Key = 'Computer'; Label = 'Target host' },
        @{ Key = 'User'; Label = 'User' },
        @{ Key = 'Password'; Label = 'Password' },
        @{ Key = 'Hash'; Label = 'NTLM hash' },
        @{ Key = 'Domain'; Label = 'Domain' },
        @{ Key = 'AttackerIP'; Label = 'Attacker IP' },
        @{ Key = 'Mode'; Label = 'Mode' }
    )
    Clear-ARScreen
    Write-ARLine (Format-ARText (' Target editor  |  {0}' -f $script:ARLocaleName) $inner) 'Yellow'
    Write-ARLine ('-' * $inner) 'DarkGray'
    for ($i = 0; $i -lt $fields.Count; $i++) {
        $field = $fields[$i]
        $value = [string]$script:ARTarget[$field.Key]
        if ($field.Key -eq 'Password' -and $value -ne '') { $value = '********' }
        if ($field.Key -eq 'Hash' -and $value -ne '') {
            if ($value.Length -gt 16) { $value = $value.Substring(0, 16) + '...' }
        }
        if ($field.Key -eq 'AttackerIP' -and $value -eq '') { $value = 'auto' }
        if ($field.Key -eq 'User' -and $value -eq '') { $value = '(current user)' }
        if ($value -eq '') { $value = '(not set)' }
        $marker = if ($i -eq $Index) { '>' } else { ' ' }
        $line = ' {0} {1,-12} : {2}' -f $marker, $field.Label, $value
        if ($i -eq $Index) {
            Write-ARLine (Format-ARText $line $inner) 'Black' 'Gray'
        }
        else {
            Write-ARLine (Format-ARText $line $inner) 'Gray'
        }
    }
    Write-ARLine ('-' * $inner) 'DarkGray'
    Write-ARLine ' Up/Down move  Enter edit  S save  Esc cancel' 'DarkGray'
}

function Read-ARLineValue {
    param([string]$Prompt)
    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    try { return $Host.UI.ReadLine() } catch { return $null }
}

function Read-ARSecretValue {
    param([string]$Prompt)
    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    try {
        $secure = $Host.UI.ReadLineAsSecureString()
        if ($null -eq $secure) { return '' }
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
        try {
            return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        }
        finally {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
    catch { return '' }
}

function Edit-ARTargetField {
    param([hashtable]$Field)
    if ($Field.Key -eq 'Mode') {
        if ($script:ARTarget['Mode'] -eq 'control') { $script:ARTarget['Mode'] = 'view' }
        else { $script:ARTarget['Mode'] = 'control' }
        return
    }
    if ($Field.Key -eq 'Password') {
        $value = Read-ARSecretValue ' New password (Enter keeps, - clears): '
        if ($null -eq $value) { return }
        if ($value -eq '-') { $script:ARTarget['Password'] = '' }
        elseif ($value -ne '') { $script:ARTarget['Password'] = $value }
        return
    }
    $current = [string]$script:ARTarget[$Field.Key]
    $value = Read-ARLineValue (' {0} [{1}]: ' -f $Field.Label, $current)
    if ($null -eq $value) { return }
    $value = $value.Trim()
    if ($value -eq '') {
        if ($Field.Key -eq 'Computer') { $script:ARTarget['Computer'] = 'localhost' }
        elseif ($Field.Key -eq 'User') { $script:ARTarget['User'] = '' }
        else { $script:ARTarget[$Field.Key] = '' }
        return
    }
    if ($Field.Key -eq 'Mode') {
        if ($value -match '^1$|control') { $script:ARTarget['Mode'] = 'control' }
        elseif ($value -match '^2$|view') { $script:ARTarget['Mode'] = 'view' }
        return
    }
    $script:ARTarget[$Field.Key] = $value
}

function Show-ARTargetForm {
    $fields = @(
        @{ Key = 'Computer'; Label = 'Target host' },
        @{ Key = 'User'; Label = 'User' },
        @{ Key = 'Password'; Label = 'Password' },
        @{ Key = 'Hash'; Label = 'NTLM hash' },
        @{ Key = 'Domain'; Label = 'Domain' },
        @{ Key = 'AttackerIP'; Label = 'Attacker IP' },
        @{ Key = 'Mode'; Label = 'Mode' }
    )
    $index = 0
    while ($true) {
        Show-ARTargetFormScreen -Index $index
        if ($script:ARTestMode) { return $false }
        try { $key = [Console]::ReadKey($true) } catch { return $false }
        switch ($key.Key) {
            'UpArrow' {
                $index--
                if ($index -lt 0) { $index = $fields.Count - 1 }
            }
            'DownArrow' {
                $index++
                if ($index -ge $fields.Count) { $index = 0 }
            }
            'Home' { $index = 0 }
            'End' { $index = $fields.Count - 1 }
            'Enter' {
                Edit-ARTargetField -Field $fields[$index]
            }
            'Escape' { return $true }
            default {
                $character = $key.KeyChar.ToString().ToUpperInvariant()
                if ($character -eq 'S') { return $true }
                if ($character -eq 'Q') { return $false }
            }
        }
    }
}

function Read-ARLineTargetForm {
    $labels = @(
        @{ Key = 'Computer'; Text = 'Target host' },
        @{ Key = 'User'; Text = 'User' },
        @{ Key = 'Hash'; Text = 'NTLM hash' },
        @{ Key = 'Domain'; Text = 'Domain' },
        @{ Key = 'AttackerIP'; Text = 'Attacker IP' }
    )
    foreach ($field in $labels) {
        $current = [string]$script:ARTarget[$field.Key]
        $value = Read-ARLineValue (' {0} [{1}]: ' -f $field.Text, $current)
        if ($null -eq $value) { continue }
        $value = $value.Trim()
        if ($value -ne '') { $script:ARTarget[$field.Key] = $value }
        elseif ($field.Key -eq 'Computer') { $script:ARTarget['Computer'] = 'localhost' }
    }
    $password = Read-ARSecretValue ' New password (Enter keeps, - clears): '
    if ($null -ne $password) {
        if ($password -eq '-') { $script:ARTarget['Password'] = '' }
        elseif ($password -ne '') { $script:ARTarget['Password'] = $password }
    }
    $mode = Read-ARLineValue (' Mode [1 control, 2 view] [{0}]: ' -f $script:ARTarget['Mode'])
    if ($null -ne $mode) {
        $mode = $mode.Trim()
        if ($mode -match '^1$|control') { $script:ARTarget['Mode'] = 'control' }
        elseif ($mode -match '^2$|view') { $script:ARTarget['Mode'] = 'view' }
    }
}

function Show-ARLanguagePicker {
    $languages = @('English', 'Spanish', 'French', 'German', 'Italian', 'Russian', 'Portuguese')
    $index = [Array]::IndexOf($languages, $script:ARLocaleName)
    if ($index -lt 0) { $index = 0 }
    while ($true) {
        Clear-ARScreen
        $width = Get-ARConsoleWidth
        $inner = $width - 1
        Write-ARLine ' Language' 'Yellow'
        Write-ARLine ('-' * $inner) 'DarkGray'
        for ($i = 0; $i -lt $languages.Count; $i++) {
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $line = ' {0} {1,2}. {2}' -f $marker, ($i + 1), $languages[$i]
            if ($i -eq $index) { Write-ARLine $line 'Black' 'Gray' }
            else { Write-ARLine $line 'Gray' }
        }
        Write-ARLine ('-' * $inner) 'DarkGray'
        Write-ARLine ' Up/Down move  Enter select  Esc cancel' 'DarkGray'
        if ($script:ARTestMode) { return '' }
        try { $key = [Console]::ReadKey($true) } catch { return '' }
        switch ($key.Key) {
            'UpArrow' {
                $index--
                if ($index -lt 0) { $index = $languages.Count - 1 }
            }
            'DownArrow' {
                $index++
                if ($index -ge $languages.Count) { $index = 0 }
            }
            'Enter' {
                $script:ARLocaleName = $languages[$index]
                return $languages[$index]
            }
            'Escape' { return '' }
            default {
                $character = $key.KeyChar.ToString().ToUpperInvariant()
                if ($character -eq 'Q') { return '' }
                if ($character -match '^[1-7]$') {
                    $languageIndex = ([int]$character) - 1
                    $script:ARLocaleName = $languages[$languageIndex]
                    return $languages[$languageIndex]
                }
            }
        }
    }
}

function Show-ARTui {
    param([string]$InitialId = '')
    if (-not (Get-ARActionById $InitialId)) {
        $first = Get-ARActionCatalog | Where-Object { $_.Kind -eq 'Action' } | Select-Object -First 1
        if ($first) { $script:ARSelectedId = $first.Id }
    }
    else {
        $script:ARSelectedId = $InitialId
    }
    $script:ARScroll = 0
    while ($true) {
        Show-ARTuiScreen
        if ($script:ARTestMode) { return 'TEST' }
        try { $key = [Console]::ReadKey($true) } catch { return 'QUIT' }
        switch ($key.Key) {
            'UpArrow' { Move-ARSelection -Delta -1 }
            'DownArrow' { Move-ARSelection -Delta 1 }
            'PageUp' { Move-ARSelectionPage -Pages -1 }
            'PageDown' { Move-ARSelectionPage -Pages 1 }
            'Home' {
                $first = Get-ARFilteredCatalog -Filter $script:ARFilter | Where-Object { $_.Kind -eq 'Action' } | Select-Object -First 1
                if ($first) { $script:ARSelectedId = $first.Id; $script:ARScroll = 0 }
            }
            'End' {
                $last = Get-ARFilteredCatalog -Filter $script:ARFilter | Where-Object { $_.Kind -eq 'Action' } | Select-Object -Last 1
                if ($last) { $script:ARSelectedId = $last.Id }
            }
            'Enter' { return ('ACTION:' + $script:ARSelectedId) }
            'Escape' {
                if ($script:ARFilter -ne '') {
                    $script:ARFilter = ''
                    Set-ARStatus 'Filter cleared' 'Info'
                }
            }
            'F1' { Show-ARHelp }
            default {
                $character = $key.KeyChar.ToString().ToUpperInvariant()
                if ($character -eq 'Q' -or $character -eq 'X') { return 'QUIT' }
                if ($character -eq 'T') {
                    if (Show-ARTargetForm) { Set-ARStatus 'Target updated' 'Ok' }
                }
                if ($character -eq 'L') { return 'LANGUAGE' }
                if ($character -eq '/') {
                    Show-ARTuiScreen -Prompt 'Filter:'
                    try { $filterValue = $Host.UI.ReadLine() } catch { $filterValue = $null }
                    if ($null -ne $filterValue) {
                        $script:ARFilter = $filterValue.Trim()
                        if ($script:ARFilter -ne '') {
                            $rows = @(Get-ARFilteredCatalog -Filter $script:ARFilter | Where-Object { $_.Kind -eq 'Action' })
                            if ($rows.Count -gt 0) { $script:ARSelectedId = $rows[0].Id; $script:ARScroll = 0 }
                            else { Set-ARStatus 'No action matches the filter' 'Warn' }
                        }
                    }
                }
                if ($character -eq 'R') {
                    $script:ARFilter = ''
                    Set-ARStatus 'Filter cleared' 'Info'
                }
            }
        }
    }
}

function Show-ARLineMenu {
    Clear-ARScreen
    $width = Get-ARConsoleWidth
    $inner = $width - 1
    Write-ARLine (Format-ARText ('AutoRDPwn v5.2 - line mode  |  {0}' -f $script:ARLocaleName) $inner) 'Yellow'
    Write-ARLine ('-' * $inner) 'DarkGray'
    Write-ARLine (Format-ARText ('Target: {0}  User: {1}  Mode: {2}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode']) $inner) 'Gray'
    Write-ARLine ''
    foreach ($item in Get-ARActionCatalog) {
        if ($item.Kind -eq 'Group') {
            Write-ARLine ''
            Write-ARLine (Format-ARText (' -- {0} --' -f $item.Title) $inner) 'Blue'
            continue
        }
        Write-ARLine (Format-ARText (' [{0,3}] {1}' -f $item.Id, $item.Title) $inner) 'Gray'
        Write-ARLine (Format-ARText ('       {0}' -f $item.Description) $inner) 'DarkGray'
    }
    Write-ARLine ''
    Write-ARLine ' [L] language  [T] target  [Q] quit' 'DarkGray'
    if ($script:ARTestMode) { return '' }
    $selection = Read-ARLineValue ' Choose an action:'
    if ($null -eq $selection) { return 'QUIT' }
    return (Resolve-ARSelection $selection)
}

function Show-ARLineTargetForm {
    Clear-ARScreen
    Write-ARLine 'Target editor (line mode)' 'Yellow'
    Read-ARLineTargetForm
    Set-ARStatus 'Target updated' 'Ok'
}
