# Tests

Static and data-contract tests for AutoRDPwn. Nothing here touches the network,
needs elevation, or runs a catalog action: every check reads the PowerShell AST,
writes fixtures under `$env:TEMP`, or compiles `src\` into `_sandbox\gen.ps1`.

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Tests\Run-Tests.ps1
pwsh -NoProfile -File .\Tests\Run-Tests.ps1
```

Exit code `0` when nothing failed, `1` otherwise. Skips are drift warnings and do
not change the exit code.

Options:

| flag | effect |
| --- | --- |
| `-Filter 'Catalog*'` | only run test files whose name matches |
| `-Detailed` | print every test, not just failures and skips |
| `-NoBuild` | reuse the existing `_sandbox\gen.ps1` |

## Build gate

`Build.ps1` without `-OutputPath` overwrites `AutoRDPwn.ps1`. The runner always
passes `-OutputPath _sandbox\gen.ps1`, and `Drift.Tests.ps1` fails if any file in
`Tests\` invokes `Build.ps1` without `-OutputPath`.

## Groups

Group names come from the `Describe` block, plus `build` and `legacy`, which the
runner adds itself.

| group | contract |
| --- | --- |
| `build` | `src\` compiles into `_sandbox\gen.ps1` (skipped with `-NoBuild`) |
| `parse` | every `.ps1` on disk parses, including `_sandbox\gen.ps1` |
| `catalog` | action ids are unique, handlers exist in `src\`, documented ids exist |
| `port preflight` | PSexec, WMI, WinRM, WinRS and Quick Screen call `Assert-ARPort` |
| `profiles` | `targets.json` / `last.json` shape, mode values, DPAPI round trip |
| `localization` | one key set across seven languages, referenced keys resolve |
| `regressions` | bugs that were already fixed once (text guards on `src\`) |
| `cleanup` | `Invoke-ARCleanup` outer traces are not behind `-noclean`, and it stays idempotent |
| `option mode` | `-option` runs never prompt: the input helpers throw instead |
| `build drift` | build hygiene; `src\` vs the versioned build (warning only) |
| `legacy` | `Test-Tui.ps1` render suite, run in a child process |

`legacy` only runs with the default `-Filter '*'`.

## Adding a test

Create a `*.Tests.ps1` file in this folder. The runner dot-sources every match in
one scope, so a file only needs `Describe` and `It` blocks:

```powershell
Describe 'my contract' {
    It 'holds for the runtime' {
        $function = Get-ArFunctionAst -Name 'Invoke-ARCleanup'
        Assert-NotNull $function 'Invoke-ARCleanup is not defined in src'
    }
}
```

Blocks available from `TestKit.ps1`:

- `It` — a normal test; a throw is a failure.
- `It-Skip` — records a skip with a reason, no block.
- `It-Warn` — passes when the block passes, records a skip when it throws. Use it
  for drift against work that is still in flight.

Assertions: `Assert-True`, `Assert-False`, `Assert-Equal`, `Assert-Match`,
`Assert-NotMatch`, `Assert-NotNull`, `Assert-FileExists`, `Assert-SetEqual`. Each
one takes a message that names the contract, so a failure explains itself.

Helpers: `TestKit.ps1` (assertions, results, `New-ArTestTempDirectory`,
`Clear-ArTestTempDirectories`) and `ArAst.ps1` (function lookup, guarded ranges,
marker searches). Use `$script:ArTestRoot` for repository paths and temp
directories for fixtures — never write inside the repository.

## Engine

The suite uses its own engine instead of Pester. Windows ships Pester 3.4.0,
which has no `-Skip`, and this suite has to report drift as a warning rather than
a failure. Pester is still detected and reported in the header, and installing
Pester does not change the result.
