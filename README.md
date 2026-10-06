# Win11 Ultimate ISO Builder

Build **one Windows 11 ISO** with the editions you want, in the language of your choice,
[CTT WinUtil](https://github.com/ChrisTitusTech/winutil) Win11 Creator-style patches and an optional unattended setup,
all from a dark, point-and-click GUI.

![Patches page](docs/screenshot.png)

## Install

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex
```

This downloads the builder to `Win11UltimateBuilder` on your drive with the most free space and starts it as admin.
Run the same line again to update; your ISOs, output and cache are kept.

Manual: download the repo ZIP, extract, right-click `Builder.ps1` -> *Run with PowerShell*.

## Features

- **Always newest**: picks the newest general Windows 11 release (today 26H2) and downloads it if your ISO is an older version.
- **Fast mode** (default): UUP downloads skip merging the latest update (~15 min instead of ~60). The ISO then holds the older base build (e.g. 26100) and Windows Update brings it up to date after setup; turn it off once for a fully current ISO. Downloaded ISOs are kept in `sources` and reused, so later builds skip the download either way.
- **Sources**: your own official ISOs, and/or automatic download through [UUP dump](https://uupdump.net)
  (Home, Pro, Education, Enterprise).
- **Language**: one language per ISO (setup and Windows); more can be added later in Windows Settings.
- **Presets**: Basic, Recommended, CTT, Extreme, or tick everything yourself.
- **Patches**
  - Setup bypasses: TPM / Secure Boot / RAM / CPU checks, local account, skip privacy screens, no auto-BitLocker
  - Debloat: preinstalled apps, telemetry, ads/tips/Copilot, OneDrive. Essential apps (Store, winget, Calculator, Photos, Xbox login, Game Bar...) are protected
  - Aggressive: remove Edge (keeps WebView2), disable Defender, disable Recall
  - Extras: inject drivers, CTT WinUtil shortcut
- **Unattended**: local account (default `User`), timezone, keyboard, skip OOBE, product key, run WinUtil or your own script after first login.
- **Automatic install**: *Best SSD* picks the one clear best internal disk (NVMe > SSD > HDD, never USB) with a 10 s cancel countdown, otherwise normal setup opens.

## Requirements

Windows 10/11, admin rights, about 60 GB free disk space, internet for UUP dump.
The first build installs the Windows ADK *Deployment Tools* (and, for *Best SSD*, the *WinPE add-on*) via winget.

## Presets

| Preset | Patches |
|---|---|
| Basic | setup bypasses |
| Recommended | + debloat (keeps the Xbox app) |
| CTT | + WinUtil shortcut; unattended: skip OOBE, run WinUtil |
| Extreme | everything incl. Edge / Defender / Recall and the Xbox app |

## Testing a build

```powershell
powershell -File tests\SelfTest.ps1      # logic checks, no admin needed
powershell -File Test-Build.ps1          # checks out\Win11.iso (admin)
```

Then install the ISO in a Hyper-V VM (Generation 2; it has no TPM by default, so it also tests the bypasses).

## Known limits

- Cancel takes effect between steps; a running DISM operation finishes first, then everything is unmounted and discarded.
- *Best SSD* auto-install needs UEFI; on legacy BIOS the normal setup opens.
- Activation: use your own key or the PC's existing digital license. No activation tools are included.

## Disclaimer

Not affiliated with Microsoft, Chris Titus Tech or UUP dump. Aggressive patches and automatic install can break things
or erase disks. Use at your own risk.

## License

[MIT](LICENSE)
