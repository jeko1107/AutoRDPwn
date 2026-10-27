# Command line

`AutoRDPwn.ps1` is a PowerShell script, so it takes its switches through the
normal `param()` block in `src\00-header.ps1`. Every sample below assumes the
repository root as the working directory.

```powershell
# source checkout, built script in the root
powershell -NoProfile -ExecutionPolicy Bypass -File .\AutoRDPwn.ps1

# same file, administrative console
$PSScriptRoot; .\AutoRDPwn.ps1
```

Started without administrator rights the script relaunches itself elevated and
the original console exits. `-noadmin` keeps the current console instead.

## Switches

| switch | type | default | effect |
| --- | --- | --- | --- |
| `-noadmin` | switch | off | Never relaunch elevated. Sets `$script:ARNoAdmin`. |
| `-nogui` | switch | off | Force the numbered line interface instead of the full-screen menu. Redirected standard input does the same. |
| `-lang <value>` | string | `''` | Language for the run. Name (`Spanish`), two-letter code (`es`) or number (`2`); unknown values resolve to English. Overrides the choice stored in `last.json`. |
| `-option <id>` | string | `''` | Run one catalog action by id, then exit. Skips the menu entirely. |
| `-shadow <value>` | string | `''` | Set the target `Mode` before startup: `see`, `view`, `ver`, `regarder`, `siehe`, `vedere` select `view`; `control`, `controlar`, `controle`, `kontrolle`, `controllo` select `control`. |
| `-createuser` | switch | off | Add the `Pwn5` payload from the language file to the payload list, so the remote-execution actions also create the operator account. Sets `$script:ARCreateUser`. |
| `-noclean` | switch | off | Skip the target-side cleanup in `Remove-ARTargetArtifacts`. Operator-side cleanup still runs. |
| `-Yes` | switch | off | Assume yes for the confirmations that read `$script:ARAssumeYes`: the shadow-copy prompt of action 804 and the `YES` prompt of action 805. Sets `$script:ARAssumeYes` in the header. |
| `-Target <value>` | string | `''` | Target computer. Written to `$script:ARTarget['Computer']` after the saved profile is restored, so it wins over the profile. |
| `-User <value>` | string | `''` | Target account. Written to `$script:ARTarget['User']`. |
| `-Password <value>` | string | unset | Target password in plain text. Written to `$script:ARTarget['Password']`; only `S` in the menu saves it to a profile. |
| `-Mode <value>` | string | `''` | Screen mode. `ValidateSet` accepts `view` and `control`; any other value fails parameter binding before the script runs. |
| `-Config <path>` | string | `''` | JSON file merged into the run: `Target`, `User`, `Password`, `Mode` and `Language`. See below. |
| `-List` | switch | off | Print the action catalog as a table with `Id`, `Title`, `Handler`, `NeedsSession` and `Group`, then exit `0`. |
| `-ListJson` | switch | off | Print the same catalog as a JSON array, then exit `0`. |

`-Target`, `-User`, `-Password` and `-Mode` are applied in
`Start-ARApplication` after `Restore-ARLastProfile`, so a value on the command
line replaces whatever the last profile held. `-Mode` and `-shadow` both set
`$script:ARTarget['Mode']`; `-shadow` is applied after `-Mode`, so `-shadow`
wins when both are present. `-Yes` sets `$script:ARAssumeYes` in the header and
suppresses the action 804 prompt and the `YES` prompt of action 805.

`-Config` reads a JSON object with `Get-Content -Raw` and `ConvertFrom-Json`
and merges five optional keys: `Target`, `User`, `Password`, `Mode` and
`Language` (`language` works too). A switch bound on the command line beats the
file; a key from the file beats the profile restored from `last.json`. A
missing file exits `1` with `Config file not found: <path>`; malformed JSON
exits `1` with `Malformed JSON in config file.`.

```json
{
  "Target": "192.0.2.10",
  "User": "usuario",
  "Password": "usuario",
  "Mode": "view",
  "Language": "es"
}
```

Run order in `Start-ARApplication`: config file, language, saved profile, the
four target switches, `-shadow`, `-Yes`, then `-List`/`-ListJson`, then
`-option` or the menu. `-List` and `-ListJson` call `Get-ARActionCatalog`,
print and exit `0` before `Initialize-ARDefender` and the interface start; when
the catalog is not available they print `Action catalog not available.` and
exit `1`.

The elevation relaunch forwards `-nogui`, `-lang`, `-option`, `-shadow`,
`-createuser` and `-noclean`. It does not forward `-Target`, `-User`,
`-Password`, `-Mode`, `-Yes`, `-Config`, `-List` or `-ListJson`; start those
runs from a console that is already elevated, or add `-noadmin`.

## `-option` semantics

`-option` accepts a catalog id. `Resolve-ARSelection` in `src\10-tui.ps1` maps
the value, so the legacy aliases `11` to `17` work as well
(`101`, `201`, `301`, `401`, `501`, `601`, `701`), and any other value that is
not a catalog id is reported as `Unknown option: <value>`.

The run is non-interactive. `Read-ARValue` and `Read-ARSecret` throw
`Missing value for "<Prompt>": it cannot be prompted for in -option mode.`, the
action is marked as failed, and the process exits with code 1. Actions that read
the target from `$script:ARTarget` work as long as the value is already there:
load a profile first, or save one with `S` in the interactive menu so
`Restore-ARLastProfile` picks it up at startup. With no saved profile the target
is `localhost` and the user is the current operator account.

Everything else about startup still runs in `-option` mode: the language is
resolved, the last profile is restored, `-shadow` is applied to `Mode`, and
`Invoke-ARCleanup` runs from the `finally` block in `src\50-main.ps1`.

## Exit codes

| code | cause |
| --- | --- |
| `0` | Menu closed with `Q`/`X`, or `-option` ran an action without failure. |
| `1` | Elevation was required but no script path could be resolved, so the launcher printed `Administrator privileges are required.` |
| `1` | The UAC prompt was cancelled: `Elevation cancelled. Run this terminal as Administrator, or launch with -noadmin.` |
| `1` | `-option` was bound with an empty value: `[!] -option requires a value, for example: -option 8`. |
| `1` | An unknown token was left on the command line: `[!] Unknown argument: <text>`. |
| `1` | `-option` received something that is not a catalog id: `Unknown option: <value>`. |
| `1` | `-Config` names a file that does not exist: `Config file not found: <path>`. |
| `1` | `-Config` points at malformed JSON: `Malformed JSON in config file.`. |
| `1` | `-List` or `-ListJson` could not read the catalog: `Action catalog not available.`. |
| `1` | The action threw. `Invoke-ARAction` stores the message in `$script:ARLastFailure` and `src\50-main.ps1` exits 1. |
| `1` | An unhandled exception reached the top-level `catch` in `src\50-main.ps1`. |

All failures go to standard output with the `[!]` prefix of `Write-ARError`
except the three header checks, which print their own red `[!]` line. Check
`$LASTEXITCODE` after the call in a script.

## Examples

Interactive session with a saved profile, Spanish interface:

```powershell
.\AutoRDPwn.ps1 -lang es
```

Quick Screen in read-only mode against the profile restored from `last.json`:

```powershell
.\AutoRDPwn.ps1 -option 8 -shadow view
```

Line interface for a console without a proper TUI (SSH, `cmd /c` redirection):

```powershell
.\AutoRDPwn.ps1 -nogui -lang en
```

An unknown id, for scripts that branch on the exit code:

```powershell
.\AutoRDPwn.ps1 -option 999
if ($LASTEXITCODE -ne 0) { Write-Host 'action failed' }
```

Catalog as JSON for another script:

```powershell
.\AutoRDPwn.ps1 -ListJson | ConvertFrom-Json
```

One action against an explicit target, no saved profile:

```powershell
.\AutoRDPwn.ps1 -Target 192.0.2.10 -User usuario -Password usuario -option 205 -Yes
```

The same run from a config file:

```powershell
.\AutoRDPwn.ps1 -Config .\run.json -option 205
```

## Building vs running

`AutoRDPwn.ps1` in the repository root is generated from `src\*.ps1` by
`Build.ps1`. Run the built file, never the parts: the parts have no entry point.
See `docs\ARCHITECTURE.md` for the build and drift rules.
