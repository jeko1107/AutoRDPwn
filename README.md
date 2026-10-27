# AutoRDPwn 6.0

AutoRDPwn is a PowerShell post-exploitation framework for Windows. It automates
the Shadow attack — a SYSTEM scheduled task that opens a console session on the
remote host — and puts 34 actions behind one menu: remote execution, shells,
credential extraction, pivoting, desktop forensics, persistence and privilege
escalation. Version 6.0 replaces the old screen path: the target runs a JPEG
frame server in the console session and the operator pulls frames over HTTP. No
VNC DLL is injected on the target and the target never dials back.

This repository is a fork of [AutoRDPwn](https://github.com/JoelGMSec/AutoRDPwn)
by Joel Gámez Molina.

## Author

- Fork, v5.x modules and v6.0 rewrite: **jeko** ([jeko1107](https://github.com/jeko1107))
- Original framework: **Joel Gámez Molina** ([@JoelGMSec](https://github.com/JoelGMSec))

## Requirements

Operator: Windows with Windows PowerShell 5.1 or PowerShell 7+, administrator
rights, and the `Resources\` folder beside `AutoRDPwn.ps1`. A missing resource is
a hard error; set `AUTORD_PWN_ALLOW_DOWNLOAD=1` to fetch it from the repository.
Started unelevated, the launcher raises a UAC prompt and forwards its arguments;
`-noadmin` keeps the current console instead.

Target: Windows with PowerShell 5.1 and WinRM enabled, plus a local administrator
account. Inbound TCP 445 for PSexec, 135 for WMI, 5985 for WinRM, WinRS and Quick
Screen, and 3389 for the RDP actions. Quick Screen also needs 8081 while it runs;
the module creates that firewall rule before the listener opens and deletes it
during teardown.

## Quick start

```powershell
git clone https://github.com/jeko1107/AutoRDPwn
cd AutoRDPwn
.\AutoRDPwn.ps1
```

`AutoRDPwn.ps1` is generated from `src\`. Rebuild it after editing a source part:

```powershell
.\Build.ps1                              # writes AutoRDPwn.ps1
.\Build.ps1 -OutputPath _sandbox\gen.ps1 # scratch build for tests
```

`Build.ps1` concatenates `src\00-header.ps1` through `src\50-main.ps1`, parses
every part and refuses to write output that does not parse. Run one action
without the menu with `.\AutoRDPwn.ps1 -option 8 -shadow view`. The process exits
`0` on success and `1` when the action throws, the option is unknown, `-option`
is empty, or an unrecognised argument is passed.

## Menu

The TUI has two levels — categories, then the actions inside one — with a
breadcrumb and a status line for target, mode and session. Arrows and Enter move
and run; digits pick a category or an action; `/` filters and Esc clears the
filter or goes back a level. `T` edits the target, `P` loads a profile, `S` saves
it, `L` changes language, `F1` opens contextual help, `Q` or `X` quits.

Category 1 is the quick-action list; the rest are grouped.

| id | category | action |
| --- | --- | --- |
| 1 | Quick actions | PSexec (SMB) |
| 2 | Quick actions | Pass the Hash (SMB) |
| 3 | Quick actions | Windows Management Instrumentation (WMI) |
| 4 | Quick actions | Windows Remote Management (WinRM) |
| 5 | Quick actions | Windows Remote Assistance (WinRS) |
| 6 | Quick actions | Local Session Hijacking (TSCon) |
| 7 | Quick actions | Remote Desktop Execution (RDP) |
| 8 | Quick actions | Quick Screen (Stealth VNC) |
| 101 | Remote Access | Named Pipe Remote Shell (SMB) |
| 102 | Remote Access | Semi-interactive console (WinRS) |
| 103 | Remote Access | PowerShell HTTP-RevShell (HTTP/S) |
| 104 | Remote Access | Netcat console (direct connection) |
| 105 | Remote Access | Netcat console (reverse connection) |
| 201 | Passwords and hashes | Extract local hashes with Mimikatz |
| 202 | Passwords and hashes | Extract system passwords with Mimikatz |
| 203 | Passwords and hashes | Obtain browsers passwords with SharpWeb |
| 204 | Passwords and hashes | Recover Wi-Fi passwords |
| 301 | Networking / Pivoting | TCP Port Scan |
| 302 | Networking / Pivoting | Native Port Forwarding |
| 303 | Networking / Pivoting | PowerShell Web Server |
| 304 | Networking / Pivoting | Network Creds Scanner |
| 401 | Remote Desktop Forensics | Rebuild the image cache |
| 402 | Remote Desktop Forensics | List local users and groups |
| 403 | Remote Desktop Forensics | Extract session credentials (SessionGopher) |
| 501 | Backdoors and persistence | Sticky Keys Hacking |
| 502 | Backdoors and persistence | Metasploit Reverse Shell |
| 503 | Backdoors and persistence | Remote Keylogger |
| 601 | Privilege escalation | Get operating system information |
| 602 | Privilege escalation | Search vulnerabilities with Sherlock |
| 603 | Privilege escalation | Privilege escalation audit |
| 701 | Other modules | Deactivate system logs |
| 702 | Other modules | Remote VNC Server (legacy) |
| 703 | Other modules | External script execution |
| 704 | Other modules | Change user with RunAs |

## Screen viewing (option 8)

Quick Screen needs a target host, a local administrator account and a mode:
`view` watches the console without forwarding input, `control` forwards keyboard
and mouse. The module's own `-Mode shot` captures one full-resolution PNG and
pulls it back over WinRM; the menu always uses the live view.

1. WinRM (5985) is checked first. A scheduled task registered as SYSTEM, and
   removed right after it starts, launches the frame server in the interactive
   session.
2. The frame server captures that desktop, encodes JPEG frames at quality 55 with
   a 200 ms interval, and answers on TCP 8081.
3. The operator's WinForms viewer pulls the frames. Esc closes it.

The firewall rule `AutoRDPwn Frame 8081` is created before the listener opens, so
Windows raises no prompt on the target. Teardown removes the task, staged script,
stop file, rule and server process in a `finally` block, including after an
interrupted run.

## Line mode and automation

The line interface runs when `-nogui` is passed or stdin is redirected, which is
the case inside a reverse shell. It asks for a category number, then an action
number; `B` in the action list goes back to the categories.

```powershell
.\AutoRDPwn.ps1 -nogui -lang English -option 4 -shadow control -createuser
```

| switch | effect |
| --- | --- |
| `-noadmin` | stay in the current console, no elevation |
| `-nogui` | line menu instead of the TUI |
| `-lang` | English, Spanish, French, German, Italian, Russian or Portuguese |
| `-option` | action id to run directly; legacy aliases `11`-`17` map to `101`, `201` ... `701` |
| `-shadow` | `view` or `control` for the screen session |
| `-createuser` | create `AutoRDPwn:AutoRDPwn` on the target for the shadow session |
| `-noclean` | keep target-side artifacts; operator-side traces are still removed |

`-option` is non-interactive: `Read-ARValue` and `Read-ARSecret` throw instead of
prompting, so every value an action needs must already be in the loaded profile.
The default target is `localhost`.

## Profiles and language

`P` loads a saved target and `S` saves the current one. Profiles live in
`Resources\Tools\targets.json`; the last one used is remembered in `last.json`
beside it and loaded at startup. A profile stores host, user, domain, attacker IP
and screen mode. Passwords and NTLM hashes are protected with DPAPI
(`ConvertFrom-SecureString`), so a profile only decrypts for the Windows account
that wrote it.

Without `-lang`, the interface follows the operator's culture and falls back to
English. `L` changes it from the menu.

## Tests

```powershell
.\Tests\Run-Tests.ps1
.\Tests\Run-Tests.ps1 -Filter 'Catalog*' -Detailed
.\Tests\Run-Tests.ps1 -NoBuild
```

The suite builds `src\` into `_sandbox\gen.ps1`, then runs offline checks: no
network, no elevation, no catalog action executed. Exit code `0` when nothing
failed, `1` otherwise. See [`Tests/README.md`](Tests/README.md) for the groups.

## License

GNU General Public License v3.0. See [LICENSE](LICENSE) for the full text.
