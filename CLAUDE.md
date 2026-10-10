# Win11 Ultimate ISO Builder

PowerShell + WPF app that builds a custom Windows 11 ISO: patches, Microsoft/UUP dump downloads, unattended setup, Best-SSD install.
Before changing builder code, read `.claude/agents/win11-iso-builder.md` (architecture, file map, pitfalls).

## Rules (reviews check these)
- `.ps1`, `.xaml`, `.js`: ASCII only and Windows PowerShell 5.1 compatible. Shipped code: no `??`, `?.`, ternary, `&&`/`||`, `-Parallel`.
- No new dependencies.
- Admin check: `IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`, never the (localized) group name.
- Patches must work in `Image` mode (offline mount) and `Setup` mode (SYSTEM in specialize, `$Online = $true`). Every patch needs a `Desc`.
- Never weaken `$ProtectedApps` (Store, winget, runtimes, Security, Xbox identity, Game Bar...).
- No secrets in config.json or presets (password, product key).
- No activation or license-bypass tools; only the user's own key.
- New logic gets a check in `tests/SelfTest.ps1`.

## Checks
- `powershell -NoProfile -ExecutionPolicy Bypass -File tests\Check.ps1`: parse, ASCII, XAML, workflow pins, SelfTest.
  Windows only; on a Linux runner skip it (the Check workflow runs it on `windows-latest`).
- Don't rename the `selftest` job in check.yml: installed builders only offer commits where it passed.
- Every workflow `uses:` is pinned to a full SHA with a `# vX.Y.Z` comment, same SHA in every file (Check.ps1 enforces it).
  `lint.yml` runs actionlint + shellcheck on workflow changes.
- Real builds, UAC and `tests/Test-Build.ps1` need admin; say clearly what was not tested.

## Agent skills
- Issue tracker: GitHub Issues on `nussico/win11-ultimate-iso` via `gh`. See `docs/agents/issue-tracker.md`.
- Triage labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.
- Domain docs: single-context, `CONTEXT.md` + `docs/adr/` at the root (created when needed). See `docs/agents/domain.md`.
