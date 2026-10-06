# autounattend.xml generation.

# Generic install keys (select the edition, do not activate).
$GenericKeys = @{
    'Windows 11 Home'       = 'YTMG3-N6DKC-DKB77-7M9GH-8HVX7'
    'Windows 11 Pro'        = 'VK7JG-NPHTM-C97JM-9MPGT-3V66T'
    'Windows 11 Education'  = 'YNMGQ-8RYV3-4PGQ3-C8XTP-7CFBY'
    'Windows 11 Enterprise' = 'XGVPP-NMH47-7TTHJ-W3FW7-8HV2C'
}

# Unattend "obfuscation" (base64 of UTF-16 password + suffix). Not encryption.
function ConvertTo-UnattendPassword($Pw, $Suffix) {
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes("$Pw$Suffix"))
}

# Local-account patch without unattended setup: newer builds ignore BypassNRO, so hide only the
# Microsoft account screens. Setup stays interactive and OOBE asks for a local user instead.
function New-LocalAccountXml {
    '<?xml version="1.0" encoding="utf-8"?><unattend xmlns="urn:schemas-microsoft-com:unattend"><settings pass="oobeSystem">' +
    '<component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">' +
    '<OOBE><HideOnlineAccountScreens>true</HideOnlineAccountScreens></OOBE></component></settings></unattend>'
}

function New-UnattendXml($u) {
    $esc = { param($s) [Security.SecurityElement]::Escape([string]$s) }
    $comp = { param($name, $body) "<component name=`"$name`" processorArchitecture=`"amd64`" publicKeyToken=`"31bf3856ad364e35`" language=`"neutral`" versionScope=`"nonSxS`">$body</component>" }

    # windowsPE pass
    # The user's own key wins; otherwise a generic key only to pre-select the edition.
    $k = if ($u.ProductKey) { $u.ProductKey } elseif ($u.Edition) { $GenericKeys[$u.Edition] }
    $key = ''
    if ($k) { $key = "<ProductKey><Key>$(& $esc $k)</Key><WillShowUI>OnError</WillShowUI></ProductKey>" }
    $pe = "<UserData>$key<AcceptEula>true</AcceptEula></UserData>"
    if ($u.AutoInstall -eq 'BestSsd') {
        # Script picks the disk and installs; if it exits without rebooting, normal Setup continues.
        $run = "cmd /c for %d in (C D E F G H I J K L M N O P Q R T U V Y Z) do if exist %d:\sources\autoinstall.js cscript //nologo %d:\sources\autoinstall.js `"$($u.Edition)`""
        $pe += "<RunSynchronous><RunSynchronousCommand wcm:action=`"add`"><Order>1</Order><Path>$(& $esc $run)</Path></RunSynchronousCommand></RunSynchronous>"
    }
    if ($u.AutoInstall -eq 'Disk0') {
        $pe += '<DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk><CreatePartitions>' +
        '<CreatePartition wcm:action="add"><Order>1</Order><Type>EFI</Type><Size>300</Size></CreatePartition>' +
        '<CreatePartition wcm:action="add"><Order>2</Order><Type>MSR</Type><Size>16</Size></CreatePartition>' +
        '<CreatePartition wcm:action="add"><Order>3</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition>' +
        '</CreatePartitions><ModifyPartitions>' +
        '<ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Format>FAT32</Format><Label>System</Label></ModifyPartition>' +
        '<ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID></ModifyPartition>' +
        '<ModifyPartition wcm:action="add"><Order>3</Order><PartitionID>3</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition>' +
        '</ModifyPartitions></Disk></DiskConfiguration>' +
        '<ImageInstall><OSImage><InstallTo><DiskID>0</DiskID><PartitionID>3</PartitionID></InstallTo></OSImage></ImageInstall>'
    }

    # specialize pass
    $cn = if ($u.ComputerName) { & $esc $u.ComputerName } else { '*' }

    # oobeSystem pass
    $pw = if ($u.Password) { "<Value>$(ConvertTo-UnattendPassword $u.Password 'Password')</Value><PlainText>false</PlainText>" }
          else { '<Value></Value><PlainText>true</PlainText>' }
    $group = if ($u.Admin) { 'Administrators' } else { 'Users' }
    $user = & $esc $u.UserName
    $oobe = ''
    if ($u.SkipOobe) {
        $oobe = '<OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>' +
        '<HideOnlineAccountScreens>true</HideOnlineAccountScreens><HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>' +
        '<HideLocalAccountScreen>true</HideLocalAccountScreen><ProtectYourPC>3</ProtectYourPC></OOBE>'
    }
    $logon = ''
    if ($u.AutoLogon) {
        $logon = "<AutoLogon><Enabled>true</Enabled><LogonCount>1</LogonCount><Username>$user</Username>" +
        "<Password><Value>$(ConvertTo-UnattendPassword $u.Password 'Password')</Value><PlainText>false</PlainText></Password></AutoLogon>"
    }
    $cmds = @()
    if ($u.EnableAdmin) { $cmds += 'net user Administrator /active:yes' }
    if ($u.CustomScript) { $cmds += 'powershell -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Setup\Scripts\custom.ps1' }
    if ($u.RunWinUtil) { $cmds += 'powershell -NoProfile -ExecutionPolicy Bypass -Command "irm christitus.com/win | iex"' }
    $flc = ''
    if ($cmds) {
        $i = 0
        $flc = '<FirstLogonCommands>' + (($cmds | ForEach-Object { $i++
            "<SynchronousCommand wcm:action=`"add`"><Order>$i</Order><CommandLine>$(& $esc $_)</CommandLine></SynchronousCommand>" }) -join '') + '</FirstLogonCommands>'
    }

    # Windows language (= ISO language), keyboard and formats. Set in both passes, otherwise Setup's first
    # page (windowsPE) and OOBE's region/keyboard pages still ask.
    $lang = & $esc $(if ($u.Language) { $u.Language } else { $u.Locale })
    $intl = "<InputLocale>$(& $esc $u.Keyboard)</InputLocale><SystemLocale>$(& $esc $u.Locale)</SystemLocale>" +
            "<UILanguage>$lang</UILanguage><UserLocale>$(& $esc $u.Locale)</UserLocale>"
    $intlPe = "<SetupUILanguage><UILanguage>$lang</UILanguage></SetupUILanguage>$intl"

    @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
<settings pass="windowsPE">$(& $comp 'Microsoft-Windows-International-Core-WinPE' $intlPe)$(& $comp 'Microsoft-Windows-Setup' $pe)</settings>
<settings pass="specialize">$(& $comp 'Microsoft-Windows-Shell-Setup' "<ComputerName>$cn</ComputerName>")</settings>
<settings pass="oobeSystem">$(& $comp 'Microsoft-Windows-International-Core' $intl)$(& $comp 'Microsoft-Windows-Shell-Setup' (
    "$oobe<UserAccounts><LocalAccounts><LocalAccount wcm:action=`"add`"><Name>$user</Name><Group>$group</Group><Password>$pw</Password></LocalAccount></LocalAccounts></UserAccounts>" +
    "$logon<TimeZone>$(& $esc $u.TimeZone)</TimeZone>$flc"))</settings>
</unattend>
"@
}
