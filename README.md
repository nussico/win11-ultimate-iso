# Win11 Ultimate ISO Builder

GUI that builds one Windows 11 x64 ISO with the editions you pick, extra display languages
(language packs inside every edition), CTT Win11 Creator-style patches and an optional `autounattend.xml`.

## Use

1. Optional: put official Windows 11 ISOs into `sources\` (Microsoft download page, one per base language).
2. Right-click `Builder.ps1` -> *Run with PowerShell* (it elevates itself).
3. Pick a preset, languages, editions, unattended options -> **Build** tab -> **Build ISO**.
4. Result: `out\Win11.iso`, `out\build-log.txt`, `out\config.json` (no password/key stored).
5. Check it (admin): `powershell -File Test-Build.ps1`

Without an ISO, enable *Download missing parts via UUP dump* and the base image is downloaded and converted
(Home/Pro direct, Education/Enterprise as virtual editions). Language packs always come from UUP dump and are
cached in `cache\`. The first build installs the ADK Deployment Tools (`oscdimg`) via winget if missing.

Needs: admin, ~60 GB free on the project drive, internet for UUP/LPs.

## Presets

| Preset | Patches |
|---|---|
| Basic | setup bypasses |
| Recommended | + debloat (keeps Xbox app) |
| CTT | + WinUtil shortcut, unattended: skip OOBE, run WinUtil |
| Extreme | everything incl. Edge/Defender/Recall and Xbox app (not drivers) |

Debloat only removes the exact names in `$RemoveApps` (`lib\Patches.ps1`); anything matching `$ProtectedApps`
(Store, winget, frameworks, Calculator, Photos, Xbox login/Game Bar, ...) is never removed.

## Files

`Builder.ps1` GUI · `lib\Patches.ps1` patches/presets · `lib\Unattend.ps1` unattend XML · `lib\Source.ps1` ISO scan + UUP ·
`lib\Build.ps1` pipeline · `tests\SelfTest.ps1` logic checks · `Test-Build.ps1` ISO checks

## Known limits

- Language packs are added after the image's cumulative update; some strings stay untranslated until the next Windows Update.
- Setup itself (the WinPE installer) stays in the base language; the language is picked in OOBE or Settings.
- Cancel takes effect between steps/editions (a running DISM call is not interrupted); mounted images are then discarded.
- Auto-partition wipes disk 0 of any PC booted from the ISO.
- Activation: enter your own key in the Unattended tab, or rely on the PC's existing digital license.
