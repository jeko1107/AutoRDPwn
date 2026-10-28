# Modules

One section per catalog action, in catalog order, grouped by the category buckets
that `Get-ARActionCategories` builds from the catalog. There are 78 actions.

Unless a section says otherwise, an action needs a target in the target editor
and a working WinRM session (TCP 5985) to that target. "Leaves" lists what the
action puts on the target or the operator; "cleanup" is `Remove-ARTargetArtifacts`
and `Invoke-ARCleanup`, which run from the `finally` block on exit. Actions that
pull a file back write it under `%LOCALAPPDATA%\AutoRDPwn\loot\` on the operator
and delete the remote copy.

Actions 205 to 207, 220 to 229, 320 to 332, 420 to 427, 801 to 805, 901 to 904 and
504 are implemented in `src\02-actions.ps1`. Read the handler before scripting
against it.

## Quick actions

### 1. PSexec (SMB)
- Needs: TCP 445 on the target, optional user and password; no open session.
- Runs: extracts `psexec.exe`, starts each payload hidden, then opens the session and runs the shadow engine.
- Leaves: `psexec.exe` in `Resources\Tools`, the RDPWrap MSI on workstations, registry writes, a `cmdkey` entry and the `RDP session agent` firewall rule; cleanup removes all of them.

### 2. Pass the Hash (SMB)
- Needs: target user and NTLM hash; TCP 445.
- Runs: SMBExec starts the payloads, creates a temporary local administrator `ARDP_<8 hex>` with password `AutoRDPwn`, then runs the shadow engine as that account.
- Leaves: the temporary account and its profile directory; cleanup deletes the account with `net user /delete` and removes `C:\Users\<account>`.

### 3. Windows Management Instrumentation (WMI)
- Needs: TCP 135, credentials for the target.
- Runs: creates the payload process through `Win32_Process.Create` over CIM, then runs the shadow engine.
- Leaves: the payload process and the shadow-engine artifacts covered under action 1; no WMI subscription is created.

### 4. Windows Remote Management (WinRM)
- Needs: TCP 5985, credentials.
- Runs: runs each payload in a hidden `powershell.exe` through `Invoke-Command`, then runs the shadow engine.
- Leaves: the payload processes and the shadow-engine artifacts; cleanup has no separate WMI or WinRM registration to remove.

### 5. Windows Remote Assistance (WinRS)
- Needs: TCP 5985, credentials.
- Runs: starts each payload with `winrs.exe /r:<target>` and then runs the shadow engine.
- Leaves: the payload processes and the shadow-engine artifacts.

### 6. Local Session Hijacking (TSCon)
- Needs: local target only, administrator rights; no remote session.
- Runs: displays `query session`, registers a SYSTEM scheduled task that runs `tscon.exe <session>`, starts it and unregisters the task in a `finally`.
- Leaves: no task; the console is attached to the chosen session.

### 7. Remote Desktop Execution (RDP)
- Needs: TCP 3389, credentials, `Resources\Scripts\Invoke-SharpRDP.ps1`.
- Runs: extracts `SharpRDP.exe`, starts each payload with `computername`, `username`, `password` and `command`, then runs the shadow engine.
- Leaves: `SharpRDP.exe` in `Resources\Tools` and the shadow-engine artifacts; both are covered by cleanup.

### 8. Quick Screen (Stealth VNC)
- Needs: TCP 5985 and 8081, a target user and password; no pre-existing session.
- Runs: stages a JPEG frame server as a scheduled task in the console session and opens the pull viewer described in `docs\SCREEN.md`.
- Leaves: task `W<8 hex>`, `C:\Windows\Temp\W<8 hex>.ps1` and `.stop`, the `AutoRDPwn Frame 8081` rule and a hidden `powershell.exe`; the module's `finally` removes all of them.

## Remote Access

### 101. Named Pipe Remote Shell (SMB)
- Needs: TCP 445 and a session.
- Runs: copies `Invoke-PipeShell.ps1` to `C:\Windows\Temp\AutoRDPwnPipe_<guid>`, starts the server as a background job on the target and connects the client over the `NamedPipeStream` pipe.
- Leaves: the temporary directory and an `AutoRDPwn_*` job; both are removed by cleanup.

### 102. Semi-interactive console (WinRS)
- Needs: TCP 5985 and credentials.
- Runs: opens `winrs.exe` against the target with `cmd.exe`, forwarding user and password when they are set.
- Leaves: nothing on disk; the console ends when `exit` is typed.

### 103. PowerShell HTTP-RevShell (HTTP/S)
- Needs: attacker IP, a port (default 8080) and a session.
- Runs: loads the encoded reverse shell on the target as a job, extracts `server.exe` locally and runs the listener on the operator.
- Leaves: the target job and `server.exe` in `Resources\Tools`; cleanup stops the job and deletes the extracted file.

### 104. Netcat console (direct connection)
- Needs: a listen port and a session.
- Runs: copies `Invoke-PowerShellTcp.ps1` to a temporary directory, opens the firewall rule `Powershell Remote Control Application` for the port, starts a bind listener as a job and prints `nc <target> <port>`.
- Leaves: the rule, the temporary directory and the job; cleanup deletes the rule, the directory and the job.

### 105. Netcat console (reverse connection)
- Needs: attacker IP and a listen port.
- Runs: copies `Invoke-PowerShellTcp.ps1` to a temporary directory and starts a job that dials back after five seconds; the operator keeps a listener ready.
- Leaves: the temporary directory and the job; both are removed by cleanup.

### 801. Enable RDP
- Needs: administrator rights, a session, TCP 5985.
- Runs: snapshots and writes `fDenyTSConnections=0`, `LocalAccountTokenFilterPolicy=1` and `RDP-Tcp\UserAuthentication=0`; enables every disabled firewall rule attached to the `TermService` service, or, when none was enabled, enables or creates `AutoRDPwn-RDP-In` for TCP 3389.
- Leaves: the registry values replayed from the snapshot by cleanup, the created rule deleted by cleanup, and the rules it re-enabled set back to disabled through `$script:ARFirewallRestore`. Prints `Registry values were already in the required state.` and writes nothing when a fresh target already allows RDP.

## Passwords and hashes

### 201. Extract local hashes with Mimikatz
- Needs: administrator rights on the target and a session.
- Runs: copies `Invoke-Mimikatz.ps1` to a temporary directory and runs `privilege::debug token::elevate lsadump::sam exit`.
- Leaves: the temporary directory only; `Invoke-ARTargetPowerShell` removes it in a `finally` after the output is collected.

### 202. Extract system passwords with Mimikatz
- Needs: administrator rights and a session.
- Runs: same staging as 201 with `sekurlsa::logonPasswords`.
- Leaves: the temporary directory only, removed in the same `finally`.

### 203. Obtain browsers passwords with SharpWeb
- Needs: a session.
- Runs: extracts `SharpWeb.exe` locally, copies it to `C:\Windows\Temp\AutoRDPwn_<guid>` and runs `SharpWeb.exe all`.
- Leaves: `SharpWeb.exe` in `Resources\Tools`; the remote directory is removed in a `finally`.

### 204. Recover Wi-Fi passwords
- Needs: a session.
- Runs: `netsh wlan export profile key=clear` into `%TEMP%\wifi_<guid>` on the target, parses the XML and prints SSID and key.
- Leaves: nothing; the export directory is deleted in a `finally`.

### 205. Lsass dump
- Needs: an elevated remote session, TCP 5985.
- Runs: resolves the LSASS pid and starts `rundll32.exe comsvcs.dll, MiniDump #<pid> <path> full` hidden, waits up to 60 s for the dump, then pulls it to `%LOCALAPPDATA%\AutoRDPwn\loot\lsass\lsass-<target>-<yyyyMMdd-HHmmss>.dmp`.
- Leaves: nothing on the target - the `.dmp` is deleted in a `finally`. Throws when the session is not elevated, LSASS is missing, `rundll32` exits without a file, or the pull fails. Sizes are printed in MB.

### 206. Sam dump
- Needs: an elevated remote session, TCP 5985.
- Runs: `reg save HKLM\SAM`, `HKLM\SYSTEM` and `HKLM\SECURITY` into `C:\Windows\Temp\W<8 hex>\<HIVE>.hiv`, then pulls every hive that saved to `%LOCALAPPDATA%\AutoRDPwn\loot\sam\<target>-<yyyyMMdd-HHmmss>\`.
- Leaves: the remote directory, removed in a `finally`. A hive that `reg save` rejects is reported and skipped; the action only throws when all three fail. The local folder is the input for offline hash extraction.

### 220-229. Credential access pack

Ten actions that read credential material the target already holds. The "needs"
column is the catalog gate: all ten need a target in the target editor, and only
227 carries `-NeedsSession $true`.

| id | action | handler | what it needs |
| --- | --- | --- | --- |
| 220 | WDigest plaintext logon | `Invoke-ARAttackWdigest` | target; administrative token to write under `HKLM`, no session |
| 221 | Credential Manager vault | `Invoke-ARAttackVaultDump` | target; the logged-on user's own vault through `vaultcmd`, no session |
| 222 | Browser saved passwords | `Invoke-ARAttackBrowserCredentials` | target; the `Login Data` and `Local State` files of the installed browsers, no session |
| 223 | Wi-Fi keys in clear | `Invoke-ARAttackWifiKeys` | target; `netsh wlan export profile key=clear`, no session |
| 224 | DPAPI master keys | `Invoke-ARAttackDpapiMasterKeys` | target; administrative token for the machine keys, no session |
| 225 | LSA secrets (SECURITY hive) | `Invoke-ARAttackLsaSecrets` | target; administrative token to save the hives, no session |
| 226 | SSH private keys | `Invoke-ARAttackSshKeys` | target; the profile directories the account can read, no session |
| 227 | Kerberos ticket cache | `Invoke-ARAttackKerberosTickets` | target and a session; the LSA cache of the logged-on user |
| 228 | Token privileges | `Invoke-ARAttackTokenPrivileges` | target; `whoami /priv` as the running account, no session |
| 229 | Cached domain logons | `Invoke-ARAttackCachedLogons` | target; administrative token to read the `Winlogon` keys, no session |

- Runs: each handler collects the material on the target and either prints it or pulls an archive to `%LOCALAPPDATA%\AutoRDPwn\loot\`; decryption and parsing happen offline on the operator.
- Leaves: any remote working directory a handler creates is registered with the cleanup lists before use, so `Invoke-ARCleanup` removes it; read the handler for the exact path and for the registry or hive values it restores.
- Note: 220 is the only row that changes target state on purpose (it turns on plaintext WDigest caching) and the only one whose payoff appears at the next logon. 205, 206 and 225 overlap on purpose: 205 is a live minidump, 206 keeps the three hives, 225 keeps only `SECURITY` and `SYSTEM` for `secretsdump`.

### 320-332. Discovery pack

Thirteen read-only actions that inventory the target. The "needs" column is the
catalog gate: all thirteen need a target in the target editor and every one of
them carries `-NeedsSession $false`. Nothing in this pack writes to the target,
creates a file or leaves a task, so there is nothing for cleanup to remove; the
handler is where the exact fields of each row are defined.

| id | action | handler | what it needs |
| --- | --- | --- | --- |
| 320 | Host audit | `Invoke-ARModuleHostAudit` | target; read-only host baseline, no session |
| 321 | AV and EDR enumeration | `Invoke-ARModuleAvEnum` | target; read-only security-product inventory, no session |
| 322 | SMB shares | `Invoke-ARModuleShareEnum` | target; read-only share inventory, no session |
| 323 | Local administrators | `Invoke-ARModuleLocalAdmins` | target; read-only group membership, no session |
| 324 | Installed software | `Invoke-ARModuleSoftwareEnum` | target; read-only installed-program inventory, no session |
| 325 | Scheduled tasks | `Invoke-ARModuleTaskEnum` | target; read-only task inventory, no session |
| 326 | Services | `Invoke-ARModuleServiceEnum` | target; read-only service inventory, no session |
| 327 | Autoruns | `Invoke-ARModuleAutoruns` | target; read-only startup inventory, no session |
| 328 | Domain information | `Invoke-ARModuleDomainInfo` | target; read-only domain and policy query, no session |
| 329 | Network configuration | `Invoke-ARModuleNetworkConfig` | target; read-only adapter and route inventory, no session |
| 330 | ARP and connections | `Invoke-ARModuleArpTable` | target; read-only ARP cache and connection list, no session |
| 331 | SMB audit | `Invoke-ARModuleSmbAudit` | target; read-only SMB configuration audit, no session |
| 332 | Patch audit | `Invoke-ARModulePatchAudit` | target; read-only hotfix and update inventory, no session |

- Runs: each handler queries the target and prints the result on the operator; none of the thirteen changes a value, a service state or a permission.
- Leaves: nothing on the target and nothing under `%LOCALAPPDATA%\AutoRDPwn\loot\`.
- Note: `-NeedsSession $false` means the action does not require an interactive session, not that it skips the target: the row still needs a reachable host and the credential the rest of the catalog uses.

## Networking / Pivoting

### 301. TCP Port Scan
- Needs: no session; an IP or CIDR range (defaults to the target).
- Runs: prompts for speed 1 to 5 and a port count (default 100), then runs `Invoke-Portscan` locally with 10 to 200 threads.
- Leaves: nothing on the target.

### 302. Native Port Forwarding
- Needs: a session for the remote operations; administrator rights for the local ones.
- Runs: `netsh interface portproxy` with operation `1` local add, `2` remote add, `3` show or `4` reset.
- Leaves: local adds are recorded and deleted by `Reset-AROperatorPortProxies`; remote adds and resets are not recorded, so a remote proxy stays until it is reset on the target.

### 303. PowerShell Web Server
- Needs: a session; TCP 8080 on the target.
- Runs: copies `Start-WebServer.ps1`, creates the `Powershell Web Server` rule for TCP 8080, starts a job bound to `http://+:8080/` and opens the URL locally.
- Leaves: the rule, the temporary directory and the job; cleanup removes all three.

### 304. Network Creds Scanner
- Needs: no session; a CIDR range, a user and either a password or an NTLM hash.
- Runs: converts a password to NTLM when needed and runs `Check-LocalAdminHash` with the chosen SMB or WMI protocol and 20 threads.
- Leaves: nothing on the target.

### 207. Credential spray
- Needs: TCP 445 and 5985; no session for an explicit user list.
- Runs: asks for one password (hidden prompt) and a comma separated user list, or `*` to read every enabled local account through `Win32_UserAccount`. Each account gets exactly one `New-PSSession` with a 15 s open timeout and a 30 s operation timeout; a hit prints `<user> -> valid`, a miss `<user> -> failed`, and three failures in a row stop the spray before the target starts locking accounts.
- Leaves: no files. The password is held in a `SecureString`, never echoed and never logged; the closing status line counts the valid accounts.

### 901. File exfiltration
- Needs: a session; a folder path on the target.
- Runs: prompts for the folder, compresses `<folder>\*` into `C:\Windows\Temp\W<8 hex>.zip` with `Compress-Archive`, pulls it to `%LOCALAPPDATA%\AutoRDPwn\loot\exfil\<target>-<yyyyMMdd-HHmmss>.zip` and prints the entry count and size. A local target compresses straight into the loot folder with no staging copy. Handler: `Invoke-ARModuleFileExfil`.
- Leaves: nothing on the target - the remote zip is deleted in a `finally`, even when the pull failed. An empty path or a missing folder is reported and nothing is written; the local zip stays in the loot folder.

## Remote Desktop Forensics

### 401. Rebuild the image cache
- Needs: local target only; no remote session.
- Runs: runs `RDP-Caching.ps1` locally and writes recovered images to `%TEMP%\Recovered_RDP_Session`, then opens the folder.
- Leaves: the recovered folder; it is tracked and removed by cleanup, and interactive runs also offer to delete it immediately.

### 402. List local users and groups
- Needs: a session.
- Runs: copies `ListAllUsers.ps1` to a temporary directory and runs `ListAllUsers`.
- Leaves: nothing; the temporary directory is removed in a `finally`.

### 403. Extract session credentials (SessionGopher)
- Needs: a session.
- Runs: copies `SessionGopher.ps1` and runs `Invoke-SessionGopher -Thorough` for PuTTY, SuperPuTTY, FileZilla and WinSCP.
- Leaves: nothing; the temporary directory is removed in a `finally`.

### 804. Shadow copies
- Needs: an elevated remote session.
- Runs: lists `Win32_ShadowCopy` as a table. With confirmation, or with `-Yes`, it creates a `ClientAccessible` copy of `C:\` and exposes it with `mklink /d C:\Windows\Temp\W<8 hex> \\?\GLOBALROOT<device>` where `DeviceObject` lacks the prefix.
- Leaves: the link directory, recorded in `$script:ARRemoteTempDirs` and deleted by cleanup. The shadow copy itself is not deleted: it stays on the target until it ages out or is removed there. A failed `mklink` throws with the `cmd` output.

### 902. Screenshot loop
- Needs: a session on TCP 5985; target user and password for the console session.
- Runs: prompts for a frame count (default 10) and seconds between frames (default 5). Each frame calls `Invoke-StealthScreen -Mode shot`, which stages a one-shot capture task in the console session, pulls the PNG back and tears its task and staged script down before returning. Frames land as `frame-NNN.jpg` in `%LOCALAPPDATA%\AutoRDPwn\loot\shots\<target>-<yyyyMMdd-HHmmss>\`; Escape stops the loop between frames. Handler: `Invoke-ARModuleScreenshotLoop`.
- Leaves: nothing persistent on the target beyond the shot route's own task and script, both removed by that route before the next frame. Locally the capture folder holds the frames; an empty folder is deleted when the loop ends.

### 903. Clipboard watch
- Needs: a session and an interactive logged-on user; the task principal is `$script:ARTarget['User']`.
- Runs: copies a poller to `C:\Windows\Temp\W<8 hex>.ps1` and registers the `W<8 hex>` task with `Interactive` logon, highest run level, running hidden. The poller reads `Get-Clipboard -Raw` every 2 s, keeps a hash set of values it has already seen and appends each new value with a timestamp to `C:\Windows\Temp\W<8 hex>.txt`. The operator reads that log every N seconds (default 5), prints the new lines and stops on Escape. Handler: `Invoke-ARModuleClipboardWatch`.
- Leaves: the task, the script and the log; cleanup ends the task, kills the payload `powershell.exe` by matching its command line, unregisters the task and deletes both files, then drops the names from `$script:ARRemoteTasks` and `$script:ARModuleFiles`.

## Backdoors and persistence

### 501. Sticky Keys Hacking
- Needs: administrator rights and a session.
- Runs: writes an Image File Execution Options `Debugger` value for `sethc.exe` and `Utilman.exe`, sets `fDenyTSConnections` to 0 and `LogonTimeout` to 3600, and enables the RDP firewall rules.
- Leaves: cleanup removes the `Debugger` values; the two Terminal Server values are not recorded in the registry backup and stay as written.

### 502. Metasploit Reverse Shell
- Needs: the MSF host and port (default 4444).
- Runs: starts a background job on the target with a reverse TCP PowerShell payload and prints the matching `multi/handler` commands.
- Leaves: an `AutoRDPwn_*` job, stopped by cleanup; nothing is registered for persistence across a reboot.

### 503. Remote Keylogger
- Needs: a session; two payload blobs from `Invoke-Keylogger.ps1`.
- Runs: writes `dllhost.exe` and `svchost.exe` into a work directory, copies them to `C:\Windows\Temp\AutoRDPwnKey_<guid>`, starts the logger against `explorer.exe` and tails `%LOCALAPPDATA%\config.dat` until `Ctrl+C`.
- Leaves: the log file, the remote directory and the host process; cleanup deletes the log and directory, and the module stops the process in a `finally`.

### 904. Fast keylogger
- Needs: a session; `Resources\Scripts\Invoke-Keylogger.ps1` for the two payload blobs.
- Runs: writes `dllhost.exe` and `svchost.exe` into a work directory, copies them to `C:\Windows\Temp\AutoRDPwnKey_<guid>\`, starts the logger against `explorer.exe` and pulls `%LOCALAPPDATA%\config.dat` every 15 s. Complete lines are appended to `%LOCALAPPDATA%\AutoRDPwn\loot\keys\<target>-<yyyyMMdd-HHmmss>.log` and printed as they arrive; Escape stops the loop. A local target reads the log in place. Handler: `Invoke-ARModuleKeyloggerFast`; the slower, file-based route is action 503.
- Leaves: the remote directory and the log, killed and deleted in a `finally`. The local mirror stays under `loot\keys\`.

### 504. Persistence kit
- Needs: an elevated remote session; a target user for the logon task.
- Runs: stages a heartbeat payload at `C:\Windows\Temp\W<8 hex>.ps1` that appends a timestamp to `C:\Windows\Temp\W<8 hex>.log` every 300 s for 288 iterations, then installs three activations: the Run value `ARDP_<6 hex>` under `HKCU:\Software\Microsoft\Windows\CurrentVersion\Run`, the logon task `AutoRDPwn<6 hex>`, and the WMI pair `__EventFilter AutoRDPwnF<6 hex>` + `CommandLineEventConsumer AutoRDPwnC<6 hex>`. Each success is appended to `$script:ARPersistenceItems`; the previous Run value is recorded in `$script:ARRegistryBackup` before the write. Handler: `Invoke-ARModulePersistenceKit`.
- Cleanup: the handler's `-Remove` switch runs `Remove-ARPersistenceItems -IncludeUnknown`, which deletes the Run value, ends and unregisters the task, kills the payload process and drops the binding, consumer and filter. The sweep also matches `ARDP_*` values, `AutoRDPwn[A-F0-9]{6}` tasks and `AutoRDPwnF*`/`AutoRDPwnC*` WMI objects left by an interrupted install. Session cleanup calls the same removal path from `Remove-ARModuleArtifacts` and replays the registry backup.

## Privilege escalation

### 601. Get operating system information
- Needs: a session.
- Runs: copies `Chachi-Enumerator.ps1` and runs `Comprueba-Todo`, printing the full enumeration.
- Leaves: nothing; the temporary directory is removed in a `finally`.

### 602. Search vulnerabilities with Sherlock
- Needs: a session.
- Runs: copies `Sherlock.ps1` and runs `Find-AllVulns` against the installed kernel and services.
- Leaves: nothing; the temporary directory is removed in a `finally`.

### 603. Privilege escalation audit
- Needs: a session.
- Runs: copies `Invoke-PrivescCheck.ps1` and runs `Invoke-PrivescCheck` over services, tasks, permissions and patches.
- Leaves: nothing; the temporary directory is removed in a `finally`.

### 420-427. Privilege escalation pack

Eight actions that either look for an escalation path or take one. The "needs"
column is the catalog gate: all eight need a target in the target editor and all
eight carry `-NeedsSession $false`. The split that matters is the one below the
table: 420 to 423 only read the target, 424 to 427 write to it.

| id | action | handler | what it needs |
| --- | --- | --- | --- |
| 420 | AlwaysInstallElevated | `Invoke-ARModuleAlwaysInstallElevated` | target; reads the `HKLM` and `HKCU` policy values, no session |
| 421 | Unquoted service paths | `Invoke-ARModuleUnquotedServicePath` | target; reads `ImagePath` and folder ACLs, no session |
| 422 | Service permissions | `Invoke-ARModuleServicePermissions` | target; reads the service DACLs for the running account, no session |
| 423 | Potato check | `Invoke-ARModulePotatoCheck` | target; reads the token privileges of the running account, no session |
| 424 | UAC bypass (fodhelper) | `Invoke-ARModuleUacBypass` | target; a non-elevated account and its `HKCU` hive, no session |
| 425 | Run as SYSTEM (task) | `Invoke-ARModuleSystemTask` | target; administrative rights to register a task as SYSTEM, no session |
| 426 | Run as SYSTEM (service) | `Invoke-ARModuleSystemService` | target; administrative rights to create and start a service, no session |
| 427 | Backdoor account | `Invoke-ARModuleBackdoorAccount` | target; administrative rights to create a local account, no session |

- Read-only: 420, 421, 422 and 423 change nothing on the target. They report a
  policy value, an unquoted path with the folder that makes it writable, the
  service DACL the running account holds, or the token privileges that make a
  Potato attack viable.
- Writers: 424 writes the `fodhelper.exe` command under `HKCU` and records the
  previous values in `ARRegistryBackup`; 425 registers a scheduled task and adds
  its name to `ARRemoteTasks`; 426 creates a LocalSystem service, keeps it in its
  own services collection and deletes it in a `finally`; 427 creates a local
  administrator account and adds it to `ARCreatedAccounts`.
- Runs: each handler works over the same remote channel as the rest of the
  catalog. The four writers create their artefact and register it with the
  cleanup list from inside the same handler, so the list and the artefact cannot
  drift apart.
- Leaves: the registry values, the task, the service or the account. 424, 425
  and 427 use the shared collections that `Invoke-ARCleanup` replays; 426 has no
  shared services list, so the handler deletes its own service in the `finally`
  and the deletion runs on the failure path too.
- Note: 420 to 423 are the reconnaissance half of the pack and leave nothing
  behind; 424 to 427 are the half that changes the host, and each of the four
  names its cleanup mechanism in its own body (`Tests\Wave3.Tests.ps1` enforces
  that).

## Other modules

### 701. Deactivate system logs
- Needs: administrator rights and a session.
- Runs: copies `Invoke-Phant0m.ps1` and runs `Invoke-Phant0m`, which stops the EventLog service threads without stopping the service.
- Leaves: nothing on disk; the service state is not restored by cleanup.

### 805. Event log clear
- Needs: administrator rights and a session.
- Runs: prints the nine logs it will wipe — Application, Security, System, Setup, Windows PowerShell, PowerShell/Operational, TaskScheduler/Operational, WinRM/Operational and TerminalServices-LocalSessionManager/Operational — and asks for the literal word `YES` unless `-Yes` was passed. Each log is cleared with `wevtutil cl` and the result table shows the exit code per log.
- Leaves: nothing on disk. Cleared logs cannot be restored; a log that refuses to clear is listed by name and exit code and the status line reports the failure count.

### 802. Defender exclusions
- Needs: administrator rights and a session.
- Runs: reads `Get-MpPreference`, adds `C:\Windows\Temp` and `C:\ProgramData` as exclusion paths when they are absent, then turns real-time monitoring off. Every change is recorded in `$script:ARRemoteDefenderChanges` together with its previous value.
- Leaves: the two exclusions and the real-time state; cleanup removes the exclusions it added and restores the previous monitoring value. When Defender answers nothing the action prints `Defender exclusions skipped: <reason>` and finishes with a warning status instead of failing.

### 803. AMSI bypass
- Needs: a session.
- Runs: resolves `System.Management.Automation.AmsiUtils` and sets the internal static `amsiInitFailed` field inside the remote runspace, then reads it back and prints `<before> -> <after>`.
- Leaves: nothing on disk and nothing in the registry: the flag lives in that runspace only and disappears with the session. Throws `AMSI bypass failed: amsiInitFailed could not be patched.` when the type or the field does not resolve, which is the normal outcome on a hardened build.

### 702. Remote VNC Server (legacy)
- Needs: the same target user, password and ports as action 8.
- Runs: `Invoke-ARModuleVncServer` is a two-line wrapper over `Invoke-ARAttackQuickScreen`; there is no VNC binary in the path.
- Leaves: exactly what action 8 leaves, and the same teardown removes it.

### 703. External script execution
- Needs: a local path or an HTTP(S) URL, an optional function name, and a session.
- Runs: downloads the script when the source is a URL, copies it to `C:\Windows\Temp\AutoRDPwnScript_<guid>`, dot-sources it and runs the function when one is named.
- Leaves: the temporary directory and, for URLs, the downloaded copy in the work directory; cleanup removes both.

### 704. Change user with RunAs
- Needs: local target only; a valid local account and password.
- Runs: validates the credentials against the local machine, extracts `RunAs.exe` and launches `powershell.exe -NoExit` as that user.
- Leaves: the new process and `RunAs.exe` in `Resources\Tools`; the process is not tracked by cleanup.
