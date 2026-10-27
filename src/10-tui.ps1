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
$script:ARActionCatalogCache = $null
$script:ARTargetProfilesPath = ''
$script:ARTuiFrameActive = $false
$script:ARTuiFrameScreen = ''
$script:ARTuiFrameWidth = 0
$script:ARTuiFrameHeight = 0
$script:ARTuiFrameLine = 0
$script:ARAdminState = $null
$script:ARTuiLevel = ''
$script:ARSelectedCategoryKey = 'quick'
$script:ARCategoryScroll = 0
$script:ARPendingKey = $null
$script:ARTuiPromptRow = 0
$script:ARLineCategoryKey = ''
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

function Start-ARTuiFrame {
    param([string]$Screen = 'main')
    if ($script:ARTestMode) { return }
    try {
        $width = Get-ARConsoleWidth
        $height = Get-ARConsoleHeight
        $needsClear = (-not $script:ARTuiFrameActive) -or
            ($Screen -ne $script:ARTuiFrameScreen) -or
            ($width -ne $script:ARTuiFrameWidth) -or
            ($height -ne $script:ARTuiFrameHeight)
        if ($needsClear) {
            if (-not $script:ARNoClear) { Clear-Host }
            $script:ARTuiFrameActive = $true
            $script:ARTuiFrameScreen = $Screen
            $script:ARTuiFrameWidth = $width
            $script:ARTuiFrameHeight = $height
        }
        try { [Console]::CursorVisible = $false } catch { }
        try {
            [Console]::SetCursorPosition(0, 0)
            $script:ARTuiFrameLine = 0
        }
        catch {
            Clear-ARScreen
            $script:ARTuiFrameActive = $false
        }
    }
    catch {
        Clear-ARScreen
        $script:ARTuiFrameActive = $false
    }
}

function Stop-ARTuiFrame {
    if ($script:ARTestMode) { return }
    try {
        $row = [Math]::Min((Get-ARConsoleHeight) - 1, [Math]::Max(0, $script:ARTuiFrameLine))
        [Console]::SetCursorPosition(0, $row)
    }
    catch { }
    try { [Console]::CursorVisible = $true } catch { }
    $script:ARTuiFrameActive = $false
    $script:ARTuiFrameScreen = ''
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
    if ($script:ARTuiFrameActive) {
        $width = $script:ARTuiFrameWidth - 1
        if ($width -gt 0 -and $Text.Length -lt $width) {
            $Text = $Text.PadRight($width)
        }
        $script:ARTuiFrameLine++
    }
    if ($Background -ne '') {
        Write-Host $Text -ForegroundColor $Color -BackgroundColor $Background
    }
    else {
        Write-Host $Text -ForegroundColor $Color
    }
}

function Test-ARIsAdmin {
    if ($null -ne $script:ARAdminState) { return $script:ARAdminState }
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        $script:ARAdminState = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        $script:ARAdminState = $false
    }
    return $script:ARAdminState
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
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [string]$Description = ''
    )
    return [pscustomobject]@{
        Kind        = 'Group'
        Title       = $Title
        Description = $Description
    }
}

function Reset-ARActionCatalogCache {
    $script:ARActionCatalogCache = $null
}

function Get-ARActionCatalog {
    if ($null -ne $script:ARActionCatalogCache) { return $script:ARActionCatalogCache }
    $items = New-Object System.Collections.Generic.List[object]

    $items.Add((New-ARAction -Id '1' -Title (Get-ARText 'txt155' 'PSexec (SMB)') -Description 'Copy and start the payload with PSexec over SMB, then open the shadow session.' -Handler 'Invoke-ARAttackPSexec' -NeedsSession $false))
    $items.Add((New-ARAction -Id '2' -Title (Get-ARText 'txt156' 'Pass the Hash (SMB)') -Description 'Authenticate with an NTLM hash through SMBExec and start the payload.' -Handler 'Invoke-ARAttackPassTheHash' -NeedsSession $false))
    $items.Add((New-ARAction -Id '3' -Title (Get-ARText 'txt157' 'Windows Management Instrumentation (WMI)') -Description 'Create the remote process through CIM/WMI with optional credentials.' -Handler 'Invoke-ARAttackWmi' -NeedsSession $false))
    $items.Add((New-ARAction -Id '4' -Title (Get-ARText 'txt158' 'Windows Remote Management (WinRM)') -Description 'Run the payload through a WinRM session with optional credentials.' -Handler 'Invoke-ARAttackWinRm' -NeedsSession $false))
    $items.Add((New-ARAction -Id '5' -Title (Get-ARText 'txt159' 'Windows Remote Assistance (WinRS)') -Description 'Run the payload with WinRS and then open the shadow session.' -Handler 'Invoke-ARAttackWinRs' -NeedsSession $false))
    $items.Add((New-ARAction -Id '6' -Title (Get-ARText 'txt160' 'Local Session Hijacking (TSCon)') -Description 'Attach the current console to another local session with tscon.' -Handler 'Invoke-ARAttackTscon' -NeedsTarget $false -NeedsSession $false))
    $items.Add((New-ARAction -Id '7' -Title (Get-ARText 'txt161' 'Remote Desktop Execution (RDP)') -Description 'Start the payload through SharpRDP and then open the shadow session.' -Handler 'Invoke-ARAttackRdp' -NeedsSession $false))
    $items.Add((New-ARAction -Id '8' -Title (Get-ARText 'txt121' 'Quick Screen (Stealth VNC)') -Description (Get-ARText 'txt122' 'Watch or control the target screen without the user noticing') -Handler 'Invoke-ARAttackQuickScreen'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt17' 'Remote Access') -Description (Get-ARText 'txt139' 'Shells, consoles and reverse connections that stay open')))
    $items.Add((New-ARAction -Id '101' -Title 'Named Pipe Remote Shell (SMB)' -Description (Get-ARText 'txt95' 'Remote shell through a named pipe over SMB port 445') -Handler 'Invoke-ARModulePipeShell'))
    $items.Add((New-ARAction -Id '102' -Title (Get-ARText 'txt39' 'Semi-interactive console (WinRS)') -Description (Get-ARText 'txt96' 'Remote console over WinRM port 5985 using direct PowerShell') -Handler 'Invoke-ARModuleWinRsConsole'))
    $items.Add((New-ARAction -Id '103' -Title 'PowerShell HTTP-RevShell (HTTP/S)' -Description (Get-ARText 'txt97' 'Reverse shell that dials back over HTTP/S, crosses proxies') -Handler 'Invoke-ARModuleHttpRevShell'))
    $items.Add((New-ARAction -Id '104' -Title (Get-ARText 'txt51' 'Netcat console (direct connection)') -Description (Get-ARText 'txt99' 'The target listens and you connect to it') -Handler 'Invoke-ARModuleNetcatDirect'))
    $items.Add((New-ARAction -Id '105' -Title (Get-ARText 'txt52' 'Netcat console (reverse connection)') -Description (Get-ARText 'txt98' 'You listen and the target connects back to you') -Handler 'Invoke-ARModuleNetcatReverse'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt50' 'Passwords and hashes') -Description (Get-ARText 'txt140' 'Dump credentials, browser secrets and saved Wi-Fi keys')))
    $items.Add((New-ARAction -Id '201' -Title (Get-ARText 'txt9' 'Extract local hashes with Mimikatz') -Description (Get-ARText 'txt100' 'Dump local account password hashes from the SAM registry hive') -Handler 'Invoke-ARModuleMimikatzSam'))
    $items.Add((New-ARAction -Id '202' -Title (Get-ARText 'txt10' 'Extract system passwords with Mimikatz') -Description (Get-ARText 'txt101' 'Extract plaintext passwords from the memory of authenticated processes') -Handler 'Invoke-ARModuleMimikatzLogon'))
    $items.Add((New-ARAction -Id '203' -Title (Get-ARText 'txt49' 'Obtain browsers passwords with SharpWeb') -Description (Get-ARText 'txt102' 'Recover passwords saved in Chrome, Firefox and other browsers') -Handler 'Invoke-ARModuleSharpWeb'))
    $items.Add((New-ARAction -Id '204' -Title (Get-ARText 'txt59' 'Recover Wi-Fi passwords') -Description (Get-ARText 'txt103' 'Show the keys of saved WiFi networks in clear text') -Handler 'Invoke-ARModuleWifiKeys'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt125' 'Networking / Pivoting') -Description (Get-ARText 'txt141' 'Scan, forward ports, serve files and spray credentials')))
    $items.Add((New-ARAction -Id '301' -Title 'TCP Port Scan' -Description (Get-ARText 'txt104' 'Multi-threaded TCP port scan of the target') -Handler 'Invoke-ARModulePortScan' -NeedsSession $false))
    $items.Add((New-ARAction -Id '302' -Title 'Native Port Forwarding' -Description (Get-ARText 'txt105' 'Forward ports with netsh, inbound locally or remote pivoting') -Handler 'Invoke-ARModulePortForward'))
    $items.Add((New-ARAction -Id '303' -Title 'PowerShell Web Server' -Description (Get-ARText 'txt106' 'Serve files from the target with a PowerShell web server') -Handler 'Invoke-ARModuleWebServer'))
    $items.Add((New-ARAction -Id '304' -Title 'Network Creds Scanner' -Description (Get-ARText 'txt107' 'Test a password or NTLM hash against a CIDR range via SMB/WMI') -Handler 'Invoke-ARModuleCredScan' -NeedsSession $false))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt126' 'Remote Desktop Forensics') -Description (Get-ARText 'txt142' 'Recover session history and enumerate local accounts')))
    $items.Add((New-ARAction -Id '401' -Title (Get-ARText 'txt11' 'Rebuild the image cache') -Description (Get-ARText 'txt129' 'Recover the RDP session history cached on this computer') -Handler 'Invoke-ARModuleRdpCaching' -NeedsTarget $false -NeedsSession $false))
    $items.Add((New-ARAction -Id '402' -Title (Get-ARText 'txt127' 'List local users and groups') -Description (Get-ARText 'txt109' 'List every user with SID, groups and last logon details') -Handler 'Invoke-ARModuleListUsers'))
    $items.Add((New-ARAction -Id '403' -Title (Get-ARText 'txt128' 'Extract session credentials (SessionGopher)') -Description (Get-ARText 'txt110' 'Extract credentials stored by PuTTY, SuperPuTTY, FileZilla and WinSCP') -Handler 'Invoke-ARModuleSessionGopher'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt64' 'Backdoors and persistence') -Description (Get-ARText 'txt143' 'Sticky keys, Metasploit and a remote keylogger')))
    $items.Add((New-ARAction -Id '501' -Title 'Sticky Keys Hacking' -Description (Get-ARText 'txt111' 'Replace sethc.exe so a SYSTEM console opens from the login screen') -Handler 'Invoke-ARModuleStickyKeys'))
    $items.Add((New-ARAction -Id '502' -Title 'Metasploit Reverse Shell' -Description (Get-ARText 'txt112' 'Deploy a persistent Metasploit reverse shell on the target') -Handler 'Invoke-ARModuleMetasploit'))
    $items.Add((New-ARAction -Id '503' -Title 'Remote Keylogger' -Description (Get-ARText 'txt113' 'Log every keystroke typed on the target console') -Handler 'Invoke-ARModuleKeylogger'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt68' 'Privilege escalation') -Description (Get-ARText 'txt144' 'Enumerate services, patches and paths to SYSTEM')))
    $items.Add((New-ARAction -Id '601' -Title (Get-ARText 'txt70' 'Get operating system information') -Description (Get-ARText 'txt114' 'Full enumeration of privesc surface and local misconfigurations') -Handler 'Invoke-ARModuleChachi'))
    $items.Add((New-ARAction -Id '602' -Title (Get-ARText 'txt71' 'Search vulnerabilities with Sherlock') -Description (Get-ARText 'txt115' 'Scan the system for known kernel and service vulnerabilities') -Handler 'Invoke-ARModuleSherlock'))
    $items.Add((New-ARAction -Id '603' -Title (Get-ARText 'txt130' 'Privilege escalation audit') -Description (Get-ARText 'txt116' 'Audit services, tasks, permissions and patches for escalation paths') -Handler 'Invoke-ARModulePrivescCheck'))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt69' 'Other modules') -Description (Get-ARText 'txt145' 'Logs, VNC, external scripts and user switching')))
    $items.Add((New-ARAction -Id '701' -Title (Get-ARText 'txt18' 'Deactivate system logs') -Description (Get-ARText 'txt117' 'Wipe event logs without stopping the EventLog service') -Handler 'Invoke-ARModulePhant0m'))
    $items.Add((New-ARAction -Id '702' -Title (Get-ARText 'txt62' 'Remote VNC Server (legacy)') -Description (Get-ARText 'txt118' 'Open an invisible VNC to watch and control the target screen') -Handler 'Invoke-ARModuleVncServer'))
    $items.Add((New-ARAction -Id '703' -Title (Get-ARText 'txt67' 'External script execution') -Description (Get-ARText 'txt119' 'Run any external PowerShell script or function on the target') -Handler 'Invoke-ARModuleExternalScript'))
    $items.Add((New-ARAction -Id '704' -Title (Get-ARText 'txt79' 'Change user with RunAs') -Description (Get-ARText 'txt120' 'Validate credentials and launch processes as another user') -Handler 'Invoke-ARModuleRunAs' -NeedsTarget $false -NeedsSession $false))

    $script:ARActionCatalogCache = $items.ToArray()
    return $script:ARActionCatalogCache
}

function Get-ARActionById {
    param([string]$Id = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
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

function Get-ARActionCategories {
    $catalog = @(Get-ARActionCatalog)
    $buckets = New-Object System.Collections.Generic.List[object]
    $current = @{
        Key         = 'quick'
        Title       = (Get-ARText 'txt137' 'Quick actions')
        Description = (Get-ARText 'txt138' 'One-shot remote execution and live screen control')
        Actions     = (New-Object System.Collections.Generic.List[object])
    }
    $buckets.Add($current)
    foreach ($item in $catalog) {
        if ($item.Kind -eq 'Group') {
            $description = ''
            if ($item.PSObject.Properties['Description']) { $description = [string]$item.Description }
            $current = @{
                Key         = 'pending'
                Title       = [string]$item.Title
                Description = $description
                Actions     = (New-Object System.Collections.Generic.List[object])
            }
            $buckets.Add($current)
            continue
        }
        $current['Actions'].Add($item)
    }
    $categories = New-Object System.Collections.Generic.List[object]
    foreach ($bucket in $buckets) {
        $actions = @($bucket['Actions'].ToArray())
        if ($actions.Count -eq 0) { continue }
        $key = [string]$bucket['Key']
        if ($key -eq 'pending') { $key = 'group-' + [string]$actions[0].Id }
        $description = [string]$bucket['Description']
        if ([string]::IsNullOrWhiteSpace($description)) {
            $description = (Format-ARItemCount -Count $actions.Count -Plural (Get-ARText 'txt146' 'actions'))
        }
        $categories.Add([pscustomobject]@{
            Kind        = 'Category'
            Key         = $key
            Title       = [string]$bucket['Title']
            Description = $description
            Actions     = $actions
        })
    }
    return $categories.ToArray()
}

function Get-ARCategoryByKey {
    param([string]$Key = '')
    if ([string]::IsNullOrWhiteSpace($Key)) { return $null }
    foreach ($category in @(Get-ARActionCategories)) {
        if ($category.Key -eq $Key) { return $category }
    }
    return $null
}

function Get-ARCategoryForAction {
    param([string]$Id = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return $null }
    foreach ($category in @(Get-ARActionCategories)) {
        foreach ($action in $category.Actions) {
            if ($action.Id -eq $Id) { return $category }
        }
    }
    return $null
}

function Get-ARCategoryListForDisplay {
    $categories = @(Get-ARActionCategories)
    if ($script:ARTuiLevel -ne 'categories') { return $categories }
    if ([string]::IsNullOrWhiteSpace($script:ARFilter)) { return $categories }
    $needle = $script:ARFilter.Trim().ToLowerInvariant()
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($category in $categories) {
        $haystack = ([string]$category.Title + ' ' + [string]$category.Description).ToLowerInvariant()
        if ($haystack.Contains($needle)) { $result.Add($category); continue }
        # A category survives the filter when one of its actions matches, so a
        # search for a module name still leads to the category that holds it.
        foreach ($action in $category.Actions) {
            $entry = ([string]$action.Id + ' ' + [string]$action.Title + ' ' + [string]$action.Description).ToLowerInvariant()
            if ($entry.Contains($needle)) { $result.Add($category); break }
        }
    }
    return $result.ToArray()
}

function Get-ARCurrentCategory {
    $categories = @(Get-ARCategoryListForDisplay)
    if ($categories.Count -eq 0) { return $null }
    foreach ($category in $categories) {
        if ($category.Key -eq $script:ARSelectedCategoryKey) { return $category }
    }
    return $categories[0]
}

function Get-ARCategoryActionList {
    param($Category, [string]$Filter = '')
    if ($null -eq $Category) { return @() }
    $actions = @($Category.Actions)
    if ([string]::IsNullOrWhiteSpace($Filter)) { return $actions }
    $needle = $Filter.Trim().ToLowerInvariant()
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($action in $actions) {
        $haystack = ([string]$action.Id + ' ' + [string]$action.Title + ' ' + [string]$action.Description).ToLowerInvariant()
        if ($haystack.Contains($needle)) { $result.Add($action) }
    }
    return $result.ToArray()
}

function Get-ARCurrentActions {
    $category = Get-ARCurrentCategory
    return @(Get-ARCategoryActionList -Category $category -Filter $script:ARFilter)
}

function Get-ARCurrentAction {
    $actions = @(Get-ARCurrentActions)
    if ($actions.Count -eq 0) { return $null }
    foreach ($action in $actions) {
        if ($action.Id -eq $script:ARSelectedId) { return $action }
    }
    return $actions[0]
}

function Get-ARTuiListHeight {
    $height = Get-ARConsoleHeight
    return [Math]::Max(3, $height - 15)
}

function Initialize-ARTuiState {
    $categories = @(Get-ARActionCategories)
    if ($categories.Count -eq 0) {
        $script:ARTuiLevel = 'categories'
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ARSelectedId)) {
        $owner = Get-ARCategoryForAction $script:ARSelectedId
        if ($null -ne $owner) {
            $script:ARSelectedCategoryKey = $owner.Key
            if ($script:ARTuiLevel -ne 'categories' -and $script:ARTuiLevel -ne 'actions') {
                $script:ARTuiLevel = 'actions'
            }
            return
        }
    }
    if ($script:ARTuiLevel -ne 'actions') { $script:ARTuiLevel = 'categories' }
    $category = Get-ARCategoryByKey $script:ARSelectedCategoryKey
    if ($null -eq $category) {
        $category = $categories[0]
        $script:ARSelectedCategoryKey = $category.Key
    }
    if ([string]::IsNullOrWhiteSpace($script:ARSelectedId) -and $category.Actions.Count -gt 0) {
        $script:ARSelectedId = [string]$category.Actions[0].Id
    }
}

function Set-ARTuiCategory {
    param($Category)
    if ($null -eq $Category) { return }
    $script:ARSelectedCategoryKey = $Category.Key
    $script:ARCategoryScroll = 0
    if ($Category.Actions.Count -gt 0) {
        $script:ARSelectedId = [string]$Category.Actions[0].Id
    }
}

function Enter-ARTuiCategory {
    param([string]$Key = '')
    $category = Get-ARCategoryByKey $Key
    if ($null -eq $category) { return }
    $script:ARSelectedCategoryKey = $category.Key
    $script:ARTuiLevel = 'actions'
    $script:ARFilter = ''
    $script:ARScroll = 0
    $inside = $false
    foreach ($action in $category.Actions) {
        if ($action.Id -eq $script:ARSelectedId) { $inside = $true; break }
    }
    if (-not $inside -and $category.Actions.Count -gt 0) {
        $script:ARSelectedId = [string]$category.Actions[0].Id
    }
    Set-ARStatus ((Get-ARText 'txt151' 'Category') + ': ' + $category.Title) 'Info'
}

function Exit-ARTuiCategory {
    $script:ARTuiLevel = 'categories'
    $script:ARFilter = ''
    $category = Get-ARCurrentCategory
    if ($null -ne $category) {
        $script:ARSelectedCategoryKey = $category.Key
    }
    Set-ARStatus (Get-ARText 'txt149' 'Top level - choose a category') 'Info'
}

function Move-ARTuiSelection {
    param(
        [int]$Delta = 0,
        [switch]$Page
    )
    if ($script:ARTuiLevel -eq 'actions') {
        $actions = @(Get-ARCurrentActions)
        if ($actions.Count -eq 0) { return }
        $current = Get-ARCurrentAction
        $index = 0
        for ($i = 0; $i -lt $actions.Count; $i++) {
            if ($actions[$i].Id -eq $current.Id) { $index = $i; break }
        }
        if ($Page) {
            $step = [Math]::Max(3, (Get-ARTuiListHeight) - 1)
            $index = $index + ($Delta * $step)
            if ($index -lt 0) { $index = 0 }
            if ($index -ge $actions.Count) { $index = $actions.Count - 1 }
        }
        else {
            $index = $index + $Delta
            if ($index -lt 0) { $index = $actions.Count - 1 }
            if ($index -ge $actions.Count) { $index = 0 }
        }
        $script:ARSelectedId = [string]$actions[$index].Id
        return
    }
    $categories = @(Get-ARCategoryListForDisplay)
    if ($categories.Count -eq 0) { return }
    $current = Get-ARCurrentCategory
    $index = 0
    for ($i = 0; $i -lt $categories.Count; $i++) {
        if ($null -ne $current -and $categories[$i].Key -eq $current.Key) { $index = $i; break }
    }
    if ($Page) {
        $step = [Math]::Max(3, (Get-ARTuiListHeight) - 1)
        $index = $index + ($Delta * $step)
        if ($index -lt 0) { $index = 0 }
        if ($index -ge $categories.Count) { $index = $categories.Count - 1 }
    }
    else {
        $index = $index + $Delta
        if ($index -lt 0) { $index = $categories.Count - 1 }
        if ($index -ge $categories.Count) { $index = 0 }
    }
    Set-ARTuiCategory $categories[$index]
}

function Set-ARTuiSelectionEdge {
    param([switch]$Last)
    if ($script:ARTuiLevel -eq 'actions') {
        $actions = @(Get-ARCurrentActions)
        if ($actions.Count -eq 0) { return }
        if ($Last) { $script:ARSelectedId = [string]$actions[$actions.Count - 1].Id }
        else { $script:ARSelectedId = [string]$actions[0].Id }
        return
    }
    $categories = @(Get-ARCategoryListForDisplay)
    if ($categories.Count -eq 0) { return }
    if ($Last) { Set-ARTuiCategory $categories[$categories.Count - 1] }
    else { Set-ARTuiCategory $categories[0] }
}

function Test-ARTuiNumberExact {
    param([string]$Digits = '')
    if ([string]::IsNullOrWhiteSpace($Digits)) { return $false }
    if ($script:ARTuiLevel -eq 'categories') {
        $categories = @(Get-ARCategoryListForDisplay)
        $number = 0
        if (-not [int]::TryParse($Digits, [ref]$number)) { return $false }
        return ($number -ge 1 -and $number -le $categories.Count)
    }
    foreach ($action in @(Get-ARCurrentActions)) {
        if ($action.Id -eq $Digits) { return $true }
    }
    return $false
}

function Test-ARTuiNumberPrefix {
    param([string]$Digits = '')
    if ([string]::IsNullOrWhiteSpace($Digits)) { return $false }
    if ($script:ARTuiLevel -ne 'actions') { return $false }
    foreach ($action in @(Get-ARCurrentActions)) {
        $id = [string]$action.Id
        if ($id.Length -gt $Digits.Length -and $id.StartsWith($Digits, [System.StringComparison]::Ordinal)) { return $true }
    }
    return $false
}

function Read-ARTuiNumberInput {
    param([string]$FirstDigit = '')
    $buffer = $FirstDigit
    if ($script:ARTestMode) { return $buffer }
    $waited = 0
    $limit = 700
    while ($buffer.Length -lt 4 -and $waited -lt $limit) {
        $exact = Test-ARTuiNumberExact $buffer
        $ambiguous = Test-ARTuiNumberPrefix $buffer
        if ($exact -and -not $ambiguous) { break }
        $limit = if ($ambiguous) { 400 } else { 700 }
        $hasKey = $false
        try { $hasKey = [Console]::KeyAvailable } catch { $hasKey = $false }
        if ($hasKey) {
            $next = [Console]::ReadKey($true)
            $character = $next.KeyChar.ToString()
            if ($character -match '^\d$') {
                $buffer += $character
                $waited = 0
            }
            else {
                $script:ARPendingKey = $next
                break
            }
        }
        else {
            Start-Sleep -Milliseconds 25
            $waited += 25
        }
    }
    return $buffer
}

function Resolve-ARTuiNumber {
    param([string]$Digits = '')
    if ([string]::IsNullOrWhiteSpace($Digits)) { return $false }
    $number = 0
    if (-not [int]::TryParse($Digits, [ref]$number)) { return $false }
    if ($script:ARTuiLevel -eq 'categories') {
        $categories = @(Get-ARCategoryListForDisplay)
        if ($number -ge 1 -and $number -le $categories.Count) {
            Set-ARTuiCategory $categories[$number - 1]
            return $true
        }
    }
    else {
        $actions = @(Get-ARCurrentActions)
        foreach ($action in $actions) {
            if ($action.Id -eq $Digits) {
                $script:ARSelectedId = $action.Id
                return $true
            }
        }
        if ($number -ge 1 -and $number -le $actions.Count) {
            $script:ARSelectedId = [string]$actions[$number - 1].Id
            return $true
        }
    }
    if ($Digits.Length -lt 2) { return $false }
    $code = Resolve-ARSelection $Digits
    if ($code -notlike 'ACTION:*') { return $false }
    $actionId = $code.Substring(7)
    $owner = Get-ARCategoryForAction $actionId
    if ($null -eq $owner) { return $false }
    $script:ARTuiLevel = 'actions'
    $script:ARSelectedCategoryKey = $owner.Key
    $script:ARSelectedId = $actionId
    $script:ARFilter = ''
    $script:ARScroll = 0
    return $true
}

function Step-ARTuiBack {
    if ($script:ARFilter -ne '') {
        $script:ARFilter = ''
        Set-ARStatus (Get-ARText 'txt154' 'Filter cleared') 'Info'
        return
    }
    if ($script:ARTuiLevel -eq 'actions') {
        Exit-ARTuiCategory
        return
    }
    Set-ARStatus (Get-ARText 'txt149' 'Top level - choose a category') 'Info'
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
    if ($upper -in @('P', 'PROFILES', 'TARGETS')) { return 'PROFILES' }
    if ($upper -in @('S', 'SAVE')) { return 'SAVE' }
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
    Move-ARTuiSelection -Delta $Delta
}

function Get-ARTargetUserLabel {
    if ($script:ARTarget['User']) { return $script:ARTarget['User'] }
    return [Environment]::UserName
}

function Get-ARVersionLabel {
    if ($null -ne $script:ARVersion -and -not [string]::IsNullOrWhiteSpace([string]$script:ARVersion)) {
        return [string]$script:ARVersion
    }
    return '6.0'
}

function Format-ARItemCount {
    param([int]$Count = 0, [string]$Plural = 'items')
    if ($Count -eq 1) {
        if ($Plural.Length -gt 1 -and $Plural.EndsWith('s')) {
            return ('1 ' + $Plural.Substring(0, $Plural.Length - 1))
        }
        return ('1 ' + $Plural)
    }
    return ('{0} {1}' -f $Count, $Plural)
}

function Format-ARBoxText {
    param(
        [AllowNull()][string]$Text,
        [int]$MaxWidth
    )
    if ($MaxWidth -lt 1) { return '' }
    if ($null -eq $Text) { return '' }
    $flat = ($Text -replace '[\r\n\t]+', ' ')
    if ($flat.Length -le $MaxWidth) { return $flat }
    if ($MaxWidth -le 3) { return $flat.Substring(0, $MaxWidth) }
    return $flat.Substring(0, $MaxWidth - 3) + '...'
}

function Format-ARLeader {
    param(
        [string]$Label = '',
        [string]$Right = '',
        [int]$Width = 0,
        [string]$Fill = '.'
    )
    if ($Width -lt 1) { return '' }
    $left = Format-ARBoxText $Label $Width
    $right = Format-ARBoxText $Right $Width
    $space = $Width - $left.Length - $right.Length
    if ($space -le 0) {
        return (Format-ARBoxText ($left + ' ' + $right) $Width)
    }
    if ($space -eq 1) { return ($left + ' ' + $right) }
    $fill = $Fill * ($space - 2)
    return ($left + ' ' + $fill + ' ' + $right)
}

function Write-ARBoxBorder {
    param(
        [int]$Width,
        [string]$Color = 'DarkCyan'
    )
    $inner = [Math]::Max(0, $Width - 2)
    Write-ARLine ('+' + ('-' * $inner) + '+') $Color
}

function Write-ARBoxRule {
    param(
        [int]$Width,
        [string]$Label = '',
        [string]$Color = 'DarkCyan'
    )
    $inner = [Math]::Max(0, $Width - 2)
    if ([string]::IsNullOrWhiteSpace($Label)) {
        Write-ARLine ('+' + ('-' * $inner) + '+') $Color
        return
    }
    $text = Format-ARBoxText $Label ($inner - 5)
    $segment = '-- ' + $text + ' '
    $fill = [Math]::Max(0, $inner - $segment.Length)
    Write-ARLine ('+' + $segment + ('-' * $fill) + '+') $Color
}

function Write-ARBoxLine {
    param(
        [AllowEmptyString()][string]$Text = '',
        [int]$Width,
        [string]$Color = 'Gray',
        [string]$Background = ''
    )
    $contentWidth = [Math]::Max(1, $Width - 4)
    $body = Format-ARBoxText $Text $contentWidth
    if ($body.Length -lt $contentWidth) { $body = $body.PadRight($contentWidth) }
    Write-ARLine ('| ' + $body + ' |') $Color $Background
}

function Write-ARBoxColumns {
    param(
        [string]$Left = '',
        [string]$Right = '',
        [int]$Width,
        [string]$Color = 'Gray',
        [string]$Background = ''
    )
    $contentWidth = [Math]::Max(1, $Width - 4)
    $leftText = Format-ARBoxText $Left $contentWidth
    $rightText = Format-ARBoxText $Right $contentWidth
    $space = $contentWidth - $leftText.Length - $rightText.Length
    if ($space -lt 1) {
        $rightText = ''
        $space = $contentWidth - $leftText.Length
    }
    $line = $leftText + (' ' * [Math]::Max(0, $space)) + $rightText
    if ($line.Length -lt $contentWidth) { $line = $line.PadRight($contentWidth) }
    if ($line.Length -gt $contentWidth) { $line = $line.Substring(0, $contentWidth) }
    Write-ARLine ('| ' + $line + ' |') $Color $Background
}

function Read-ARTuiInlineInput {
    param(
        [int]$Row = -1,
        [int]$Column = 0,
        [string]$Initial = '',
        [int]$MaxLength = 40,
        [scriptblock]$OnChange = $null
    )
    if ($script:ARTestMode) { return $Initial }
    $buffer = [string]$Initial
    if ($buffer.Length -gt $MaxLength) { $buffer = $buffer.Substring(0, $MaxLength) }
    try {
        try { [Console]::CursorVisible = $true } catch { }
        while ($true) {
            if ($Row -ge 0) {
                try { [Console]::SetCursorPosition($Column + $buffer.Length, $Row) } catch { }
            }
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq 'Enter') { return $buffer }
            if ($key.Key -eq 'Escape') { return $null }
            if ($key.Key -eq 'Delete') {
                $buffer = ''
            }
            elseif ($key.Key -eq 'Backspace') {
                if ($buffer.Length -gt 0) { $buffer = $buffer.Substring(0, $buffer.Length - 1) }
            }
            else {
                $character = $key.KeyChar
                if ($character -and -not [char]::IsControl($character) -and $buffer.Length -lt $MaxLength) {
                    $buffer += $character.ToString()
                }
            }
            if ($null -ne $OnChange) {
                try { & $OnChange $buffer } catch { }
            }
        }
    }
    catch { return $null }
    finally {
        try { [Console]::CursorVisible = $false } catch { }
    }
}

function Get-ARStatusColor {
    switch ($script:ARStatus['Kind']) {
        'Ok' { return 'Green' }
        'Warn' { return 'Yellow' }
        'Error' { return 'Red' }
        default { return 'DarkGray' }
    }
}

function Get-ARCategoryLabel {
    $category = Get-ARCurrentCategory
    if ($null -eq $category) { return '' }
    return [string]$category.Title
}

function Show-ARTuiScreen {
    param([string]$Prompt = '')

    $width = Get-ARConsoleWidth
    $boxWidth = [Math]::Max(40, $width - 1)
    $contentWidth = [Math]::Max(20, $boxWidth - 4)
    $listHeight = Get-ARTuiListHeight
    $script:ARTuiPromptRow = 0

    Initialize-ARTuiState

    $level = $script:ARTuiLevel
    $items = @()
    $selectedIndex = -1
    $scroll = 0
    $detailTitle = ''
    $detailRight = ''
    $detailText = ''
    $noun = Get-ARText 'txt147' 'categories'

    if ($level -eq 'categories') {
        $items = @(Get-ARCategoryListForDisplay)
        $current = Get-ARCurrentCategory
        if ($null -ne $current) {
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($items[$i].Key -eq $current.Key) { $selectedIndex = $i; break }
            }
            $detailTitle = [string]$current.Title
            $detailRight = Format-ARItemCount -Count $current.Actions.Count -Plural (Get-ARText 'txt146' 'actions')
            $detailText = [string]$current.Description
        }
        $scroll = $script:ARCategoryScroll
    }
    else {
        $noun = Get-ARText 'txt146' 'actions'
        $items = @(Get-ARCurrentActions)
        $current = Get-ARCurrentAction
        if ($null -ne $current) {
            for ($i = 0; $i -lt $items.Count; $i++) {
                if ($items[$i].Id -eq $current.Id) { $selectedIndex = $i; break }
            }
            $detailTitle = [string]$current.Title
            $detailRight = '[' + [string]$current.Id + ']'
            $detailText = [string]$current.Description
        }
        $scroll = $script:ARScroll
    }

    if ($selectedIndex -ge 0) {
        if ($selectedIndex -lt $scroll) { $scroll = $selectedIndex }
        if ($selectedIndex -ge ($scroll + $listHeight)) {
            $scroll = $selectedIndex - $listHeight + 1
        }
    }
    $maxScroll = [Math]::Max(0, $items.Count - $listHeight)
    if ($scroll -gt $maxScroll) { $scroll = $maxScroll }
    if ($scroll -lt 0) { $scroll = 0 }
    if ($level -eq 'categories') { $script:ARCategoryScroll = $scroll }
    else { $script:ARScroll = $scroll }

    Start-ARTuiFrame -Screen 'main'

    $adminLabel = if (Test-ARIsAdmin) { 'yes' } else { 'no' }
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left ('AutoRDPwn v' + (Get-ARVersionLabel) + ' - Shadow Attack Framework') -Right ('admin: ' + $adminLabel + '  |  ' + $script:ARLocaleName) -Width $boxWidth -Color 'Yellow'
    $targetLine = 'Target: {0}  User: {1}  Mode: {2}  Session: {3}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode'], $script:ARSessionState
    Write-ARBoxLine $targetLine $boxWidth 'Gray'
    Write-ARBoxBorder $boxWidth

    if ($level -eq 'categories') {
        $breadcrumb = 'AutoRDPwn'
    }
    else {
        $breadcrumb = 'AutoRDPwn > ' + (Get-ARCategoryLabel)
    }
    $counter = '{0}/{1} {2}' -f [Math]::Max(0, ($selectedIndex + 1)), $items.Count, $noun
    $filterLabel = ''
    if ($script:ARFilter -ne '') { $filterLabel = '[/ ' + $script:ARFilter + ']' }
    Write-ARBoxColumns -Left $breadcrumb -Right $filterLabel -Width $boxWidth -Color 'Cyan'

    $ruleLabel = if ($level -eq 'categories') { 'CATEGORIES' } else { 'ACTIONS' }
    Write-ARBoxRule -Width $boxWidth -Label $ruleLabel -Color 'DarkCyan'

    for ($row = 0; $row -lt $listHeight; $row++) {
        $index = $scroll + $row
        if ($index -ge $items.Count) {
            Write-ARBoxLine '' $boxWidth
            continue
        }
        $item = $items[$index]
        $selected = ($index -eq $selectedIndex)
        $marker = if ($selected) { '>' } else { ' ' }
        if ($level -eq 'categories') {
            $count = Format-ARItemCount -Count $item.Actions.Count -Plural (Get-ARText 'txt146' 'actions')
            $prefix = '{0} {1,2}. ' -f $marker, ($index + 1)
            $text = Format-ARLeader -Label ([string]$item.Title) -Right $count -Width ($contentWidth - $prefix.Length)
            $line = $prefix + $text
        }
        else {
            $prefix = '{0} {1,2}. ' -f $marker, ($index + 1)
            $idText = '[{0,3}]' -f [string]$item.Id
            $text = Format-ARBoxText ([string]$item.Title) ($contentWidth - $prefix.Length - 7)
            $line = $prefix + $idText + ' ' + $text
        }
        if ($selected) {
            Write-ARBoxLine $line $boxWidth 'Black' 'Cyan'
        }
        else {
            Write-ARBoxLine $line $boxWidth 'White'
        }
    }

    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    if ($items.Count -eq 0) {
        Write-ARBoxLine (' ' + (Get-ARText 'txt150' 'No item matches the current filter')) $boxWidth 'DarkGray'
        Write-ARBoxLine '' $boxWidth
        Write-ARBoxLine '' $boxWidth
    }
    else {
        Write-ARBoxColumns -Left $detailTitle -Right $detailRight -Width $boxWidth -Color 'Yellow'
        $descriptionLines = @(Get-ARWrappedLines -Text $detailText -Width ($contentWidth - 2) -MaxLines 2)
        for ($i = 0; $i -lt 2; $i++) {
            if ($i -lt $descriptionLines.Count) {
                Write-ARBoxLine (' ' + $descriptionLines[$i]) $boxWidth 'Gray'
            }
            else {
                Write-ARBoxLine '' $boxWidth
            }
        }
    }

    Write-ARBoxColumns -Left ('Status: ' + [string]$script:ARStatus['Text']) -Right $counter -Width $boxWidth -Color (Get-ARStatusColor)

    if ($Prompt -ne '') {
        $script:ARTuiPromptRow = $script:ARTuiFrameLine
        $filterText = 'Filter: ' + [string]$script:ARFilter
        Write-ARBoxColumns -Left $filterText -Right 'Enter apply  Esc cancel  Del clear' -Width $boxWidth -Color 'Yellow'
        Write-ARBoxLine ' Type to narrow the list, the selection follows the filter' $boxWidth 'DarkGray'
    }
    else {
        if ($level -eq 'categories') {
            Write-ARBoxLine ' Up/Down move   Enter open   digits select   / filter   R clear' $boxWidth 'DarkGray'
        }
        else {
            Write-ARBoxLine ' Up/Down move   Enter run   Esc/Backspace back   digits jump   / filter' $boxWidth 'DarkGray'
        }
        Write-ARBoxLine ' T target   P profiles   S save   L language   F1 help   Q quit' $boxWidth 'DarkGray'
    }
    Write-ARBoxBorder $boxWidth
}

function Show-ARHelp {
    param(
        [string]$Level = '',
        [string]$CategoryTitle = ''
    )
    if ([string]::IsNullOrWhiteSpace($Level)) { $Level = $script:ARTuiLevel }
    if ([string]::IsNullOrWhiteSpace($Level)) { $Level = 'categories' }
    if ([string]::IsNullOrWhiteSpace($CategoryTitle)) { $CategoryTitle = Get-ARCategoryLabel }

    $width = Get-ARConsoleWidth
    $boxWidth = [Math]::Max(40, $width - 1)

    Start-ARTuiFrame -Screen 'help'
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left ('AutoRDPwn v' + (Get-ARVersionLabel) + ' - help') -Right ('level: ' + $Level) -Width $boxWidth -Color 'Yellow'
    Write-ARBoxRule -Width $boxWidth -Label 'KEYS' -Color 'DarkCyan'
    if ($Level -eq 'categories') {
        $lines = @(
            'Up / Down / PgUp / PgDn   move between categories',
            'Home / End                first or last category',
            'Enter / Right             open the selected category',
            'Digits                    select a category',
            '/                         filter categories by name',
            'R                         clear the filter',
            'Esc / Backspace           clear the filter, stay on top',
            'T / P / S / L             target, profiles, save, language',
            'F1                        this help',
            'Q / X                     quit'
        )
    }
    else {
        $lines = @(
            'Up / Down / PgUp / PgDn   move between actions',
            'Home / End                first or last action',
            'Enter                     run the selected action',
            'Esc / Backspace / Left    back to the category list',
            'Digits                    jump by number or by action id',
            '                          (1..n for position, 101..704 for id)',
            '/                         filter actions in this category',
            'R                         clear the filter',
            'T / P / S / L             target, profiles, save, language',
            'F1                        this help',
            'Q / X                     quit'
        )
    }
    $height = Get-ARConsoleHeight
    $showNotes = $true
    if ((7 + $lines.Count + 4) -gt ($height - 1)) { $showNotes = $false }
    if ((7 + $lines.Count) -gt ($height - 1)) {
        if ($Level -eq 'categories') {
            $lines = @(
                'Up / Down    move',
                'Enter        open',
                'Digits       select',
                '/            filter',
                'Esc          clear the filter',
                'T/P/S/L      target, profiles, save, language',
                'F1           help',
                'Q / X        quit'
            )
        }
        else {
            $lines = @(
                'Up / Down    move',
                'Enter        run',
                'Esc          back',
                'Digits       jump',
                '/            filter',
                'T/P/S/L      target, profiles, save, language',
                'F1           help',
                'Q / X        quit'
            )
        }
    }
    foreach ($line in $lines) {
        Write-ARBoxLine (' ' + $line) $boxWidth 'Gray'
    }
    if ($showNotes) {
        Write-ARBoxRule -Width $boxWidth -Label 'NOTES' -Color 'DarkCyan'
        if ($Level -eq 'actions' -and $CategoryTitle -ne '') {
            Write-ARBoxLine (' Category: ' + $CategoryTitle) $boxWidth 'Cyan'
        }
        Write-ARBoxLine ' Legacy -option 11..17 maps to the first action of each old group.' $boxWidth 'DarkGray'
        Write-ARBoxLine ' Profiles remember the last used target and reload it at start.' $boxWidth 'DarkGray'
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    Write-ARBoxLine '' $boxWidth
    Write-ARBoxLine ' Press any key to return' $boxWidth 'Green'
    Write-ARBoxBorder $boxWidth
    if (-not $script:ARTestMode) {
        try { $null = [Console]::ReadKey($true) } catch { }
    }
}

function Get-ARTargetProfilesPath {
    if (-not [string]::IsNullOrWhiteSpace($script:ARTargetProfilesPath)) {
        return $script:ARTargetProfilesPath
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ARTools)) {
        return (Join-Path $script:ARTools 'targets.json')
    }
    if (-not [string]::IsNullOrWhiteSpace($script:ARRoot)) {
        return (Join-Path $script:ARRoot 'Resources\Tools\targets.json')
    }
    return (Join-Path (Get-Location).Path 'targets.json')
}

function Get-ARTargetProfiles {
    $path = Get-ARTargetProfilesPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try {
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return @() }
        return @($data)
    }
    catch { return @() }
}

function Protect-ARTargetSecret {
    param([string]$Value = '')
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $secure = ConvertTo-SecureString -String $Value -AsPlainText -Force -ErrorAction Stop
    return (ConvertFrom-SecureString -SecureString $secure -ErrorAction Stop)
}

function Unprotect-ARTargetSecret {
    param([string]$Value = '')
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    try {
        $secure = ConvertTo-SecureString -String $Value -ErrorAction Stop
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

function Get-ARTargetProfileDefaultName {
    $computer = [string]$script:ARTarget['Computer']
    if ([string]::IsNullOrWhiteSpace($computer)) { $computer = 'localhost' }
    $user = [string]$script:ARTarget['User']
    if ([string]::IsNullOrWhiteSpace($user)) { return $computer }
    return ($computer + ' - ' + $user)
}

function Save-ARTargetProfile {
    param([string]$Name = '')
    $profileName = $Name.Trim()
    if ($profileName -eq '') { $profileName = Get-ARTargetProfileDefaultName }
    $profiles = New-Object System.Collections.Generic.List[object]
    foreach ($profile in @(Get-ARTargetProfiles)) {
        if ([string]$profile.Name -ne $profileName) { $profiles.Add($profile) }
    }
    $profiles.Add([pscustomobject]@{
        Name              = $profileName
        Computer          = [string]$script:ARTarget['Computer']
        User              = [string]$script:ARTarget['User']
        PasswordProtected = Protect-ARTargetSecret ([string]$script:ARTarget['Password'])
        HashProtected     = Protect-ARTargetSecret ([string]$script:ARTarget['Hash'])
        Domain            = [string]$script:ARTarget['Domain']
        AttackerIP        = [string]$script:ARTarget['AttackerIP']
        Mode              = [string]$script:ARTarget['Mode']
    })
    $path = Get-ARTargetProfilesPath
    $directory = Split-Path -Parent $path
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    $json = ConvertTo-Json -InputObject $profiles.ToArray() -Depth 3
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8 -ErrorAction Stop
    Set-ARLastProfileName $profileName
    return $profileName
}

function Apply-ARTargetProfile {
    param($Profile)
    if ($null -eq $Profile) { return $false }
    foreach ($key in @('Computer', 'User', 'Domain', 'AttackerIP')) {
        $property = $Profile.PSObject.Properties[$key]
        if ($property) { $script:ARTarget[$key] = [string]$property.Value }
    }
    $modeProperty = $Profile.PSObject.Properties['Mode']
    if ($modeProperty -and ([string]$modeProperty.Value -in @('control', 'view'))) {
        $script:ARTarget['Mode'] = [string]$modeProperty.Value
    }
    $passwordProperty = $Profile.PSObject.Properties['PasswordProtected']
    if ($passwordProperty) {
        $script:ARTarget['Password'] = Unprotect-ARTargetSecret ([string]$passwordProperty.Value)
    }
    $hashProperty = $Profile.PSObject.Properties['HashProtected']
    if ($hashProperty) {
        $script:ARTarget['Hash'] = Unprotect-ARTargetSecret ([string]$hashProperty.Value)
    }
    $nameProperty = $Profile.PSObject.Properties['Name']
    if ($nameProperty -and -not [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
        Set-ARLastProfileName ([string]$nameProperty.Value)
    }
    return $true
}

function Get-ARLastProfilePath {
    $profilesPath = Get-ARTargetProfilesPath
    $directory = Split-Path -Parent $profilesPath
    if ([string]::IsNullOrWhiteSpace($directory)) {
        if (-not [string]::IsNullOrWhiteSpace($script:ARRoot)) { $directory = $script:ARRoot }
        else { $directory = (Get-Location).Path }
    }
    return (Join-Path $directory 'last.json')
}

function Get-ARLastState {
    $state = @{}
    try {
        $path = Get-ARLastProfilePath
        if (-not (Test-Path -LiteralPath $path)) { return $state }
        $raw = Get-Content -LiteralPath $path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return $state }
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $data) { return $state }
        if ($data -isnot [System.Management.Automation.PSCustomObject]) { return $state }
        foreach ($property in $data.PSObject.Properties) {
            if ([string]::IsNullOrWhiteSpace($property.Name)) { continue }
            $state[[string]$property.Name] = $property.Value
        }
    }
    catch { }
    return $state
}

function Save-ARLastState {
    param([hashtable]$State)
    if ($null -eq $State) { return }
    try {
        $payload = [pscustomobject]$State
        Set-Content -LiteralPath (Get-ARLastProfilePath) -Value (ConvertTo-Json -InputObject $payload -Depth 3) -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

function Set-ARLastProfileName {
    param([string]$Name = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $state = Get-ARLastState
    $state['Name'] = $Name
    $state['Saved'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-ARLastState -State $state
}

function Set-ARLastLanguage {
    param([string]$Name = '')
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    $state = Get-ARLastState
    $state['Language'] = $Name
    if (-not $state.ContainsKey('Saved')) {
        $state['Saved'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    Save-ARLastState -State $state
}

function Get-ARLastLanguage {
    $state = Get-ARLastState
    if ($state.ContainsKey('Language')) { return [string]$state['Language'] }
    return ''
}

function Get-ARLastProfileName {
    try {
        $path = Get-ARLastProfilePath
        if (-not (Test-Path -LiteralPath $path)) { return '' }
        $data = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($data -and $data.PSObject.Properties['Name']) { return [string]$data.Name }
    }
    catch { }
    return ''
}

function Restore-ARLastProfile {
    $name = Get-ARLastProfileName
    if ([string]::IsNullOrWhiteSpace($name)) { return $false }
    foreach ($profile in @(Get-ARTargetProfiles)) {
        if ([string]$profile.Name -ne $name) { continue }
        if (Apply-ARTargetProfile $profile) {
            Set-ARStatus ((Get-ARText 'txt148' 'Last profile loaded') + ': ' + $name) 'Info'
            return $true
        }
    }
    Set-ARStatus ((Get-ARText 'txt148' 'Last profile loaded') + ': ' + $name + ' (missing)') 'Warn'
    return $false
}

function Save-ARCurrentTarget {
    try {
        $name = Save-ARTargetProfile
        Set-ARStatus ((Get-ARText 'txt133' 'Target saved') + ': ' + $name) 'Ok'
        return $true
    }
    catch {
        Set-ARStatus ((Get-ARText 'txt135' 'Could not save target') + ': ' + $_.Exception.Message) 'Error'
        return $false
    }
}

function Show-ARTargetProfilesScreen {
    param(
        [object[]]$Profiles,
        [int]$Index = 0
    )
    $width = Get-ARConsoleWidth
    $height = Get-ARConsoleHeight
    $boxWidth = [Math]::Max(40, $width - 1)
    $contentWidth = [Math]::Max(20, $boxWidth - 4)
    $listHeight = [Math]::Max(3, $height - 9)
    if ($Index -lt 0) { $Index = 0 }
    if ($Index -ge $Profiles.Count) { $Index = $Profiles.Count - 1 }
    $scroll = 0
    if ($Index -ge $listHeight) { $scroll = $Index - $listHeight + 1 }

    Start-ARTuiFrame -Screen 'profiles'
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left (Get-ARText 'txt136' 'Saved target profiles') -Right (Format-ARItemCount -Count $Profiles.Count -Plural 'profiles') -Width $boxWidth -Color 'Yellow'
    Write-ARBoxRule -Width $boxWidth -Label 'PROFILES' -Color 'DarkCyan'
    for ($row = 0; $row -lt $listHeight; $row++) {
        $profileIndex = $scroll + $row
        if ($profileIndex -ge $Profiles.Count) {
            Write-ARBoxLine '' $boxWidth
            continue
        }
        $profile = $Profiles[$profileIndex]
        $name = [string]$profile.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed)' }
        $hostName = [string]$profile.Computer
        if ([string]::IsNullOrWhiteSpace($hostName)) { $hostName = 'localhost' }
        $marker = if ($profileIndex -eq $Index) { '>' } else { ' ' }
        $prefix = '{0} {1,2}. ' -f $marker, ($profileIndex + 1)
        $line = $prefix + (Format-ARLeader -Label $name -Right $hostName -Width ($contentWidth - $prefix.Length))
        if ($profileIndex -eq $Index) {
            Write-ARBoxLine $line $boxWidth 'Black' 'Cyan'
        }
        else {
            Write-ARBoxLine $line $boxWidth 'White'
        }
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    $selected = $Profiles[$Index]
    $selectedUser = [string]$selected.User
    if ([string]::IsNullOrWhiteSpace($selectedUser)) { $selectedUser = '(current user)' }
    Write-ARBoxLine (' {0}  |  user: {1}  |  mode: {2}' -f $selected.Computer, $selectedUser, $selected.Mode) $boxWidth 'White'
    Write-ARBoxLine (' ' + (Get-ARText 'txt123' 'Your IP for the reverse connection') + ': ' + ([string]$selected.AttackerIP)) $boxWidth 'Gray'
    Write-ARBoxLine ' Up/Down move   Enter load   Esc cancel' $boxWidth 'DarkGray'
    Write-ARBoxBorder $boxWidth
}

function Show-ARTargetPicker {
    $profiles = @(Get-ARTargetProfiles)
    if ($profiles.Count -eq 0) {
        Set-ARStatus (Get-ARText 'txt132' 'No saved targets. Edit a target and press S to save it.') 'Warn'
        return $false
    }
    $index = 0
    for ($i = 0; $i -lt $profiles.Count; $i++) {
        if ([string]$profiles[$i].Computer -eq [string]$script:ARTarget['Computer'] -and
            [string]$profiles[$i].User -eq [string]$script:ARTarget['User']) {
            $index = $i
            break
        }
    }
    while ($true) {
        Show-ARTargetProfilesScreen -Profiles $profiles -Index $index
        if ($script:ARTestMode) { return $false }
        try { $key = [Console]::ReadKey($true) } catch { return $false }
        switch ($key.Key) {
            'UpArrow' {
                $index--
                if ($index -lt 0) { $index = $profiles.Count - 1 }
            }
            'DownArrow' {
                $index++
                if ($index -ge $profiles.Count) { $index = 0 }
            }
            'Home' { $index = 0 }
            'End' { $index = $profiles.Count - 1 }
            'Enter' {
                $null = Apply-ARTargetProfile $profiles[$index]
                Set-ARStatus ((Get-ARText 'txt134' 'Target loaded') + ': ' + [string]$profiles[$index].Name) 'Ok'
                return $true
            }
            'Escape' { return $false }
            default {
                $character = $key.KeyChar.ToString().ToUpperInvariant()
                if ($character -eq 'Q') { return $false }
            }
        }
    }
}

function Show-ARTargetFormScreen {
    param([int]$Index)
    $width = Get-ARConsoleWidth
    $boxWidth = [Math]::Max(40, $width - 1)
    $contentWidth = [Math]::Max(20, $boxWidth - 4)
    $fields = @(
        @{ Key = 'Computer'; Label = 'Target host' },
        @{ Key = 'User'; Label = 'User' },
        @{ Key = 'Password'; Label = 'Password' },
        @{ Key = 'Hash'; Label = 'NTLM hash' },
        @{ Key = 'Domain'; Label = 'Domain' },
        @{ Key = 'AttackerIP'; Label = 'Attacker IP' },
        @{ Key = 'Mode'; Label = 'Mode' }
    )
    Start-ARTuiFrame -Screen 'target'
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left 'Target editor' -Right $script:ARLocaleName -Width $boxWidth -Color 'Yellow'
    Write-ARBoxRule -Width $boxWidth -Label 'TARGET' -Color 'DarkCyan'
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
        $prefix = '{0} ' -f $marker
        $line = $prefix + (Format-ARLeader -Label ('{0,-12} :' -f $field.Label) -Right $value -Width ($contentWidth - $prefix.Length) -Fill ' ')
        if ($i -eq $Index) {
            Write-ARBoxLine $line $boxWidth 'Black' 'Cyan'
        }
        else {
            Write-ARBoxLine $line $boxWidth 'White'
        }
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    Write-ARBoxLine (' Status: ' + [string]$script:ARStatus['Text']) $boxWidth (Get-ARStatusColor)
    Write-ARBoxLine ' Up/Down move   Enter edit   P profiles   S save   Esc cancel' $boxWidth 'DarkGray'
    Write-ARBoxBorder $boxWidth
}

function Read-ARLineValue {
    param([string]$Prompt)
    $restoreHidden = $script:ARTuiFrameActive
    if ($restoreHidden) { try { [Console]::CursorVisible = $true } catch { } }
    Write-Host $Prompt -NoNewline -ForegroundColor Yellow
    try { return $Host.UI.ReadLine() }
    catch { return $null }
    finally {
        if ($restoreHidden) { try { [Console]::CursorVisible = $false } catch { } }
    }
}

function Read-ARSecretValue {
    param([string]$Prompt)
    $restoreHidden = $script:ARTuiFrameActive
    if ($restoreHidden) { try { [Console]::CursorVisible = $true } catch { } }
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
    finally {
        if ($restoreHidden) { try { [Console]::CursorVisible = $false } catch { } }
    }
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
                if ($character -eq 'S') { $null = Save-ARCurrentTarget }
                if ($character -eq 'P') { $null = Show-ARTargetPicker }
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
        $width = Get-ARConsoleWidth
        $boxWidth = [Math]::Max(40, $width - 1)
        Start-ARTuiFrame -Screen 'language'
        Write-ARBoxBorder $boxWidth
        Write-ARBoxColumns -Left 'Language' -Right $script:ARLocaleName -Width $boxWidth -Color 'Yellow'
        Write-ARBoxRule -Width $boxWidth -Label 'LANGUAGES' -Color 'DarkCyan'
        for ($i = 0; $i -lt $languages.Count; $i++) {
            $marker = if ($i -eq $index) { '>' } else { ' ' }
            $line = ' {0} {1,2}. {2}' -f $marker, ($i + 1), $languages[$i]
            if ($i -eq $index) { Write-ARBoxLine $line $boxWidth 'Black' 'Cyan' }
            else { Write-ARBoxLine $line $boxWidth 'White' }
        }
        Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
        Write-ARBoxLine ' Up/Down move   Enter select   Esc cancel' $boxWidth 'DarkGray'
        Write-ARBoxBorder $boxWidth
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
                Set-ARLastLanguage $languages[$index]
                return $languages[$index]
            }
            'Escape' { return '' }
            default {
                $character = $key.KeyChar.ToString().ToUpperInvariant()
                if ($character -eq 'Q') { return '' }
                if ($character -match '^[1-7]$') {
                    $languageIndex = [int]::Parse($character) - 1
                    $script:ARLocaleName = $languages[$languageIndex]
                    Set-ARLastLanguage $languages[$languageIndex]
                    return $languages[$languageIndex]
                }
            }
        }
    }
}

function Show-ARTui {
    param([string]$InitialId = '')

    if (-not [string]::IsNullOrWhiteSpace($InitialId)) {
        $action = Get-ARActionById $InitialId
        if ($null -ne $action) {
            $script:ARSelectedId = $action.Id
            $script:ARTuiLevel = 'actions'
        }
    }
    $script:ARScroll = 0
    $script:ARCategoryScroll = 0
    if (-not $script:ARTestMode) {
        try { [Console]::CursorVisible = $false } catch { }
    }
    try {
        while ($true) {
            Show-ARTuiScreen
            if ($script:ARTestMode) { return 'TEST' }
            $key = $null
            if ($null -ne $script:ARPendingKey) {
                $key = $script:ARPendingKey
                $script:ARPendingKey = $null
            }
            else {
                try { $key = [Console]::ReadKey($true) } catch { return 'QUIT' }
            }
            if ($null -eq $key) { continue }

            if ($key.Key -eq 'UpArrow') {
                Move-ARTuiSelection -Delta -1
                continue
            }
            if ($key.Key -eq 'DownArrow') {
                Move-ARTuiSelection -Delta 1
                continue
            }
            if ($key.Key -eq 'PageUp') {
                Move-ARTuiSelection -Delta -1 -Page
                continue
            }
            if ($key.Key -eq 'PageDown') {
                Move-ARTuiSelection -Delta 1 -Page
                continue
            }
            if ($key.Key -eq 'Home') {
                Set-ARTuiSelectionEdge
                continue
            }
            if ($key.Key -eq 'End') {
                Set-ARTuiSelectionEdge -Last
                continue
            }
            if ($key.Key -eq 'RightArrow') {
                if ($script:ARTuiLevel -eq 'categories') {
                    $category = Get-ARCurrentCategory
                    if ($null -ne $category) { Enter-ARTuiCategory -Key $category.Key }
                }
                continue
            }
            if ($key.Key -eq 'LeftArrow') {
                Step-ARTuiBack
                continue
            }
            if ($key.Key -eq 'Enter') {
                if ($script:ARTuiLevel -eq 'categories') {
                    $category = Get-ARCurrentCategory
                    if ($null -ne $category) { Enter-ARTuiCategory -Key $category.Key }
                    continue
                }
                $action = Get-ARCurrentAction
                if ($null -ne $action) {
                    $script:ARSelectedId = $action.Id
                    return ('ACTION:' + $action.Id)
                }
                Set-ARStatus (Get-ARText 'txt150' 'No item matches the current filter') 'Warn'
                continue
            }
            if ($key.Key -eq 'Escape' -or $key.Key -eq 'Backspace') {
                Step-ARTuiBack
                continue
            }
            if ($key.Key -eq 'F1') {
                Show-ARHelp -Level $script:ARTuiLevel -CategoryTitle (Get-ARCategoryLabel)
                continue
            }

            $character = $key.KeyChar.ToString().ToUpperInvariant()
            if ($character -eq 'Q' -or $character -eq 'X') { return 'QUIT' }
            if ($character -eq 'L') { return 'LANGUAGE' }
            if ($character -eq 'T') {
                if (Show-ARTargetForm) { Set-ARStatus 'Target updated' 'Ok' }
                continue
            }
            if ($character -eq 'P') { $null = Show-ARTargetPicker; continue }
            if ($character -eq 'S') { $null = Save-ARCurrentTarget; continue }
            if ($character -eq 'R') {
                if ($script:ARFilter -ne '') {
                    $script:ARFilter = ''
                    Set-ARStatus (Get-ARText 'txt154' 'Filter cleared') 'Info'
                }
                continue
            }
            if ($character -eq '/') {
                $previous = $script:ARFilter
                $maxLength = [Math]::Max(8, (Get-ARConsoleWidth) - 24)
                Show-ARTuiScreen -Prompt 'filter'
                $typed = Read-ARTuiInlineInput -Row $script:ARTuiPromptRow -Column 10 -Initial $previous -MaxLength $maxLength -OnChange {
                    param($value)
                    $script:ARFilter = [string]$value
                    Show-ARTuiScreen -Prompt 'filter'
                }
                if ($null -eq $typed) {
                    $script:ARFilter = $previous
                    Set-ARStatus (Get-ARText 'txt153' 'Filter cancelled') 'Info'
                }
                else {
                    $script:ARFilter = [string]$typed
                    if ($script:ARFilter -eq '') {
                        Set-ARStatus (Get-ARText 'txt154' 'Filter cleared') 'Info'
                    }
                    else {
                        Set-ARStatus ((Get-ARText 'txt152' 'Filter applied') + ': ' + $script:ARFilter) 'Info'
                    }
                }
                continue
            }
            if ($key.KeyChar -match '^\d$') {
                $digits = Read-ARTuiNumberInput -FirstDigit $key.KeyChar.ToString()
                if (-not (Resolve-ARTuiNumber -Digits $digits)) {
                    Set-ARStatus ((Get-ARText 'txt6' 'Incorrect option, try again') + ': ' + $digits) 'Warn'
                }
                continue
            }
        }
    }
    finally {
        Stop-ARTuiFrame
    }
}

function Show-ARLineCategoryList {
    param([int]$Width = 79)
    $boxWidth = [Math]::Max(40, $Width)
    $categories = @(Get-ARActionCategories)
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left ('AutoRDPwn v' + (Get-ARVersionLabel) + ' - line mode') -Right $script:ARLocaleName -Width $boxWidth -Color 'Yellow'
    Write-ARBoxLine ('Target: {0}  User: {1}  Mode: {2}  Session: {3}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode'], $script:ARSessionState) $boxWidth 'Gray'
    Write-ARBoxRule -Width $boxWidth -Label 'CATEGORIES' -Color 'DarkCyan'
    for ($index = 0; $index -lt $categories.Count; $index++) {
        $category = $categories[$index]
        $count = Format-ARItemCount -Count $category.Actions.Count -Plural (Get-ARText 'txt146' 'actions')
        $prefix = ' {0,2}. ' -f ($index + 1)
        $line = $prefix + (Format-ARLeader -Label ([string]$category.Title) -Right $count -Width ($boxWidth - 4 - $prefix.Length))
        Write-ARBoxLine $line $boxWidth 'White'
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    Write-ARBoxLine (' Status: ' + [string]$script:ARStatus['Text']) $boxWidth (Get-ARStatusColor)
    Write-ARBoxLine ' [digits] category   [L] language   [T] target   [P] profiles   [S] save   [Q] quit' $boxWidth 'DarkGray'
    Write-ARBoxBorder $boxWidth
}

function Show-ARLineActionList {
    param($Category, [int]$Width = 79)
    $boxWidth = [Math]::Max(40, $Width)
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left ('AutoRDPwn > ' + [string]$Category.Title) -Right $script:ARLocaleName -Width $boxWidth -Color 'Yellow'
    Write-ARBoxLine ('Target: {0}  User: {1}  Mode: {2}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode']) $boxWidth 'Gray'
    Write-ARBoxRule -Width $boxWidth -Label 'ACTIONS' -Color 'DarkCyan'
    $actions = @($Category.Actions)
    for ($index = 0; $index -lt $actions.Count; $index++) {
        $action = $actions[$index]
        Write-ARBoxLine (' {0,2}. [{1,3}] {2}' -f ($index + 1), [string]$action.Id, [string]$action.Title) $boxWidth 'White'
        Write-ARBoxLine ('      ' + [string]$action.Description) $boxWidth 'DarkGray'
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    Write-ARBoxLine (' Status: ' + [string]$script:ARStatus['Text']) $boxWidth (Get-ARStatusColor)
    Write-ARBoxLine ' [number] run   [B] back   [L] language   [T] target   [P] profiles   [S] save   [Q] quit' $boxWidth 'DarkGray'
    Write-ARBoxBorder $boxWidth
}

function Show-ARLineCatalogDump {
    param([int]$Width = 79)
    $boxWidth = [Math]::Max(40, $Width)
    $categories = @(Get-ARActionCategories)
    Write-ARBoxBorder $boxWidth
    Write-ARBoxColumns -Left ('AutoRDPwn v' + (Get-ARVersionLabel) + ' - line mode') -Right $script:ARLocaleName -Width $boxWidth -Color 'Yellow'
    Write-ARBoxLine ('Target: {0}  User: {1}  Mode: {2}  Session: {3}' -f $script:ARTarget['Computer'], (Get-ARTargetUserLabel), $script:ARTarget['Mode'], $script:ARSessionState) $boxWidth 'Gray'
    foreach ($category in $categories) {
        Write-ARBoxRule -Width $boxWidth -Label ([string]$category.Title).ToUpperInvariant() -Color 'DarkCyan'
        foreach ($action in $category.Actions) {
            Write-ARBoxLine (' [{0,3}] {1}' -f [string]$action.Id, [string]$action.Title) $boxWidth 'White'
            Write-ARBoxLine ('       ' + [string]$action.Description) $boxWidth 'DarkGray'
        }
    }
    Write-ARBoxRule -Width $boxWidth -Label '' -Color 'DarkCyan'
    $footer = Get-ARText 'txt162' '[L] language  [T] target  [P] profiles  [S] save target  [Q] quit'
    Write-ARBoxLine (' ' + $footer) $boxWidth 'DarkGray'
    Write-ARBoxBorder $boxWidth
}

function Show-ARLineMenu {
    $width = Get-ARConsoleWidth
    $inner = [Math]::Max(40, $width - 1)
    if ($script:ARTestMode) {
        Show-ARLineCatalogDump -Width $inner
        return ''
    }
    $category = Get-ARCategoryByKey $script:ARLineCategoryKey
    while ($true) {
        Clear-ARScreen
        if ($null -eq $category) {
            Show-ARLineCategoryList -Width $inner
            $answer = Read-ARLineValue ' Choose a category:'
            if ($null -eq $answer) { return 'QUIT' }
            $value = $answer.Trim()
            if ($value -eq '') { continue }
            if ($value -match '^\d+$') {
                $categories = @(Get-ARActionCategories)
                $index = 0
                if ([int]::TryParse($value, [ref]$index)) {
                    $index = $index - 1
                    if ($index -ge 0 -and $index -lt $categories.Count) {
                        $category = $categories[$index]
                        $script:ARLineCategoryKey = $category.Key
                        continue
                    }
                }
            }
            $code = Resolve-ARSelection $value
            if ($code -in @('QUIT', 'TARGET', 'PROFILES', 'SAVE', 'LANGUAGE')) { return $code }
            if ($code -like 'ACTION:*') { return $code }
            Set-ARStatus ((Get-ARText 'txt6' 'Incorrect option, try again') + ': ' + $value) 'Warn'
            continue
        }

        Show-ARLineActionList -Category $category -Width $inner
        $answer = Read-ARLineValue ' Choose an action:'
        if ($null -eq $answer) { return 'QUIT' }
        $value = $answer.Trim()
        if ($value -eq '') { continue }
        $upper = $value.ToUpperInvariant()
        if ($upper -in @('B', 'BACK', '..')) {
            $category = $null
            $script:ARLineCategoryKey = ''
            continue
        }
        if ($value -match '^\d+$') {
            $actions = @($category.Actions)
            $index = 0
            if ([int]::TryParse($value, [ref]$index)) {
                $index = $index - 1
                if ($index -ge 0 -and $index -lt $actions.Count) {
                    $script:ARLineCategoryKey = $category.Key
                    return ('ACTION:' + $actions[$index].Id)
                }
            }
        }
        $code = Resolve-ARSelection $value
        if ($code -in @('QUIT', 'TARGET', 'PROFILES', 'SAVE', 'LANGUAGE')) { return $code }
        if ($code -like 'ACTION:*') {
            $script:ARLineCategoryKey = $category.Key
            return $code
        }
        Set-ARStatus ((Get-ARText 'txt6' 'Incorrect option, try again') + ': ' + $value) 'Warn'
    }
}

function Show-ARLineTargetForm {
    Clear-ARScreen
    Write-ARLine 'Target editor (line mode)' 'Yellow'
    Read-ARLineTargetForm
    Set-ARStatus 'Target updated' 'Ok'
}

function Show-ARLineTargetPicker {
    $profiles = @(Get-ARTargetProfiles)
    if ($profiles.Count -eq 0) {
        Write-ARWarn (Get-ARText 'txt132' 'No saved targets. Edit a target and press S to save it.')
        return $false
    }
    Clear-ARScreen
    Write-ARLine (Get-ARText 'txt136' 'Saved target profiles') 'Yellow'
    Write-ARLine ('-' * ((Get-ARConsoleWidth) - 1)) 'DarkGray'
    for ($index = 0; $index -lt $profiles.Count; $index++) {
        $profile = $profiles[$index]
        $name = [string]$profile.Name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = '(unnamed)' }
        Write-ARLine (' {0}. {1}  [{2}]' -f ($index + 1), $name, $profile.Computer) 'Gray'
    }
    Write-ARLine ('-' * ((Get-ARConsoleWidth) - 1)) 'DarkGray'
    $choice = Read-ARValue ('Target profile (1-' + $profiles.Count + ')') '1'
    $selectedIndex = 0
    if (-not [int]::TryParse($choice, [ref]$selectedIndex)) {
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
        return $false
    }
    $selectedIndex = $selectedIndex - 1
    if ($selectedIndex -lt 0 -or $selectedIndex -ge $profiles.Count) {
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
        return $false
    }
    $null = Apply-ARTargetProfile $profiles[$selectedIndex]
    Set-ARStatus ((Get-ARText 'txt134' 'Target loaded') + ': ' + [string]$profiles[$selectedIndex].Name) 'Ok'
    return $true
}
