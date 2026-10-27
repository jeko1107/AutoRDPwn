# Screen access (option 8)

Action 8, Quick Screen (Stealth VNC), opens the target console screen from the
operator console. Action 702, Remote VNC Server (legacy), is a wrapper over the
same function; there is no VNC binary in either path.

## Entry and preflight

`Invoke-ARAttackQuickScreen` (`src\02-actions.ps1`) does the following:

1. Checks TCP 5985 on the target with `Assert-ARPort`; a closed port aborts the
   action before anything is staged.
2. Requires a target user. In `-option` mode an empty user throws
   `Quick Screen requires a target user`; in the menu it prompts for one.
3. Takes the password from the target profile, prompting only when it is empty.
   `-option` runs cannot prompt, so the profile must already hold the user and
   password.
4. Reads the target `Mode`: `view` maps to view-only, `control` maps to input
   forwarding. `-shadow view` or `-shadow control` overrides it at startup.

It then calls `Invoke-StealthScreen` from
`Resources\Scripts\Invoke-StealthScreen.ps1` with `-Mode view` and
`-ViewOnly:$viewOnly`. Both menu entries use this route.

## Staging

The operator opens a WinRM session to the target with `Negotiate`
authentication, then stages one scheduled task:

- task name `W` followed by eight random hex characters;
- script `C:\Windows\Temp\W<8 hex>.ps1`;
- stop file `C:\Windows\Temp\W<8 hex>.stop`;
- action `powershell.exe -nop -w hidden -ep bypass -f "<script>"`;
- principal: the target user, `LogonType Interactive`, `RunLevel Highest`.

An interactive task runs the payload inside the logged-on desktop session, which
is what gives the frame server access to the console desktop. If the task cannot
be registered as the user, the module falls back to a SYSTEM task that spawns
the payload with `CreateProcessAsUserW` from `WTSQueryUserToken`; the code marks
that path as a fallback only, because a process created that way does not
initialise reliably.

## Firewall rule

Before the listener binds, the module creates the inbound rule
`AutoRDPwn Frame 8081` for TCP 8081 through `netsh advfirewall`. Creating the
rule first is deliberate: a blocked first connection pops the Windows Defender
Firewall prompt on the target desktop, which is the noise this route exists to
avoid. The rule name is added to `$script:ARFirewallRules` and removed from that
list, and from the target, in the module's `finally`.

The rule's lifetime is the action, not the session: stop the viewer, press
`Ctrl+C`, close the console or hit an error and the `finally` still deletes the
rule, the task, the script and the stop file.

## Frame server

The staged script is a single-threaded HTTP server built on `TcpListener`; it
needs no URL ACL and no HTTP.sys reservation.

- Binds `0.0.0.0:8081`.
- Loads `System.Windows.Forms` and `System.Drawing`.
- Captures `SystemInformation.VirtualScreen` with `CopyFromScreen`, so it
  follows the console resolution and covers every monitor.
- Encodes each frame as JPEG at quality 55, with a capture interval of 200 ms.
- Captures only while someone is pulling: a request in the last four seconds
  keeps it awake, an unwatched server costs nothing.
- Reports its own session id, screen size and frame count in `/latest.txt`.

Endpoints:

| path | answer |
| --- | --- |
| `/latest.jpg` | latest JPEG, or `503` with `warming up` before the first frame |
| `/latest.txt` | `frame=<time> session=<id> screen=<w>x<h> frames=<n>` |
| `/input?...` | applies an input event when control mode is enabled, answers `ok` |
| `/stop` | answers `bye`, writes the stop file and ends the loop |

The task runs as the console user, so the process lands in the console session
(usually session 1 on a single-user workstation). There is no separate capture
service, no `WinShotSvc`, and no persistent listener.

## Viewer

The operator side is a WinForms window that pulls frames:

- HTTP client with a four-second timeout, polling every 120 ms;
- a black form, 1024x768 by default, with a `PictureBox` in zoom mode;
- a status line with the frame count, the target's `/latest.txt` line and
  `control` or `view only`;
- `ESC` closes the window and requests `/stop`.

In control mode the viewer forwards mouse movement (throttled to 40 ms),
left/right/middle button down and up, wheel, and key down/up. The target applies
them with `SetCursorPos`, `mouse_event` and `keybd_event`; the virtual-key code
is the WinForms `KeyCode`. In view-only mode the `/input` endpoint is not
compiled into the frame server at all, so forwarded events are impossible.

Before opening the viewer, the module probes `/latest.txt` up to 15 times with a
three-second pause, so a cold start (task launch, WinForms load, listener bind)
has up to 45 seconds.

## Why there is no 5900 listener and no DLL injection

The previous route staged a 1.7 MB VNC vendor blob and injected it reflectively
into a target process. That injection dies silently after the `GetProcAddress`
fix, and it required a second listener on 5900 plus a dial-back path. The
current route keeps one HTTP port that the operator pulls from:

- the target never dials back to the operator;
- nothing is mapped into another process, so there is no reflective load and no
  DLL to avoid on disk;
- the only inbound port is 8081, opened by the action and closed by its
  teardown.

## Failure modes

| symptom | cause | check |
| --- | --- | --- |
| `Quick Screen needs TCP 5985` | WinRM closed or filtered | `Test-NetConnection -ComputerName <target> -Port 5985` |
| `WinRM session failed` | bad credentials, Negotiate refused, WinRM listener down | `winrs -r:<target> -u:<user> -p:<password> cmd` |
| frame server never answers | interactive task failed and the SYSTEM fallback never initialised, no console user, or port 8081 taken | `query session` on the target; `Get-NetTCPConnection -LocalPort 8081 -State Listen` |
| viewer opens but stays black | no frame yet (`503 warming up`), capture failed in a non-interactive session | `Invoke-WebRequest http://<target>:8081/latest.txt` |
| port reachable locally but not remotely | rule missing, or a network device blocks 8081 | `netsh advfirewall firewall show rule name="AutoRDPwn Frame 8081"` |
| viewer reports `no frames` | target stopped answering; task or listener died | re-run action 8 and watch `/latest.txt` |

A single PNG capture also exists in the script as `-Mode shot`; it stages the
same kind of task, saves `stealthshot.png` under `Resources\Tools`, and is not
exposed by any catalog action.
