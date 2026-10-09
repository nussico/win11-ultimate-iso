// Runs inside Windows Setup from <media>\sources\autoinstall.js, called by autounattend.xml:
//   cscript //nologo autoinstall.js "<edition>"
// JScript + WMI because Setup has no PowerShell (adding it needs the 1 GB WinPE add-on); cscript, WMI (cimv2),
// diskpart, dism and bcdboot are all in the stock Setup boot.wim.
// Picks the best internal disk (NVMe > SSD > HDD), but only if the choice is unambiguous.
// Picked -> 10 s popup to cancel, then wipe it, apply the image, make it bootable, reboot. Not picked -> exit; normal Setup UI continues.

var GB = 1073741824;

function contains(list, x) { for (var i = 0; i < list.length; i++) { if (list[i] == x) return true; } return false; }

// One Win32_DiskDrive row -> { Number, Name, Size, Kind }. Win32_DiskDrive because the storage WMI classes
// (MSFT_PhysicalDisk) return nothing inside Setup. NVMe disks have VEN_NVME in their device ID.
// ponytail: SATA SSD vs HDD is guessed from the model name ("SSD"); a tie just opens normal setup.
function toDisk(index, model, iface, pnp, mediaType, size) {
    var id = String(pnp).toUpperCase(), m = String(model);
    var kind = iface == 'USB' || /^(USBSTOR|SD|SDBUS)\\/.test(id) || /Removable|External/i.test(mediaType) ? 'USB/removable'
        : /VEN_NVME/.test(id) || /NVME/i.test(m) ? 'NVMe' : /SSD/i.test(m) ? 'SSD' : 'HDD/other';
    return { Number: index, Name: m, Size: parseFloat(size) || 0, Kind: kind };
}

var RANK = { 'NVMe': 3, 'SSD': 2, 'HDD/other': 1 };

// disks: toDisk() results, exclude: disk numbers never to touch. Returns the single best disk or null.
function selectTargetDisk(disks, exclude) {
    var top = [], best = 0;
    for (var i = 0; i < disks.length; i++) {
        var d = disks[i], r = RANK[d.Kind];
        if (!r || d.Size < 64 * GB || contains(exclude, d.Number)) continue;
        if (r > best) { best = r; top = [d]; } else if (r == best) { top.push(d); }
    }
    return top.length == 1 ? top[0] : null;
}

function readDisks(wmi) {
    var disks = [];
    for (var e = new Enumerator(wmi.ExecQuery('SELECT Index, Model, InterfaceType, PNPDeviceID, MediaType, Size FROM Win32_DiskDrive')); !e.atEnd(); e.moveNext()) {
        var p = e.item();
        disks.push(toDisk(p.Index, p.Model, p.InterfaceType, p.PNPDeviceID, p.MediaType, p.Size));
    }
    return disks;
}

function describe(d) { return 'Disk ' + d.Number + ': ' + d.Name + ', ' + Math.round(d.Size / GB) + ' GB, ' + d.Kind; }

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

    var wmi = GetObject('winmgmts:\\\\.\\root\\cimv2'), e;
    var mediaDisks = [];   // disk holding the install media (a USB stick is skipped anyway; a DVD has none)
    try {
        for (e = new Enumerator(wmi.ExecQuery('ASSOCIATORS OF {Win32_LogicalDisk.DeviceID="' + media + '"} WHERE AssocClass=Win32_LogicalDiskToPartition')); !e.atEnd(); e.moveNext()) {
            mediaDisks.push(e.item().DiskIndex);
        }
    } catch (ex) { }
    var disks = readDisks(wmi);
    var disk = selectTargetDisk(disks, mediaDisks);
    if (!disk) {
        var seen = [];
        for (var j = 0; j < disks.length; j++) { seen.push(describe(disks[j]) + (contains(mediaDisks, disks[j].Number) ? ', install media' : '')); }
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
    if (!fso.FileExists(wim)) { wim = media + '\\sources\\install.esd'; }   // Small ISO
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

// The builder runs this file with PREVIEW = true on the PC it runs on: prints the pick and all disks, changes nothing.
if (this.PREVIEW) {
    var all = readDisks(GetObject('winmgmts:\\\\.\\root\\cimv2')), pick = selectTargetDisk(all, []);
    WScript.Echo(pick ? 'PICK ' + describe(pick) : 'NOPICK');
    for (var k = 0; k < all.length; k++) WScript.Echo(describe(all[k]));
} else if (!this.TESTING) {
    try { main(); } catch (err) { say('Automatic install failed: ' + (err.message || err) + '\n\nChoose the disk in setup instead.', 120, 16); WScript.Quit(1); }
}
