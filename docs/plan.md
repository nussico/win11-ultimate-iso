# Win11 Ultimate ISO Builder — Implementation Plan

Spec: `docs/spec.md`. Execution: native (user said "do it").

## Constraints
- Must run on Windows PowerShell 5.1 (no `??`, ternary, `-Parallel`); ASCII-only source files (5.1 reads BOM-less files as ANSI).
- Needs admin; Builder self-elevates via `powershell.exe`.
- Offline registry edits only via `reg.exe` (no PowerShell handles left on loaded hives).

## Tasks
- [ ] 1. `lib\Patches.ps1` — patch catalog (`$Patches`), `$RemoveApps`, `$ProtectedApps`, `Test-ProtectedApp`, `Get-AppsToRemove`, `Get-Preset`, `Convert-RegPath`, `Invoke-Patches`, `Set-BootPatches`.
- [ ] 2. `lib\Unattend.ps1` — `New-UnattendXml $u` → string; generic keys per edition.
- [ ] 3. `lib\Source.ps1` — `ConvertTo-IsoInfo`, `Get-SourceIsos`, `Get-UupBuilds`, `Select-UupBuild`, `Get-UupLanguages`, `Save-UupLanguagePack`, `Save-UupIso`.
- [ ] 4. `tests\SelfTest.ps1` — asserts for 1–3 pure logic.
- [ ] 5. `lib\Build.ps1` — `Invoke-Build $cfg $sync` (steps 1–9, cleanup on error/cancel), `Get-Oscdimg`.
- [ ] 6. `Builder.ps1` — elevation, WinForms tabs, presets, runspace build, log/progress, cancel.
- [ ] 7. `Test-Build.ps1` — verify a finished ISO against `config.json`.
- [ ] 8. README with usage + known limits.

## Review focus
- Base ISO language not among scanned ISOs and UUP off → clear error, no partial build.
- LP build major != image build major → abort before mounting.
- Cancel mid-mount → images discarded, hives unloaded, Build button re-enabled.
- Protected app on removal list → skipped and logged.
- Auto-partition never set by preset; warning dialog before build.
