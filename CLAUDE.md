# Win11 Ultimate ISO Builder

PowerShell + WPF app that builds a custom Windows 11 ISO (patches, UUP dump downloads, unattended setup, Best-SSD install).
Full architecture, file map and pitfalls: `.claude/agents/win11-iso-builder.md`. Read it before changing builder code.

## Rules (reviews check these)
- Every `.ps1`, `.xaml`, `.js` file: ASCII only (PS 5.1 reads BOM-less files as ANSI) and Windows PowerShell 5.1 compatible.
  No PS 7-only syntax (`??`, `?.`, ternary, `&&`/`||` pipeline chains, `-Parallel`) in shipped code. No new dependencies.
- Admin check via `IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`, never the localized group name.
- Patches must work in both modes: `Image` (offline mount) and `Setup` (runs as SYSTEM in specialize, `$Online = $true`).
  Every patch needs a `Desc`.
- Debloat never removes essentials (`$ProtectedApps`: Store, winget, runtimes, Security, Xbox identity, Game Bar...). Never weaken it.
- Never store secrets: password and product key stay out of config.json and presets.
- No activation or license-bypass tools; only the user's own key.
- New logic gets a check in `tests/SelfTest.ps1`.

## Checks
- `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Check.ps1`: parse, ASCII, XAML load, workflow pins, SelfTest.
  Windows only (WPF, `powershell.exe`). On a Linux runner, skip it; the Check workflow runs it on `windows-latest`.
- Installed builders only offer commits whose `selftest` job (check.yml) passed. Don't rename that job.
- Workflows: every `uses:` pinned to a full commit SHA with a `# vX.Y.Z` comment, the same SHA in every file
  (Check.ps1 enforces it). `lint.yml` runs actionlint + shellcheck on workflow changes.
- Real builds, UAC and `tests/Test-Build.ps1` need admin on Windows; say clearly what was not tested.
