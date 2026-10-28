# AutoRDPwn 6.0

AutoRDPwn is a PowerShell post-exploitation framework for Windows. It automates
the Shadow attack — a SYSTEM scheduled task that opens a console session on the
remote host — and puts 88 actions behind one menu: remote execution, shells,
credential extraction, pivoting, lateral movement, desktop forensics,
persistence, collection and privilege escalation.

v6.0 replaces the old screen path: the target runs a JPEG frame server in the
console session and the operator pulls frames over HTTP. No VNC DLL is injected
on the target and the target never dials back.

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

## What 6.0 adds

- **Shadow session engine** behind every remote-execution action: registry values
  are recorded before they are written and replayed by cleanup.
- **Quick Screen** — a pull-based JPEG frame server in the target console session,
  `control` or `view` mode, no injected DLL and no dial-back.
- **Loot pulled, not left behind** — action 205 dumps LSASS with `comsvcs.dll`,
  206 saves the SAM/SYSTEM/SECURITY hives with `reg save`, 901 zips a folder; all
  three pull the file back to `%LOCALAPPDATA%\AutoRDPwn\loot\` and delete the
  remote copy.
- **Cleanup that knows what it touched** — tasks, temp directories, created
  accounts, `sethc`/`Utilman` debugger values, firewall rules, Defender
  exclusions, registry backups, MSI product codes, operator port proxies and
  `cmdkey` entries.
- **Restore-aware changes**: 801 enables RDP and 802 adds Defender exclusions
  while recording the previous state, so a run leaves the target as it was found.
- **Two interfaces** — full-screen TUI and a numbered line mode for redirected
  consoles — with seven languages, saved target profiles, inline filter,
  favourites and contextual help.
- **Decisions that fail loudly**: `-option` is non-interactive and exits `1`
  instead of prompting, an unknown id is an error, and a missing value names the
  field it needed.

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

`Build.ps1` concatenates `src\01-core.ps1` through `src\03-main.ps1`, parses
every part and refuses to write output that does not parse.

Three ways in:

```powershell
# 1. interactive
.\AutoRDPwn.ps1 -lang en

# 2. one action, no menu, profile already saved with S
.\AutoRDPwn.ps1 -option 205

# 3. screen route in read-only mode
.\AutoRDPwn.ps1 -option 8 -shadow view
```

The process exits `0` on success and `1` when the action throws, the option is
unknown, `-option` is empty, or an unrecognised argument is passed. See
[`docs/CLI.md`](docs/CLI.md).

## Menu

The TUI has two levels — categories, then the actions inside one — with a
breadcrumb and a status line for target, mode and session. Arrows and Enter move
and run; digits pick a category or an action; `/` filters, `R` clears the filter;
`F` pins an action to the top of its category; `Esc`/`B` goes back a level. `T`
edits the target, `P` loads a profile, `S` saves it, `L` changes language, `F1`
opens contextual help, `Q` or `X` quits.

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
| 801 | Remote Access | Enable RDP |
| 201 | Passwords and hashes | Extract local hashes with Mimikatz |
| 202 | Passwords and hashes | Extract system passwords with Mimikatz |
| 203 | Passwords and hashes | Obtain browsers passwords with SharpWeb |
| 204 | Passwords and hashes | Recover Wi-Fi passwords |
| 205 | Passwords and hashes | Lsass dump |
| 206 | Passwords and hashes | Sam dump |
| 220 | Passwords and hashes | WDigest plaintext logon |
| 221 | Passwords and hashes | Credential Manager vault |
| 222 | Passwords and hashes | Browser saved passwords |
| 223 | Passwords and hashes | Wi-Fi keys in clear |
| 224 | Passwords and hashes | DPAPI master keys |
| 225 | Passwords and hashes | LSA secrets (SECURITY hive) |
| 226 | Passwords and hashes | SSH private keys |
| 227 | Passwords and hashes | Kerberos ticket cache |
| 228 | Passwords and hashes | Token privileges |
| 229 | Passwords and hashes | Cached domain logons |
| 301 | Networking / Pivoting | TCP Port Scan |
| 302 | Networking / Pivoting | Native Port Forwarding |
| 303 | Networking / Pivoting | PowerShell Web Server |
| 304 | Networking / Pivoting | Network Creds Scanner |
| 207 | Networking / Pivoting | Credential spray |
| 901 | Networking / Pivoting | File exfiltration |
| 620 | Lateral movement | Pivot proxy |
| 621 | Lateral movement | SOCKS over WinRM |
| 622 | Lateral movement | Remote share mount |
| 623 | Lateral movement | PsExec hop |
| 624 | Lateral movement | WinRM hop |
| 320 | Discovery | Host audit |
| 321 | Discovery | AV and EDR enumeration |
| 322 | Discovery | SMB shares |
| 323 | Discovery | Local administrators |
| 324 | Discovery | Installed software |
| 325 | Discovery | Scheduled tasks |
| 326 | Discovery | Services |
| 327 | Discovery | Autoruns |
| 328 | Discovery | Domain information |
| 329 | Discovery | Network configuration |
| 330 | Discovery | ARP and connections |
| 331 | Discovery | SMB audit |
| 332 | Discovery | Patch audit |
| 401 | Remote Desktop Forensics | Rebuild the image cache |
| 402 | Remote Desktop Forensics | List local users and groups |
| 403 | Remote Desktop Forensics | Extract session credentials (SessionGopher) |
| 804 | Remote Desktop Forensics | Shadow copies |
| 902 | Remote Desktop Forensics | Screenshot loop |
| 903 | Remote Desktop Forensics | Clipboard watch |
| 501 | Backdoors and persistence | Sticky Keys Hacking |
| 502 | Backdoors and persistence | Metasploit Reverse Shell |
| 503 | Backdoors and persistence | Remote Keylogger |
| 904 | Backdoors and persistence | Fast keylogger |
| 504 | Backdoors and persistence | Persistence kit |
| 520 | Backdoors and persistence | Startup shortcut |
| 521 | Backdoors and persistence | SSH authorized_keys |
| 522 | Backdoors and persistence | Service persistence |
| 523 | Backdoors and persistence | Boot task |
| 524 | Backdoors and persistence | WMI subscription |
| 601 | Privilege escalation | Get operating system information |
| 602 | Privilege escalation | Search vulnerabilities with Sherlock |
| 603 | Privilege escalation | Privilege escalation audit |
| 420 | Privilege escalation | AlwaysInstallElevated |
| 421 | Privilege escalation | Unquoted service paths |
| 422 | Privilege escalation | Service permissions |
| 423 | Privilege escalation | Potato check |
| 424 | Privilege escalation | UAC bypass (fodhelper) |
| 425 | Privilege escalation | Run as SYSTEM (task) |
| 426 | Privilege escalation | Run as SYSTEM (service) |
| 427 | Privilege escalation | Backdoor account |
| 701 | Other modules | Deactivate system logs |
| 805 | Other modules | Event log clear |
| 802 | Other modules | Defender exclusions |
| 803 | Other modules | AMSI bypass |
| 702 | Other modules | Remote VNC Server (legacy) |
| 703 | Other modules | External script execution |
| 704 | Other modules | Change user with RunAs |

Per-action inputs, what each one leaves on the target and how it is cleaned up:
[`docs/MODULES.md`](docs/MODULES.md).

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
interrupted run. Details in [`docs/SCREEN.md`](docs/SCREEN.md).

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
| `-createuser` | add the `Pwn5` payload, which creates `AutoRDPwn:AutoRDPwn` on the target |
| `-noclean` | keep target-side artifacts; operator-side traces are still removed |
| `-Yes` | assume yes for the 804 and 805 confirmations |
| `-Target` | target computer; applied after the saved profile, so it overrides it |
| `-User` | target account |
| `-Password` | target password in plain text |
| `-Mode` | `view` or `control` for the screen session |
| `-Config` | JSON file with `Target`, `User`, `Password`, `Mode` and `Language` |
| `-List` | print the action catalog as a table and exit `0` |
| `-ListJson` | print the action catalog as JSON and exit `0` |

`-option` is non-interactive: `Read-ARValue` and `Read-ARSecret` throw instead of
prompting, so every value an action needs must already be in the loaded profile.
The default target is `localhost`. [`docs/CLI.md`](docs/CLI.md) lists every
switch, the values `-shadow` accepts and the exit codes.

## Profiles and language

`P` loads a saved target and `S` saves the current one. Profiles live in
`Resources\Tools\targets.json`; the last one used is remembered in `last.json`
beside it, together with the language and the favourites, and loaded at startup.
A profile stores host, user, domain, attacker IP, NTLM hash and screen mode.
Passwords and NTLM hashes are protected with DPAPI
(`ConvertFrom-SecureString`), so a profile only decrypts for the Windows account
that wrote it.

Without `-lang`, the interface follows the operator's culture and falls back to
English. `L` changes it from the menu.

## Documentation

| document | contents |
| --- | --- |
| [`docs/USAGE.md`](docs/USAGE.md) | interface, keys, filters, favourites, profiles, languages, line mode |
| [`docs/MODULES.md`](docs/MODULES.md) | every action: inputs, what it runs, what it leaves, how it is cleaned |
| [`docs/SCREEN.md`](docs/SCREEN.md) | the frame server, the viewer, modes, ports and teardown |
| [`docs/CLI.md`](docs/CLI.md) | switches, `-option` semantics, exit codes, examples |
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | source parts, build, state, cleanup model, adding an action |
| [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) | failures seen in practice, with the command that fixes each one |

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

Original work Copyright (C) Joel Gámez Molina. Fork and v6.0 rewrite
Copyright (C) jeko. The GPL-3.0 licence and the original copyright notice are
kept as they were.
