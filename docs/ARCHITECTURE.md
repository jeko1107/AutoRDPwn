# Architecture

AutoRDPwn is one PowerShell script assembled from six source parts. `src\` is the
source of truth; `AutoRDPwn.ps1` in the repository root is generated from it and
must never be edited by hand. Both files run on Windows PowerShell 5.1 and
PowerShell 7.

## Source map

| file | size | owns |
| --- | --- | --- |
| `src\00-header.ps1` | ~140 lines | `param()` block, version, root discovery, elevation, `$script:AR*` flags, CLI values, TLS and proxy setup |
| `src\10-tui.ps1` | ~2300 lines | action catalog, categories, both interfaces, target profiles, language, favourites, drawing helpers |
| `src\20-runtime.ps1` | ~1100 lines | sessions, retries, logging, cleanup, Defender exclusions, resource download, action dispatch, shadow engine |
| `src\30-attacks.ps1` | ~740 lines | the remote-execution actions, the loot and transfer helpers |
| `src\40-modules.ps1` | ~630 lines | collection, pivoting, persistence and priv-esc modules |
| `src\50-main.ps1` | ~76 lines | startup, `-option` dispatch, the top-level `try`/`finally` |

Load order matters: the header defines `$script:ARRoot` and `$script:ARTools`
before anything reads a resource, `10-tui` defines `New-ARAction` before
`20-runtime` calls `Get-ARActionById`, and `50-main` is the only part that
actually starts the application.

### 00-header

Sets `$script:ARVersion`, resolves the repository root by looking for
`Resources\Scripts` next to the script, falls back to
`%TEMP%\AutoRDPwn` when the script runs outside a checkout, and creates the
directories it needs. It also re-launches itself elevated with
`Start-Process -Verb RunAs`, forwarding every switch it received. No function
here is called later except `Test-ARHeaderAdmin`.

### 10-tui

Three blocks:

1. State: the `$script:AR*` scalars and lists (target, status, selection, filter,
   frame buffer, language strings).
2. Data: `New-ARAction`, `New-ARGroup`, `Get-ARActionCatalog`,
   `Get-ARActionCategories`, the filter and selection resolvers.
3. Presentation: the box-drawing primitives, `Show-ARTuiScreen`, `Show-ARHelp`,
   the target form, the profile picker, the language picker, the line-mode
   fallbacks and the `Show-ARTui` key loop.

The catalog is a flat list of actions and group markers. `Get-ARActionCategories`
walks it once and turns each group marker into a category bucket, so the menu
cannot drift from the catalog: there is no second list of ids anywhere.

### 20-runtime

Everything that talks to the target:

- `Connect-ARTargetSession` / `Close-ARTargetSession` / `Get-ARTargetSession`
  wrap `New-PSSession` with a 15 s open timeout and a 180 s operation timeout.
- `Invoke-ARTargetCommand`, `Invoke-ARTargetPowerShell`, `Invoke-ARTargetBinary`
  and `Copy-ARFileToTarget` are the four ways a module reaches the target. Each
  stages into `C:\Windows\Temp\AutoRDPwn_<guid>` or
  `C:\Windows\Temp\W<8 hex>` and removes its staging in a `finally`.
- `Invoke-ARRemote` is the retrying wrapper: three attempts by default, only for
  transport failures (`PSRemotingTransportException`, `PSRemotingDataStructureException`,
  or a message naming `transport`, `broken pipe`, `deadlock` or `WSMan`), waiting
  `2 * 2^(n-1)` seconds and reconnecting once when the session died. Everything
  else is rethrown on the first attempt.
- `Write-ARLog` appends `%LOCALAPPDATA%\AutoRDPwn\logs\ardpwn-<yyyyMMdd>.log` and
  rotates it at 5 MB; a log failure is swallowed so it can never take the run
  down. `Write-ARProgress` draws the progress bar and returns early when output is
  redirected or the script runs in test mode.
- `Invoke-ARAction` resolves an id, runs the handler and turns an exception into
  `$script:ARLastFailure` plus a red status line.
- `Invoke-ARShadowEngine` writes the Terminal Server registry values, records the
  previous state, opens the `mstsc /shadow` client.
- `Remove-ARTargetArtifacts` and `Invoke-ARCleanup` are the teardown.

### 30-attacks and 40-modules

One function per catalog handler. A handler reads its inputs from
`$script:ARTarget` or from `Read-ARValue`, does its work, prints through
`Write-ARInfo` / `Write-ARSuccess` / `Write-ARWarn`, and ends with
`Set-ARStatus`. Handlers never draw the menu and never call `exit`.

`30-attacks.ps1` also exports three helpers that `40-modules.ps1` reuses:

- `Get-ARLootDirectory` — `%LOCALAPPDATA%\AutoRDPwn\loot\<leaf>`, operator side.
- `New-ARRemoteTempName` — `W` plus eight hex characters, which keeps matching
  the `W[0-9A-F]{8}` pattern used by cleanup.
- `Receive-ARFileFromTarget` — `Copy-Item -FromSession` first, then a 48 KB
  base64 chunk loop when WinRM truncates the copy.

### 50-main

Loads the saved language, restores the last profile, applies `-shadow` to the
mode, initialises the Defender exclusions, dispatches `-option` or enters the
menu loop, and wraps everything in `try`/`catch`/`finally`. The `finally` calls
`Invoke-ARCleanup`, which is why an exception, a `Ctrl+C` or a closed console
still tears the target down.

## Build

```powershell
.\Build.ps1                              # writes AutoRDPwn.ps1
.\Build.ps1 -OutputPath _sandbox\gen.ps1 # scratch build for tests
```

`Build.ps1` parses each of the six parts with the PowerShell parser and refuses
to write output when a part has a syntax error. It concatenates them with a
blank line between parts, writes `AutoRDPwn.ps1.tmp` as UTF-8 with BOM, parses
the result again, and only then moves it over the target path. A failed build
leaves the previous `AutoRDPwn.ps1` untouched.

Rules that follow from this:

- Never edit `AutoRDPwn.ps1`. Edit `src\` and rebuild.
- Never run `Build.ps1` without `-OutputPath` while work is in flight; it
  overwrites the versioned build. The suite always builds to `_sandbox\gen.ps1`
  and a test fails if any test file invokes `Build.ps1` without `-OutputPath`.
- A drift between `src\` and `AutoRDPwn.ps1` is reported as a skip, not a
  failure, because `src\` is under active edit.

## State

| state | lives in | lifetime |
| --- | --- | --- |
| target fields | `$script:ARTarget` | process |
| current status line | `$script:ARStatus` | process |
| selection and filter | `$script:ARSelectedId`, `$script:ARFilter`, `$script:ARSelectedCategoryKey` | process |
| session | `$script:ARSession` | until `Close-ARTargetSession` |
| cleanup trackers | `$script:ARWorkDirs`, `$script:ARTemporaryFiles`, `$script:ARRemoteTempDirs`, `$script:ARCreatedAccounts`, `$script:ARRemoteTasks`, `$script:ARFirewallRules`, `$script:ARCmdKeyTargets`, `$script:ARRegistryBackup`, `$script:ARInstalledProducts`, `$script:ARModuleFiles`, `$script:ARPortProxyPorts` | process |
| saved profiles | `Resources\Tools\targets.json` | disk |
| last profile, language and favourites | `Resources\Tools\last.json` | disk |
| extracted binaries, work directories | `Resources\Tools\` | until cleanup |
| loot from 205, 206 and 901 | `%LOCALAPPDATA%\AutoRDPwn\loot\` | disk, operator side |
| log | `%LOCALAPPDATA%\AutoRDPwn\logs\` | disk, rotated at 5 MB |
| CLI values | `$script:ARCliTarget`, `$script:ARCliUser`, `$script:ARCliPassword`, `$script:ARCliMode`, `$script:ARConfigPath` | process, not consumed yet |
| confirmations | `$script:ARAssumeYes` (from `-Yes`) | process |

`Resources\Tools\.gitignore` ignores everything in that directory except itself,
so a run never dirties the working tree with binaries or profiles.

## Cleanup model

`Invoke-ARCleanup` runs once per process (`$script:ARCleanupDone`) and does two
separate jobs.

Target side, only with a live session and only without `-noclean`, in
`Remove-ARTargetArtifacts`:

- stop and remove `AutoRDPwn_*` jobs in the remote session;
- unregister `AutoRDPwn*` scheduled tasks and any `W[0-9A-F]{8}` task whose
  action runs `C:\Windows\Temp\W[0-9A-F]{8}.ps1`;
- delete `C:\Windows\Temp\AutoRDPwn*` directories and the legacy
  `vncb64.txt`, `vnc.ps1`, `vnclog.txt`, `ss.ps1` files;
- stop and delete the `WinShotSvc` and `WinSessionSvc` services;
- delete created local accounts and their `C:\Users\<account>` directories;
- remove the `sethc.exe` and `Utilman.exe` `Debugger` values;
- delete every firewall rule in `$script:ARFirewallRules` plus
  `AutoRDPwn-TermService-RPC-In`;
- set back to disabled every rule recorded in `$script:ARFirewallRestore` by
  action 801;
- replay `$script:ARRemoteDefenderChanges` from action 802: remove the exclusions
  it added and restore the previous real-time monitoring value;
- replay `$script:ARRegistryBackup` entry by entry: remove the value when it did
  not exist before, restore type and data when it did;
- uninstall every MSI product code in `$script:ARInstalledProducts` with
  `msiexec /x` and remove the remaining uninstall keys.

Operator side, always, even with `-noclean`:

- delete every `cmdkey` entry in `$script:ARCmdKeyTargets`;
- run `Remove-ARModuleArtifacts` (keylogger log, recovered RDP cache) while the
  session is still open;
- restore the Defender exclusions added by `Initialize-ARDefender`;
- delete `$script:ARWorkDirs` and `$script:ARTemporaryFiles` under the repository;
- reset the operator port proxies recorded in `$script:ARPortProxyPorts`;
- close the session, restore the original working directory, and print a summary
  naming up to five failed steps.

Remote port proxies created by action 302 operation 2 are not recorded, so they
stay on the target until they are reset there. The `WinShotSvc` cleanup is kept
for targets touched by older builds.

## Adding an action

1. Write the handler in `src\30-attacks.ps1` or `src\40-modules.ps1`. Name it
   `Invoke-ARAttack<Name>` or `Invoke-ARModule<Name>`; take no parameters unless
   the dispatcher will pass them; read inputs with `Read-ARValue` or
   `Read-ARSecret`; end with `Set-ARStatus`.
2. Register it in `Get-ARActionCatalog` in `src\10-tui.ps1` with
   `New-ARAction -Id '<id>' -Title (Get-ARText 'txtNNN' '<fallback>')
   -Description '<one line>' -Handler '<handler>' [-NeedsTarget $false]
   [-NeedsSession $false]`. Place it under the group marker of the category it
   belongs to; the category buckets are derived, never listed.
3. Add the title and description keys to all seven files in
   `Resources\Languages\` with the same key names. The files are UTF-8 with BOM
   and CRLF; `Localization.Tests.ps1` fails when a key exists in one file and
   not in another.
4. Rebuild to `_sandbox\gen.ps1` and run the suite. `Catalog.Tests.ps1` checks
   that every catalog handler exists in `src\` and that ids are unique, so an
   entry without a handler fails the build gate before anything runs live.

## Tests

`Tests\Run-Tests.ps1` builds `_sandbox\gen.ps1` and runs the offline groups:
`Parse`, `Catalog`, `Contracts`, `Profiles`, `Runtime`, `Attacks`,
`Regression`, `Localization` and `Drift`. No network, no elevation and no catalog
action is executed. `Tests\TestKit.ps1` provides the assertion helpers and
`Tests\ArAst.ps1` the AST queries. See `Tests\README.md`.
