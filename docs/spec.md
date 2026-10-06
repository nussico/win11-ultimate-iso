# Win11 Ultimate ISO Builder - Original Design Spec

Date: 2026-10-06. Historical design notes; the README describes the current tool (WPF GUI, Best SSD auto-install).

## Goal

A GUI tool that builds one bootable Windows 11 x64 ISO containing:
- the editions the user selects,
- multiple display languages as **language packs inside every edition** (language chosen in OOBE / Settings),
- CTT Win11 Creator / MicroWin-style patches, selectable per checkbox or via presets,
- an optional generated `autounattend.xml`.

For personal use. Project root: `D:\projects\win11-ultimate-iso`.

## Non-goals (v1)

- ARM64, Windows 10, Windows Server.
- Setup (WinPE) UI in multiple languages — setup runs in the base language; the language is picked in OOBE.
- User-saved presets (presets are a hashtable in code; adding one = a few lines).
- Removing Defender files (disable only).

## Tech

- PowerShell 5.1+ / 7, WinForms GUI, built-in DISM cmdlets / `dism.exe`.
- UUP dump API + its converter package (`uup-converter-wimlib`: aria2, wimlib, cdimage) for downloads.
- `oscdimg` from ADK if installed, else `cdimage` from the converter package.
- Self-elevates to admin.

## Files

```
Builder.ps1          # entry: elevation, GUI, presets, starts build job
lib\Source.ps1       # ISO detection, UUP dump download, language-pack fetch
lib\Patches.ps1      # one function per patch + protected/remove app lists
lib\Unattend.ps1     # autounattend.xml generation
lib\Build.ps1        # pipeline steps 1–9, mount/cleanup, ISO creation
Test-Build.ps1       # verifies a finished ISO
sources\             # user drops ISOs here
work\                # scratch, wiped each build
out\                 # ISO + build-log.txt + config.json
```

## GUI

Preset dropdown above tabs. Changing any box sets preset to "Custom".

**Tabs**
1. **Source & Languages** — ISO folder; "Download missing parts via UUP dump" + build selector (default: latest 25H2); base language (radio); language packs (checkboxes, all others).
2. **Editions** — Home, Pro, Education, Enterprise, (others found). Only those available from ISO or UUP are enabled; Enterprise marked "UUP only" when not in ISO.
3. **Patches** — groups: Setup bypasses, Debloat, Aggressive, Extras (see Patches).
4. **Unattended** — see Unattended.
5. **Build** — output path (default `out\Win11.iso`), "Split install.wim for FAT32 USB", Build/Cancel button, live log, progress bar (Step n/9).

Build runs in a background job; GUI stays responsive. Cancel → unmount with `/Discard`.

## Presets

| Preset | Ticks |
|---|---|
| Basic | Setup bypasses |
| Recommended | Basic + Debloat (without "Remove Xbox app") |
| CTT | Recommended + WinUtil shortcut + Unattended: skip all OOBE, run WinUtil after first login |
| Extreme | All patches incl. Aggressive and "Remove Xbox app" + CTT unattended options |

Presets never touch: languages, editions, account/region fields, auto-partition.

## Build pipeline

1. **Preflight** — admin, ≥ 60 GB free on work drive, `dism /Cleanup-Mountpoints`, wipe `work\`.
2. **Source** — copy ISO for base language to `work\iso\`; if none and UUP enabled, download + convert via UUP dump. Download language packs + basic FoDs (Basic, Spelling/Typing, Handwriting, OCR) for the **same build number**; mismatch → abort with clear error.
3. **Editions** — export selected indices from `install.wim`/`.esd` into a new `work\install.wim`.
4. **Per edition** — mount → add LPs → add FoDs → remove apps → registry patches (offline SYSTEM, SOFTWARE, default-user NTUSER.DAT) → file patches → drivers → `/Cleanup-Image /StartComponentCleanup` → unmount `/Commit`.
5. **boot.wim** — index 2: apply HW-check bypass; update `sources\lang.ini` with installed languages.
6. **Unattended** — write `autounattend.xml` to ISO root; post-install scripts to `sources\$OEM$\$$\Setup\Scripts\`.
7. **Compress** — export to final `install.wim` (max compression); if split ticked → `.swm` 3800 MB parts.
8. **ISO** — oscdimg/cdimage, BIOS (etfsboot.com) + UEFI (efisys.bin) dual boot.
9. **Finish** — `out\build-log.txt`, `out\config.json` (all GUI choices).

**Errors:** any failure → unmount all with `/Discard`, unload any loaded hives, log failing step, re-enable Build. `work\` kept for inspection.

## Patches

### Setup bypasses
| Box | Implementation |
|---|---|
| HW checks | `HKLM\SYSTEM\Setup\LabConfig`: BypassTPMCheck, BypassSecureBootCheck, BypassRAMCheck, BypassCPUCheck, BypassStorageCheck = 1; `HKLM\SYSTEM\Setup\MoSetup\AllowUpgradesWithUnsupportedTPMOrCPU = 1`. Applied to install.wim and boot.wim. |
| Local account | `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE\BypassNRO = 1`. GUI note: unattended local account is the reliable route on newer builds. |
| Skip privacy | `HKLM\SOFTWARE\Policies\Microsoft\Windows\OOBE\DisablePrivacyExperience = 1` |
| No BitLocker | `HKLM\SYSTEM\ControlSet001\Control\BitLocker\PreventDeviceEncryption = 1` |

### Debloat
| Box | Implementation |
|---|---|
| Bloat apps | `Remove-AppxProvisionedPackage` for exact names in `$RemoveApps`, each checked against `$ProtectedApps` first (match → skip + log). |
| Remove Xbox app | Removes `Microsoft.GamingApp` only. Off by default, Extreme only. |
| Telemetry | `Policies\Microsoft\Windows\DataCollection\AllowTelemetry = 0`; services DiagTrack, dmwappushservice `Start = 4`. |
| Ads/Copilot | `Policies\Microsoft\Windows\CloudContent\DisableWindowsConsumerFeatures = 1`; `Policies\Microsoft\Windows\WindowsCopilot\TurnOffWindowsCopilot = 1` (machine + default user); default-user `ContentDeliveryManager` suggestion values = 0. |
| OneDrive | Delete `Windows\System32\OneDriveSetup.exe`; remove `OneDriveSetup` from default-user `Run` key. |

`$RemoveApps` (exact names): Clipchamp.Clipchamp, Microsoft.BingNews, Microsoft.BingWeather, Microsoft.Getstarted, Microsoft.MicrosoftOfficeHub, Microsoft.MicrosoftSolitaireCollection, Microsoft.People, Microsoft.PowerAutomateDesktop, Microsoft.Todos, Microsoft.WindowsFeedbackHub, Microsoft.WindowsMaps, MSTeams, Microsoft.OutlookForWindows, Microsoft.Copilot, Microsoft.Windows.DevHome, MicrosoftCorporationII.MicrosoftFamily.

`$ProtectedApps` (never removed): Microsoft.WindowsStore, Microsoft.DesktopAppInstaller, Microsoft.VCLibs.*, Microsoft.UI.Xaml.*, Microsoft.NET.Native.*, Microsoft.WebView2/Microsoft.EdgeWebView*, Microsoft.SecHealthUI, Microsoft.StorePurchaseApp, Microsoft.HEIFImageExtension, Microsoft.VP9VideoExtensions, Microsoft.WebpImageExtension, Microsoft.AV1VideoExtension, Microsoft.LanguageExperiencePack*, Microsoft.WindowsCalculator, Microsoft.Windows.Photos, Microsoft.WindowsNotepad, Microsoft.WindowsTerminal, Microsoft.Paint, Microsoft.ScreenSketch, Microsoft.WindowsCamera, Microsoft.WindowsSoundRecorder, Microsoft.XboxIdentityProvider, Microsoft.Xbox.TCUI, Microsoft.XboxGamingOverlay, Microsoft.GetHelp.

### Aggressive
| Box | Implementation |
|---|---|
| Edge | Delete `Program Files (x86)\Microsoft\Edge`, `EdgeUpdate`, `EdgeCore`; policy `Policies\Microsoft\EdgeUpdate\DoNotUpdateToEdgeWithChromium = 1`. WebView2 untouched. |
| Defender | Services WinDefend, WdNisSvc, WdFilter, WdBoot, Sense `Start = 4`; `Policies\Microsoft\Windows Defender\DisableAntiSpyware = 1` + Real-Time Protection policies. Files kept. |
| Recall/AI | `Disable-WindowsOptionalFeature Recall`; `Policies\Microsoft\Windows\WindowsAI\DisableAIDataAnalysis = 1`. |

### Extras
| Box | Implementation |
|---|---|
| Drivers | `Add-WindowsDriver -Recurse` from chosen folder. |
| WinUtil | Public-desktop shortcut running `powershell -c "irm christitus.com/win \| iex"` (needs internet). |

## Unattended

Enabled by checkbox. Fields and defaults:
- Username `User`, password empty, auto-login off, administrator on.
- Computer name empty (= random), timezone default `W. Europe Standard Time`, keyboard + locale default = base language.
- Skip all OOBE (EULA, privacy, MS account, network) on.
- Skip edition selection off → dropdown of selected editions.
- Auto-partition disk 0 **off, never set by presets**; enabling shows a warning dialog at build time.
- Run WinUtil after first login (FirstLogonCommands); run custom script (copied into `$OEM$`); enable built-in Administrator off.

Password stored base64-encoded per unattend spec; the tab notes this is not encryption.

## Testing

- **Self-checks** (`-SelfTest` switch in each lib, `assert`-style): preset → checkbox mapping; protected list blocks every protected name; unattend XML is well-formed and contains chosen fields; ISO language/edition detection on a sample `Get-WindowsImage` output.
- **`Test-Build.ps1 <iso>`**: mounts ISO, verifies editions = selection, each index has the LPs (`Get-WindowsPackage`), registry values present in offline hives of index 1, protected apps still provisioned, `autounattend.xml` parses.
- **Manual once**: boot ISO in Hyper-V Gen 2 VM with TPM off → install succeeds, OOBE skipped, language switch available, debloat visible.

## Open risk

- **OOBE language selection:** assumed that OOBE offers a language choice when the image has multiple LPs; verify in the first VM test. Fallback: user picks the language in Settings after install.
- **BypassNRO:** may be ignored on current builds; the unattended local account covers it.
- **UUP dump:** API/converter changes can break downloads; ISO-only mode keeps working.
