// Runs inside Windows Setup from <media>\sources\autoinstall.js, called by autounattend.xml:
//   cscript //nologo autoinstall.js "<edition>"
// JScript + WMI because Setup has no PowerShell (adding it needs the 1 GB WinPE add-on); cscript, WMI with the
// storage provider, diskpart, dism and bcdboot are all in the stock Setup boot.wim.
// Picks the best internal disk (NVMe > SSD > HDD), but only if the choice is unambiguous.
// Picked -> 10 s popup to cancel, then wipe it, apply the image, make it bootable, reboot. Not picked -> exit; normal Setup UI continues.

var GB = 1073741824;
// MSFT_PhysicalDisk codes. BusType: 7 USB, 12 SD, 13 MMC, 15 File Backed Virtual, 17 NVMe. MediaType: 4 SSD.
var SKIP_BUS = { 7: true, 12: true, 13: true, 15: true };

function contains(list, x) { for (var i = 0; i < list.length; i++) { if (list[i] == x) return true; } return false; }

// disks: [{ Number, BusType, MediaType, Size }], exclude: disk numbers never to touch. Returns a disk or null.
function selectTargetDisk(disks, exclude) {
    var top = [], best = 0;
    for (var i = 0; i < disks.length; i++) {
        var d = disks[i];
        if (SKIP_BUS[d.BusType] || d.Size < 64 * GB || contains(exclude, d.Number)) continue;
        var r = d.BusType == 17 ? 3 : d.MediaType == 4 ? 2 : 1;
        if (r > best) { best = r; top = [d]; } else if (r == best) { top.push(d); }
    }
    return top.length == 1 ? top[0] : null;
}

var sh = new ActiveXObject('WScript.Shell'), fso = new ActiveXObject('Scripting.FileSystemObject');

function log(s) {
    WScript.Echo(s);
    try { var f = fso.OpenTextFile('X:\\autoinstall.log', 8, true); f.WriteLine(s); f.Close(); } catch (e) { }
}

// Popups show even when Setup hides this console window. Returns the button clicked (-1 = timed out).
function say(s, secs, buttons) { log(s); return sh.Popup(s, secs, 'Win11 Ultimate - automatic install', buttons || 48); }

function run(cmd) { log('> ' + cmd); return sh.Run(cmd, 1, true); }

function main() {
    var edition = WScript.Arguments(0);
    var media = WScript.ScriptFullName.substr(0, 2);   // e.g. "D:"
    if (sh.RegRead('HKLM\\SYSTEM\\CurrentControlSet\\Control\\PEFirmwareType') != 2) { say('Legacy BIOS: automatic install skipped, choose the disk in setup.', 30); return; }

    var wmi = GetObject('winmgmts:\\\\.\\root\\Microsoft\\Windows\\Storage'), e;
    var mediaDisks = [];
    for (e = new Enumerator(wmi.ExecQuery('SELECT DiskNumber, DriveLetter FROM MSFT_Partition')); !e.atEnd(); e.moveNext()) {
        var l = e.item().DriveLetter;
        if (typeof l == 'number') l = String.fromCharCode(l);
        if (String(l).toUpperCase() == media.charAt(0).toUpperCase()) mediaDisks.push(e.item().DiskNumber);
    }
    var disks = [];
    for (e = new Enumerator(wmi.ExecQuery('SELECT DeviceId, FriendlyName, BusType, MediaType, Size FROM MSFT_PhysicalDisk')); !e.atEnd(); e.moveNext()) {
        var p = e.item(), n = parseInt(p.DeviceId, 10);
        if (!isNaN(n)) disks.push({ Number: n, BusType: p.BusType, MediaType: p.MediaType, Size: parseFloat(p.Size), Name: p.FriendlyName });
    }
    var disk = selectTargetDisk(disks, mediaDisks);
    if (!disk) {
        var seen = [];
        for (var j = 0; j < disks.length; j++) { var x = disks[j]; seen.push('Disk ' + x.Number + ': ' + x.Name + ', ' + Math.round(x.Size / GB) + ' GB, bus ' + x.BusType + ', media ' + x.MediaType); }
        say('No single best disk found, choose the disk in setup.\n\n' + (seen.join('\n') || 'No disks found.'), 60);
        return;
    }

    var target = 'Disk ' + disk.Number + ': ' + disk.Name + ' (' + Math.round(disk.Size / GB) + ' GB)';
    if (say('Installing Windows to ' + target + '.\n\nALL DATA ON THIS DISK WILL BE ERASED.\n\n' +
            'Starts by itself in 10 seconds. Click Cancel to stop and choose the disk in setup.', 10, 1 + 48) == 2) {
        log('Cancelled by user.'); return;
    }
    log('Installing to ' + target);

    var dp = fso.CreateTextFile('X:\\diskpart.txt', true);
    dp.Write(['select disk ' + disk.Number, 'clean', 'convert gpt', 'create partition efi size=300', 'format quick fs=fat32 label=System',
        'assign letter=S', 'create partition msr size=16', 'create partition primary', 'format quick fs=ntfs label=Windows', 'assign letter=W'].join('\r\n'));
    dp.Close();
    var rc = run('diskpart /s X:\\diskpart.txt');
    if (rc) throw new Error('diskpart failed (' + rc + ')');

    var wim = media + '\\sources\\install.wim', swm = '';
    if (!fso.FileExists(wim)) { wim = media + '\\sources\\install.swm'; swm = ' /SWMFile:' + media + '\\sources\\install*.swm'; }
    log('Applying ' + edition + '...');
    rc = run('dism /Apply-Image /ImageFile:' + wim + swm + ' /Name:"' + edition + '" /ApplyDir:W:\\');
    if (rc) throw new Error('dism failed (' + rc + '), is "' + edition + '" in the image?');
    rc = run('bcdboot W:\\Windows /s S: /f UEFI');
    if (rc) throw new Error('bcdboot failed (' + rc + ')');

    if (!fso.FolderExists('W:\\Windows\\Panther')) fso.CreateFolder('W:\\Windows\\Panther');
    fso.CopyFile(media + '\\autounattend.xml', 'W:\\Windows\\Panther\\unattend.xml', true);
    var oem = media + '\\sources\\$OEM$\\$$';
    if (fso.FolderExists(oem)) { run('robocopy "' + oem + '" W:\\Windows /E /NFL /NDL /NJH /NJS'); }
    log('Done, rebooting...');
    sh.Run('wpeutil reboot', 0, true);
}

if (!this.TESTING) {
    try { main(); } catch (err) { say('Automatic install failed: ' + (err.message || err) + '\n\nChoose the disk in setup instead.', 120, 16); WScript.Quit(1); }
}
