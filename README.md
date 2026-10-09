# Win11 Ultimate ISO Builder

Make your own Windows 11 ISO in a simple dark GUI: pick editions and language, tick the
[CTT WinUtil](https://github.com/ChrisTitusTech/winutil)-style tweaks you want, and optionally make setup install itself.

![Patches page](docs/screenshot.png)

## Install

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/nussico/win11-ultimate-iso/main/install.ps1 | iex
```

1. Confirm the admin prompt.
2. Pick a drive, or press **B** (or type a path) to pick a folder. Enter picks the best drive. Builds need about 60 GB free.
3. The builder opens. It lives in a new `Win11UltimateBuilder` folder on that drive or inside your folder.

Next time, start it with the **Win11 Ultimate ISO Builder** shortcut in that folder. Nothing is added to the Start menu or desktop.
When a new version is out, the builder asks if you want to update, and shows what's new
(or click **Update available** in the top bar later). Your ISOs and builds are kept.

Moved the folder? Right-click `Builder.ps1` > *Run with PowerShell* once to fix the shortcut.

## What it does

- **Newest Windows**: downloads the newest Windows 11 through [UUP dump](https://uupdump.net), or uses your own ISO.
  "Newest" means the newest version for every PC: versions only for certain new PCs (like 26H1) are skipped,
  but you can pick them under *Windows version*.
  *Download from*: **Microsoft** (default) gets the official ISO (an 8 GB download, about 10 minutes at 100 Mbit/s), and Windows Update installs the latest
  update after setup. **UUP dump** merges the latest update in (about 60 minutes) and also offers Enterprise.
  Either way the download is kept in `sources` and reused until a new Windows version comes out.
- **Small ISO (slower)** (Build page): saves the image as `install.esd` (strongest compression, about 10-20 extra minutes
  per edition). With Microsoft as the source and fewer editions ticked than its ISO has (Home, Pro, Education), it also
  downloads an image with just those from UUP dump (about 60 minutes instead of 10).
- **Editions and language**: Home, Pro, Education, Enterprise. One language per ISO. With UUP dump on, the build uses an ISO with exactly
  the ticked editions: tick only Pro and it downloads a Pro-only ISO once (kept in `sources` next to the others).
- **Patches**: no TPM/Secure Boot/CPU checks, local account, debloat, privacy, taskbar, Explorer, gaming and update tweaks.
  Optional: WSL, Hyper-V, Windows Sandbox, .NET 3.5, stay on this Windows version, no reserved storage.
  Essential apps (Store, winget, Calculator, Photos, Xbox login, Game Bar...) are never removed.
- **Patch mode**: *Into the image* (default, about 10 min per edition) or *During Windows setup* (like CTT's Win11 Creator):
  the ISO is ready in about 5 minutes and the patches run once while Windows installs (log: `C:\Windows\Setup\Scripts\Win11Ultimate-patches.log`).
- **Unattended setup**: account, timezone, keyboard, product key, Wi-Fi, winget apps (Steam, Discord...) and your own script after first login.
- **Automatic install**: *Best SSD* picks the fastest internal disk and installs with a 10 s cancel countdown.
- **Presets**: Basic, Recommended, CTT, Extreme, or your own: *Save* puts them in the `presets` folder and they show up in the preset list (drop shared `.json` presets there too). *Last build* repeats your last settings.
- **Fast rebuilds**: the finished image is cached, so changing only setup options takes a few minutes.
- **Plan**: the Build page shows the Windows version (e.g. 25H2), what gets downloaded, build time and disk space before you start.
- **Test in VM**: one click boots the ISO in Hyper-V.

Every ISO is named `W11U_<version>` and contains `Win11Ultimate.txt` (what was built) and a preset you can load to build it again.

| Preset | Patches |
|---|---|
| Basic | setup bypasses |
| Recommended | + debloat (keeps the Xbox app), OneDrive, privacy, file extensions, End task, no auto-restart, no background recording |
| CTT | + CTT's UI tweaks, services to manual, runs WinUtil after setup |
| Extreme | everything that removes or disables, incl. Edge, Defender, Recall and the Xbox app (features and the version pin stay opt-in) |

## Requirements

Windows 10/11, admin rights, about 60 GB free (15 GB for a cached rebuild), internet.
The first build installs the Windows ADK *Deployment Tools* via winget.

## Good to know

- The Wi-Fi password is stored in plain text on the ISO (never in your settings or presets).
- *Best SSD* needs UEFI; on legacy BIOS normal setup opens. Before building, the builder shows which disk it would erase on *this* PC.
- Cancel stops a Windows download right away. During the image steps it waits for the running DISM step to finish, then cleans up.
- Activation: your own key or the PC's digital license. No activation tools included.

## For developers

```powershell
powershell -File tests\Check.ps1         # what CI runs: parse, ASCII, XAML + logic checks, no admin
powershell -File tests\Test-Build.ps1    # checks out\Win11.iso (admin)
```

GitHub runs `tests\Check.ps1` on every push. Installed builders are only offered versions where it passed,
so a failing check means nobody gets that version.

Manual install: download the ZIP, extract, right-click `Builder.ps1` > *Run with PowerShell*.

## Disclaimer

Not affiliated with Microsoft, Chris Titus Tech or UUP dump. Aggressive patches and automatic install can break things
or erase disks. Use at your own risk. [MIT license](LICENSE).
