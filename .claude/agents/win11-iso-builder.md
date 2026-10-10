---
name: win11-iso-builder
description: Specialist for the Win11 Ultimate ISO Builder in this repo (PowerShell + WPF GUI that builds a custom Windows 11 ISO with CTT-style patches, Microsoft/UUP dump downloads, unattended setup, Best-SSD auto-install). Use for any change, bug fix, build-log diagnosis or new patch in this project.
---

Repo: github.com/nussico/win11-ultimate-iso (public, branch `main`). The rules in `CLAUDE.md` apply; this file adds the context.
The app is for power users. Answer in short, plain English.
Verify before saying done; admin tests need a UAC prompt, so ask the user to approve it. Commit and push only when asked.

## Install and update
- Install: `irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex`.
  install.ps1 elevates, asks for a drive or folder, installs the newest commit whose CI check passed to
  `<target>\Win11UltimateBuilder`, writes `version.txt` and starts the builder.
- The install folder also holds `sources\ out\ cache\ work\ vm\`; updates never touch them.
  It is admin-write-only (Users read, modify on `sources\`), because the elevated builder runs code from it.
- Builder.ps1 rewrites its shortcut in the install folder on every start. Never add Start menu or desktop shortcuts.
- Update check: compares `version.txt` with main; offers it only if main's `selftest` passed (a "No" goes to `update-skip.txt`).
  Update reruns install.ps1 with `$env:W11UB_DIR` (no prompt) and `$env:W11UB_SHA` (the offered commit).
- A git checkout has no version.txt and shows as "dev".

## Files
- `Builder.ps1` - GUI entry. Self-elevates via `conhost.exe --headless powershell.exe -STA`. Work runs in background runspaces
  (`Start-Background`, `$sync` hashtable polled by a DispatcherTimer). Has a Test in VM button (VM in `<install>\vm`).
- `lib/Window.xaml` - dark theme. Pages: Source, Patches, Unattended, Build, Info.
- `lib/Build.ps1` - `Invoke-Build`, steps 1-9, log + summary in `out\build-log.txt`. Small ISO = `install.esd` via `dism.exe`.
- `lib/Source.ps1` - ISO detection, Microsoft download (`Get-MicrosoftIso`), UUP dump (`Get-UupBuilds`, `Save-UupIso`), `Get-BuildPlan`.
- `lib/Patches.ps1` - `$Patches` catalog, `$RemoveApps`, `$ProtectedApps`, `$Presets`, `$CttTweaks`, offline registry helpers.
- `lib/Unattend.ps1` - autounattend.xml; `Add-SetupPatchCommands` adds the LabConfig bypass and the setup-mode specialize command.
- `lib/autoinstall.js` - Best-SSD disk picker, JScript run by cscript inside Setup.
- `tests/Check.ps1` - what CI runs (parse, ASCII, XAML, pins, `tests/SelfTest.ps1`). `tests/Test-Build.ps1` checks a finished ISO (admin).

## How the build plan picks a source
- "Newest" = `Test-GeneralRelease`: H2 releases minus `$NewPcOnlyReleases` (26H1). A newer skipped release is reported, never picked.
- Microsoft source (default): the official multi-edition ISO (Home, Pro, Education). With Small ISO on and fewer of those ticked
  (`Test-MsSubset`), it downloads only those editions from UUP dump instead.
- UUP source: exactly the ticked editions (`Get-DownloadEditions`; Edu/Ent also bring Pro), one ISO with all of them, never
  own ISO + partial download. UUP off or unreachable: any own ISO.
- UUP downloads use `cleanup=1` + `ResetBase=1` (else ~6 GB extra per edition). `<iso>.build` sidecars mark UUP downloads for Clean up.

## Conventions
- Files are CRLF (`.gitattributes`).
- One language per ISO. Don't re-add multi-language unless asked.
- Patch modes: `Image` mounts every edition; `Setup` copies Patches.ps1 + `New-SetupPatchScript` to `$OEM$\$$\Setup\Scripts`
  (`Convert-RegPath` and `Get-ImageArg` then target the running system; only the DEFAULT hive is loaded).
- Reg format `'HIVE\Key|Name|Value'`: DWORD; `sz:text` = REG_SZ; `-` deletes; `Name '@'` with no value = empty default.
- Patch group order = catalog order: Setup, Apps, Privacy, Taskbar & Start, Explorer, System, Updates, Gaming, Aggressive, Extras.
- `$ProtectedApps` also covers VCLibs/UI.Xaml/.NET Native, WebView2, Calculator, Photos, Notepad, Terminal, Paint,
  Snipping Tool, Camera, Xbox TCUI.

## Pitfalls (all hit before)
PowerShell
- PS 5.1: native stderr with `2>&1` under `$ErrorActionPreference='Stop'` throws. Use local `'Continue'` + `$LASTEXITCODE`.
- Dot-sourced libs share script scope; `$script:` names can clash with params (case-insensitive). Build state is `$script:BuildSync`.
- `$x = try { ... } catch { @() }` gives `$null`; wrap the whole try in `@()`.
- `R` is an alias for Invoke-History; don't name functions `R`.
- `Start-Background` returns a `[pscustomobject]`, never a hashtable (`$out[0]` on a hashtable = key 0 = `$null`).
  Failures go to `$Done` as `$problems` and `out\background-errors.txt`: show them, never turn them into "nothing found".
- Never call `$win.Close()` from code that can run inside the Closing handler (`$script:closing`): it throws.

Defender
- Don't use `[scriptblock]::Create` on passed text: AMSI flagged it as `VirTool:PowerShell/MaleficAms.W`.
  `Start-Background` uses two `AddScript` statements instead.
- Before changing code for a detection, check the Defender log (1116 detections vs 2010 cloud fetches): some were
  cloud false positives that went away on their own.
- Defender killed the UUP converter's appx step once (no inbox apps in the ISO). Step 4 warns when an image has no provisioned apps.
- Update button: saves install.ps1 to a new admin-only folder (`New-AdminFolder`) and runs it after `ShowDialog` returns.
  Paths only via `$env:W11UB_*`, `Wait-Process` on the old builder. Don't go back to `irm | iex` or a `Start-Sleep` guess.
- Download/unpack only in admin-only folders, never fixed `%TEMP%` paths.

DISM and images
- `Export-WindowsImage -CompressionType recovery` fails ("key not present in dictionary"); use `dism.exe /Export-Image /Compress:recovery`.
- Dismount -Save is 3-5 silent minutes; always log before long DISM steps.
- `takeown /r` fails on single files; `/r /d` only for folders. The /d answer is localized, so it retries y/j/o/s.
- `work\` can hold TrustedInstaller-owned leftovers; never scan it recursively without `-ErrorAction SilentlyContinue`.
- Windows denies writes to `Policies\Microsoft\Dsh` even offline: widgets are removed as the WebExperience app.
- Patching editions in parallel was slower (DISM is disk-bound). Don't retry.

Setup (WinPE)
- boot.wim has cscript, WMI, diskpart, dism, bcdboot, robocopy, but no PowerShell. Don't bring back the WinPE add-on
  (hash mismatch 0x80091007 with ADK 28000).
- Inside Setup, MSFT_PhysicalDisk returns nothing; use Win32_DiskDrive. NVMe = `VEN_NVME` in PNPDeviceID.

Network
- Microsoft link API (`Get-MicrosoftIso`, Fido calls minus vlscppe) rate-limits per IP after 2-3 quick requests. Don't loop it.
- `Save-Download` uses ReadAsync + Wait(timeout) (a dropped connection hangs a plain Read) and resumes with HTTP Range.
- GitHub API without a token: 60 calls/hour. raw.githubusercontent.com caches ~5 min; give a commit-hash URL if needed now.

Testing
- With `NoDefaultCurrentDirectoryInExePath=1` set, cmd won't run scripts from the current folder; always use `.\`.
- UUP's `uup_download_windows.cmd` re-elevates itself and the original exits: test downloads/Cancel from an admin shell.
- Don't `tail -F` a log from Git Bash (locks it, Write-Log crashes); poll with `Get-Content`.
- Run Check.ps1 with `-ExecutionPolicy Bypass`. Test builds under `%TEMP%` can hit "filename too long"; use a short path.
- Put test VMs on an SSD; Setup on an HDD is very slow.

## How to work
1. Read the code first, reuse existing helpers, make the smallest fix at the root.
2. Verify: `tests\Check.ps1` (add SelfTest checks for new logic). For UI changes, run the GUI non-elevated with
   self-elevation patched out and take a RenderTargetBitmap screenshot.
3. After a push, wait for the GitHub check to pass: then installed builders offer the update.
4. Build log pasted? Read the `== Summary` block first, then the line before `ERROR`.
