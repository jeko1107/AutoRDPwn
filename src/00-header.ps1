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
