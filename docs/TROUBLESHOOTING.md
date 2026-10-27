# Troubleshooting

Each entry gives the symptom as it appears, the cause, and the command that
confirms or fixes it. Run the commands on the operator unless the entry says
otherwise.

## WinRM refused on 5985

- Symptom: `PSexec` and `WMI` work but `WinRM`, `WinRS` or `Quick Screen` stop
  immediately with `WinRM needs TCP 5985 on <target> and it is closed or
  filtered.` or `New-PSSession : Connecting to remote server ... failed`.
- Cause: WinRM is not enabled on the target, the listener is bound to another
  port, or a firewall rule blocks 5985. `Assert-ARPort` tests the port before
  the action stages anything, so the failure is upstream of AutoRDPwn.
- Fix: enable WinRM and open the rule on the target, then re-check from the
  operator.

```powershell
# on the target
winrm quickconfig -force
Enable-PSRemoting -Force
# on the operator
Test-NetConnection -ComputerName <target> -Port 5985
Test-WSMan -ComputerName <target>
```

The `Pwn2` and `Pwn4` payloads in `Resources\Languages\*.ps1` do the same thing
remotely through any transport that already works.

## WinRM authentication failure

- Symptom: `New-PSSession : ... Access is denied` or
  `The WinRM client cannot process the request`, after the port check passed.
- Cause: wrong user or password in the profile, a local account without
  `LocalAccountTokenFilterPolicy`, or Negotiate refusing a non-domain account.
  Actions 1-5 and 8 read `User`, `Password` and `Domain` from
  `$script:ARTarget`.
- Fix: verify the account with `winrs` (same transport, same credentials), and
  set `LocalAccountTokenFilterPolicy` on the target for local administrators.

```powershell
winrs -r:<target> -u:<user> -p:<password> cmd /c whoami
# on the target, for a workgroup machine
reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v LocalAccountTokenFilterPolicy /t REG_DWORD /d 1 /f
```

Pass the Hash does not use WinRM for the first step: it authenticates over SMB
and then creates `ARDP_<8 hex>` to open the session.

## Administrator required

- Symptom: `[!] Administrator privileges are required.` and exit code 1, or a
  handler throws `Administrator privileges are required for TSCon.`
- Cause: the header checks for the Administrator role before anything else. With
  `-noadmin` it does not relaunch, and the actions that need elevation fail one
  by one. The interface header shows `admin: no` in that case.
- Fix: start an elevated console, or accept the UAC prompt the launcher raises.
  Do not use `-noadmin` for actions 6, 205, 206, 501 and the shadow engine.

```powershell
Start-Process powershell -Verb RunAs
.\AutoRDPwn.ps1
```

If UAC is cancelled the launcher prints `Elevation cancelled` and exits 1; the
original unelevated console has already closed.

## `query session` output is localised

- Symptom: the session table printed by action 6 or by the shadow engine is in
  the target's language and looks unparsable.
- Cause: that output is displayed for the operator only. Since 6.0
  `Get-ARSessionId` never parses it: it reads the last `explorer.exe` session id
  through `Win32_Process`, then falls back to `Win32_LogonSession` entries of
  type 2 and 10, and finally to the supplied fallback (1).
- Fix: nothing. If the detected id is still wrong, run the action in the menu,
  where it asks for the session id with the detected value as the default, and
  type the correct one. `-option` runs accept the detected value without
  prompting.

```powershell
query session
Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" | Select-Object SessionId
```

## No active console session

- Symptom: the frame server starts but `/latest.jpg` keeps returning `503
  warming up`, or `Get-Process explorer` on the target shows session 0.
- Cause: nobody is logged on interactively. The frame server captures
  `SystemInformation.VirtualScreen` inside the session the scheduled task runs
  in; a session with no desktop has nothing to capture. Quick Screen does not
  create a session, it only looks at one.
- Fix: log a user on at the console, or reach the session with the shadow engine
  first.

```powershell
query user
Invoke-WebRequest http://<target>:8081/latest.txt
```

## Firewall rule present, port unreachable

- Symptom: `netsh advfirewall firewall show rule name="AutoRDPwn Frame 8081"`
  lists the rule on the target, but the operator cannot connect.
- Cause: the rule exists and the listener does not, the target's network profile
  is Public and a device in between filters 8081, or another process holds the
  port so the frame server exited on bind.
- Fix: check the listener on the target and the path from the operator.

```powershell
# on the target
Get-NetTCPConnection -LocalPort 8081 -State Listen
netsh advfirewall firewall show rule name="AutoRDPwn Frame 8081"
# on the operator
Test-NetConnection -ComputerName <target> -Port 8081
```

The rule is created before the listener binds on purpose: a blocked first
connection raises the firewall prompt on the target desktop. It is deleted in
the action's `finally`, so a rule that survives a run means the console was
killed between the two steps; delete it by name.

## Viewer opens with a black image

- Symptom: the WinForms window appears with the status line `connecting...` or
  `frames: 0`, and the picture stays black.
- Cause: no frame has arrived yet. The server answers `503 warming up` until the
  first capture, the operator pulls every 120 ms, and the probe before the viewer
  opens allows 15 attempts of three seconds. A session 0 task, a locked desktop
  with no user, or a target that stopped answering all produce the same view.
- Fix: read `/latest.txt` directly; it reports the session, screen size and frame
  count, which separates "no capture" from "no network".

```powershell
Invoke-WebRequest http://<target>:8081/latest.txt | Select-Object -ExpandProperty Content
```

`no frames - the target stopped answering` after 40 consecutive misses means the
task or the listener died; re-run action 8.

## `-option` returns 1

- Symptom: `powershell -File AutoRDPwn.ps1 -option 205; $LASTEXITCODE` is `1`
  with no visible menu.
- Cause: one of four paths sets the exit code: an unknown id, a bound but empty
  `-option`, a stray positional argument, or a handler that threw. A handler
  that calls `Read-ARValue` or `Read-ARSecret` also throws, because `-option`
  mode cannot prompt.
- Fix: read the red line above the exit code, then supply the missing value in a
  saved profile and load it before the run.

```powershell
.\AutoRDPwn.ps1 -option 205            # target must exist and the profile must hold user and password
echo $LASTEXITCODE                     # 0 on success
.\AutoRDPwn.ps1 -option 999            # unknown option, prints "Unknown option: 999", exits 1
```

In `-option` mode the target is `localhost` unless a profile was loaded, so
almost every missing-value failure is a profile that was never saved with `S`.

## A locale file is missing a key

- Symptom: `Localization.Tests.ps1` fails, or the interface shows the English
  fallback for one string after switching language.
- Cause: `Get-ARText` falls back to `Resources\Languages\English.ps1` and then to
  the inline default, so a missing key is silent at run time. The seven files
  must carry the same key set.
- Fix: compare the key lists and add the missing key to every file, UTF-8 with
  BOM and CRLF.

```powershell
Get-ChildItem Resources\Languages\*.ps1 | ForEach-Object {
    $keys = Select-String -Path $_.FullName -Pattern '^\s*\$txt\d+\s*=' |
        ForEach-Object { ($_.Line -split '=')[0].Trim() }
    '{0}: {1}' -f $_.Name, $keys.Count
}
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1 -Filter 'Localization*' -Detailed
```

## Generated-script drift

- Symptom: `AutoRDPwn.ps1` behaves differently from `src\`, or `git status`
  shows the generated file changed while `src\` did not.
- Cause: `AutoRDPwn.ps1` is generated. Editing it by hand, or building while
  another edit is in flight, produces a file that no longer matches the parts.
  `Drift.Tests.ps1` reports drift as a skip on purpose, because `src\` is edited
  continuously and the versioned build is expected to lag.
- Fix: rebuild from `src\` and confirm the parse and the version.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Build.ps1 -OutputPath _sandbox\gen.ps1
Select-String -Path _sandbox\gen.ps1 -Pattern "ARVersion = '"
git diff --stat AutoRDPwn.ps1
```

Only run `.\Build.ps1` without `-OutputPath` when the suite is green and the
generated file is meant to be committed; it overwrites `AutoRDPwn.ps1` in place
through a `.tmp` file, so an interrupted build leaves the previous file intact.

## Shadow session never opens

- Symptom: `Payloads started with PSexec` then nothing, or
  `The remote machine needs a reboot to apply the changes, rebooting..` and the
  operator waits.
- Cause: the shadow engine writes `AllowRemoteRPC`, `fDenyTSConnections` and the
  `RDP-Tcp` values; a target where `AllowRemoteRPC` was 0 needs the reboot the
  engine performs. On a workstation without RDPWrap installed the session id
  comes from `explorer.exe`.
- Fix: let the reboot finish (the engine waits up to 90 s for the session to come
  back), then re-run the action. Check `mstsc /shadow` by hand if it still fails.

```powershell
mstsc /v:<target> /shadow:1 /noconsentprompt /control /f
```

## Old-style artifacts left on a target

- Symptom: `Cleaning done!` reports failed steps, or a `C:\Windows\Temp\W<8
  hex>.ps1`, an `AutoRDPwn*` task or an `AutoRDPwn Frame 8081` rule survives.
- Cause: cleanup needs a live session. With no session it prints
  `Cleanup skipped: no session to <target>` and only the operator-side traces are
  removed. `-noclean` skips the target side on purpose.
- Fix: re-run any action that opens a session, exit normally, and let the
  `finally` in `src\03-main.ps1` clean up. On a target that cannot be
  reached, remove the artifacts by hand.

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -like 'AutoRDPwn*' -or $_.TaskName -match '^W[0-9A-F]{8}$' }
Get-ChildItem C:\Windows\Temp -Directory -Filter 'AutoRDPwn*'
netsh advfirewall firewall show rule name=all | Select-String 'AutoRDPwn'
```
