# Usage

AutoRDPwn 6.0 is a Windows PowerShell console application. Everything below
describes the interface built by the TUI section of `src\01-core.ps1` and the
startup path in `src\03-main.ps1`.

## Requirements

- Operator: Windows with Windows PowerShell 5.1 (PowerShell 7 also runs the
  source build), plus the `Resources\` directory beside the script or repository
  root. A missing resource is a hard error unless
  `AUTORD_PWN_ALLOW_DOWNLOAD=1` is set.
- Target: Windows with PowerShell 5.1 and WinRM enabled for the remote actions.
  TCP 445, 135, 5985 and 3389 are used by the protocols that need them; Quick
  Screen opens 8081 only for the duration of the session.

## First run and elevation

```powershell
.\AutoRDPwn.ps1
```

Started without administrator rights, `src\01-core.ps1` relaunches
`powershell.exe` with `-sta -NoProfile -ExecutionPolicy Bypass -File` and
forwards `-nogui`, `-lang`, `-option`, `-shadow`, `-createuser` and `-noclean`.
The original console exits as soon as the elevated window is created. If UAC is
cancelled the launcher prints `Elevation cancelled` and exits with code 1.

`-noadmin` keeps the current console. Actions that need administrator rights
still fail if the console is not elevated; the header of the running UI shows
`admin: yes` or `admin: no`.

The line interface runs instead of the full-screen TUI when `-nogui` is passed
or when standard input is redirected.

## Target profile

Press `T` from either menu level to open the target editor. The fields, in
order, are:

| field | default | meaning |
| --- | --- | --- |
| Target host | `localhost` | Computer name or IP of the target |
| User | empty | Local or domain account; empty means the current operator account |
| Password | empty | Password for that account, read hidden |
| NTLM hash | empty | Hash used by Pass the Hash and the credential scanner |
| Domain | empty | Prepended to the user as `DOMAIN\user` when set |
| Attacker IP | empty | Address the target dials back to; blank is resolved at run time |
| Mode | `control` | `control` or `view` for the Quick Screen route |

In the full-screen editor, `Up`/`Down` move, `Home`/`End` jump, `Enter` edits
the highlighted field and `Esc` returns to the menu. Editing `Mode` toggles
between `control` and `view` immediately. For the password, an empty answer
keeps the current value and a single `-` clears it. An empty target host resets
to `localhost`; an empty user clears to the current account. `S` saves the
profile and `P` opens the saved-profile picker from inside the editor.

In line mode the editor prompts for target host, user, NTLM hash, domain,
attacker IP, password and mode, in that order.

## The menu

The interface has two levels. The top level lists categories; opening one lists
its actions. The screen shows:

- a header with the version, the administrator state and the active language;
- a target line with `Target`, `User`, `Mode` and `Session`;
- a breadcrumb: `AutoRDPwn` at the top level, `AutoRDPwn > <Category>` inside a
  category;
- a filter label when a filter is active;
- the list, with the selection highlighted;
- a detail pane with the selected item's title, id or action count, and up to
  two lines of description;
- a status line and the key legend.

The eight categories are:

| # | category | actions |
| --- | --- | --- |
| 1 | Quick actions | 8 |
| 2 | Remote Access | 6 |
| 3 | Passwords and hashes | 6 |
| 4 | Networking / Pivoting | 6 |
| 5 | Remote Desktop Forensics | 6 |
| 6 | Backdoors and persistence | 5 |
| 7 | Privilege escalation | 3 |
| 8 | Other modules | 7 |

47 actions in total. The category count and every per-category count are
computed from the catalog, not hard-coded, so the list always matches the
actions declared with `New-ARAction`.

## Keys in the full-screen menu

| key | top level | inside a category |
| --- | --- | --- |
| `Up` / `Down` | previous / next category | previous / next action |
| `PgUp` / `PgDn` | page through categories | page through actions |
| `Home` / `End` | first / last category | first / last action |
| `Enter` | open the category | run the action |
| `Right` | open the category | no effect |
| `Esc` / `Backspace` | clear the filter, then stay on top | clear the filter, then go back |
| `Left` | clear the filter, then stay on top | go back |
| `B` | no effect | go back to the category list |
| digits | select a category by position | select by position or jump to an action id |
| `/` | filter categories | filter actions in the category |
| `R` | clear the filter | clear the filter |
| `F` | no effect | pin or unpin the selected action |
| `T` | target editor | target editor |
| `P` | saved profiles | saved profiles |
| `S` | save the current target | save the current target |
| `L` | language picker | language picker |
| `F1` | contextual help | contextual help |
| `Q` / `X` | quit | quit |

Selection wraps at both ends for `Up` and `Down`; paging clamps at the first and
last row. The list height follows the console height, and the selection is kept
in view while scrolling.

`F1` draws a key sheet for the current level: category keys at the top level,
action keys inside a category. On a short console the sheet drops the trailing
notes, and on a very short one it switches to a compact key list.

### Action markers

Inside a category each row shows the position, a pin column, the action id in
brackets and the title:

```
>  3* [205] Lsass dump                                     [session]
```

- the `>` marker is the current selection;
- `*` means the action is pinned as a favourite;
- `[session]` appears when the action declares `NeedsSession` and no WinRM
  session is open yet. The action still runs; it asks the session helpers to
  open one.

## Favourites

`F` inside a category pins or unpins the selected action and writes the change
to `Resources\Tools\last.json` under `Favorites`. Pinned actions move to the top
of their category in the same order they had, so the two or three actions used
most sit above the rest without leaving the category. The status line confirms
`Added to favourites: <id>` or `Removed from favourites: <id>`. At the top level
`F` does nothing.

## Filtering and numeric selection

`/` opens an inline prompt under the list. Typing narrows the current level live
and the selection follows the filter. `Enter` keeps the filter, `Esc` drops it,
`Del` clears the input buffer and `Backspace` deletes one character. The active
filter appears beside the breadcrumb, and `R` clears it. Each level keeps its
own filter: opening a category remembers the category filter and restores the
action filter, and going back does the reverse.

At the top level a filter matches category titles and descriptions, and also
keeps a category when one of its actions matches. Inside a category the filter
matches action id, title and description, but the result is limited to the
actions of the category you are in: type `dump` inside Passwords and hashes and
you get 205 and 206, not the whole catalog.

Digits select by position in the visible list. When the digits match an action
id that is not a position, the menu jumps to that action and opens its category,
so `501` goes straight to Sticky Keys Hacking. The legacy aliases `11` to `17`
resolve to the first action of each original group (`101`, `201`, `301`, `401`,
`501`, `601`, `701`) when they are not read as a position.

## Saved profiles

`S` writes the current target to `Resources\Tools\targets.json` (or to
`%TEMP%\AutoRDPwn\Resources\Tools\targets.json` when the script runs outside a
repository). The default profile name is `<computer> - <user>`, or the computer
name when no user is set. Saving with an existing name replaces that entry.

Passwords and hashes are stored through `ConvertFrom-SecureString`, so the file
holds DPAPI blobs tied to the Windows account that saved them, not clear text.

`P` opens the picker: `Up`/`Down` move, `Home`/`End` jump, `Enter` loads the
highlighted profile, `Esc` or `Q` cancels. The picker shows the profile name,
the host, the user and the mode.

The name of the last saved or loaded profile is written to
`Resources\Tools\last.json`. At startup `Restore-ARLastProfile` reloads that
profile automatically and reports `Last profile loaded: <name>`; if the profile
no longer exists the status line says so and the previous target values stay.

## Language

`L` opens the language picker: English, Spanish, French, German, Italian,
Russian or Portuguese. `Up`/`Down` move, `Enter` selects, `Esc` cancels, and the
digits `1` to `7` select directly.

The full-screen picker writes the choice to `last.json`, and the next start
loads it before the first screen is drawn. `-lang` overrides the stored choice
for that run. Names, two-letter codes (`en`, `es`, `fr`, `de`, `it`, `ru`, `pt`)
and numbers are accepted; an unknown value resolves to English. The line-mode
language picker applies the choice for the current session and does not write
`last.json`.

## Line mode

With `-nogui`, or when standard input is redirected, the menu is drawn as
numbered lists and read from the prompt. At the top level type a category
number, `L` language, `T` target, `P` profiles, `S` save or `Q` quit. Inside a
category type an action number or id to run it, `B` (or `..`) to go back, or one
of the same single-letter commands. An action id entered directly, for example
`402`, runs that action regardless of the current category.

## Exiting

`Q` or `X` closes the menu. The application then runs `Invoke-ARCleanup` from a
`finally` block, which removes target artifacts unless `-noclean` was passed and
always removes operator-side traces. The process exits with code 0 on a clean
exit.
