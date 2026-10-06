// Runs inside Windows Setup from <media>\sources\autoinstall.js, called by autounattend.xml:
//   cscript //nologo autoinstall.js "<edition>"
// JScript + WMI because Setup has no PowerShell (adding it needs the 1 GB WinPE add-on); cscript, WMI with the
// storage provider, diskpart, dism and bcdboot are all in the stock Setup boot.wim.
// Picks the best internal disk (NVMe > SSD > HDD), but only if the choice is unambiguous.
// Picked -> wipe it, apply the image, make it bootable, reboot. Not picked -> exit; normal Setup UI continues.

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

function run(cmd) { log('> ' + cmd); return sh.Run(cmd, 1, true); }

function main() {
    var edition = WScript.Arguments(0);
    var media = WScript.ScriptFullName.substr(0, 2);   // e.g. "D:"
    if (sh.RegRead('HKLM\\SYSTEM\\CurrentControlSet\\Control\\PEFirmwareType') != 2) { log('Legacy BIOS: auto-install skipped, use the normal setup.'); return; }

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
    if (!disk) { log('No single best disk found: continuing with the normal setup.'); return; }

    log('');
    log('Installing to disk ' + disk.Number + ': ' + disk.Name + ' (' + Math.round(disk.Size / GB) + ' GB)');
    WScript.Echo('ALL DATA ON THIS DISK WILL BE ERASED. Press Ctrl+C within 10 seconds to cancel.');
    for (var i = 10; i > 0; i--) { WScript.StdOut.Write(i + ' '); WScript.Sleep(1000); }
    WScript.Echo('');

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
    try { main(); } catch (err) { log('Auto-install failed: ' + (err.message || err)); WScript.Sleep(30000); WScript.Quit(1); }
}
