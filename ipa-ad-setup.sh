#!/bin/sh

CONF=${CONF:-$1}
CONF=${CONF:-vm.conf}

if [ -f $CONF ] ; then
    . $CONF
fi

# unrar is from rpmfusion
# sudo yum localinstall -y http://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-stable.noarch.rpm
$SUDOCMD yum -y install unrar qemu-img kvm libvirt virt-manager libguestfs-tools

mkdir -p $WIN_DL_IMG_DIR
cd $WIN_DL_IMG_DIR
for file in $WIN_IMG_NAME.part01.exe $WIN_IMG_NAME.part02.rar $WIN_IMG_NAME.part03.rar ; do
    if [ ! -f $file ] ; then
        wget $WIN_URL/$file
    fi
done

if [ ! -f "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks/$WIN_IMG_NAME.vhd" ] ; then
    unrar x $WIN_IMG_NAME.part01.exe
fi

cd "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks"
if ! $SUDOCMD test -f $WIN_VM_DISKFILE ; then
    $SUDOCMD qemu-img convert -p -f vpc -O qcow2 $WIN_IMG_NAME.vhd $WIN_VM_DISKFILE
fi

# set administrator to auto-logon, and set the first RunOnce script
$SUDOCMD virt-win-reg --merge $WIN_VM_DISKFILE <<EOF
[HKLM\Software\Microsoft\Windows NT\CurrentVersion\Winlogon]
"AutoAdminLogon"="1"
"DefaultUserName"="$ADMINNAME"
"DefaultPassword"="$ADMINPASSWORD"

[HKLM\SYSTEM\Setup]
"UnattendFile"="$SETUP_PATH\\autounattend.xml"
EOF
# [HKLM\Software\Microsoft\Windows\CurrentVersion\RunOnce]
# "SetupPass1"="cmd /c $SETUP_PATH\\setupscript1.cmd > c:\\setuppass1.log 2>&1"

# [HKLM\SYSTEM\ControlSet001\Control\Session Manager\Environment]
# "WINDOWS_TRACING_FACILITY_POQ_FLAGS"="10000"

# [HKLM\SYSTEM\ControlSet002\Control\Session Manager\Environment]
# "WINDOWS_TRACING_FACILITY_POQ_FLAGS"="10000"

#[HKLM\SYSTEM\Setup]
#"CmdLine"="cmd /c $SETUP_PATH\\setupscript1.cmd > c:\\setuppass1.log 2>&1"

$MAKE_AD_VM_PATH/make-ad-vm.sh $CONF
