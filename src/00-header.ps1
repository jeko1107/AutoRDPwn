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
