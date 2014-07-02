#!/bin/bash

set -o errexit
if [ -n "$VM_DEBUG" ] ; then
    set -x
fi

# first file is the global (i.e. not server specific) config

globalconf=$1
. $globalconf
shift

# ipa needs the ad conf files for cross domain trust setup
AD_CONF_FILES=""
IPA_CONF_FILES=""
for cf in "$@" ; do
    case "$cf" in
    ad*.conf) AD_CONF_FILES="$AD_CONF_FILES $cf" ;;
    ipa*.conf) IPA_CONF_FILES="$IPA_CONF_FILES $cf" ;;
    *) echo Unknown config file $cf - does not match 'ipa*.conf' or 'ad*.conf' ; exit 1 ;;
    esac
done

install_packages() {
    # unrar is from rpmfusion
    # sudo yum localinstall -y http://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-stable.noarch.rpm
    # unar is in f20
    PKGS_REQ=${PKGS_REQ:-"unar qemu-img qemu-kvm libvirt virt-manager libguestfs-tools virt-install"}
    PKGS_TO_INSTALL=${PKGS_TO_INSTALL:-""}

    for pkg in $PKGS_REQ ; do
        if rpm -q $pkg ; then
            echo package $pkg installed
        else
            PKGS_TO_INSTALL="$PKGS_TO_INSTALL $pkg"
        fi
    done
    if [ -n "$PKGS_TO_INSTALL" ] ; then
        $SUDOCMD yum -y install $PKGS_TO_INSTALL
    fi
    if rpm -q unar ; then
        echo using unar
    else
        $SUDOCMD yum -y install unrar
    fi

}

get_windows_image() {
    mkdir -p $WIN_DL_IMG_DIR
    pushd $WIN_DL_IMG_DIR
    for file in $WIN_IMG_NAME.part01.exe $WIN_IMG_NAME.part02.rar $WIN_IMG_NAME.part03.rar ; do
        if [ ! -f $file ] ; then
            wget $WIN_URL/$file
        fi
    done

    if type unrar ; then
        UNRAR=unrar
    else
        UNRAR=unar
    fi

    if [ ! -f "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks/$WIN_IMG_NAME.vhd" ] ; then
        $UNRAR x $WIN_IMG_NAME.part01.exe
    fi

    cd "$WIN_DL_IMG_DIR/$WIN_IMG_NAME/$WIN_IMG_NAME/Virtual Hard Disks"
    destfile=${WIN_VM_DISKFILE_BACKING:-$VM_IMG_DIR/$WIN_IMG_NAME.qcow2}
    if ! $SUDOCMD test -f $destfile ; then
        $SUDOCMD qemu-img convert -p -f vpc -O qcow2 $WIN_IMG_NAME.vhd $destfile
    fi
    popd
    # NOTE: On F20, when using a backing file + image, it seems that virt-win-reg somehow
    # corrupts the registry, which is used by other virt tools such as virt-cat and virt-ls,
    # which are used to test for setup/install completion - in this case, we can't use the
    # backing file, we just make a copy of it so we can write to it
    # we keep a copy of it for testing, so we can create other vms from the same source
    for cf in $AD_CONF_FILES ; do (
        . $cf
        if [ -z "$WIN_VM_DISKFILE_BACKING" -a -n "$WIN_VM_DISKFILE" ] ; then
            if ! $SUDOCMD test -f $WIN_VM_DISKFILE ; then
                $SUDOCMD cp $destfile $WIN_VM_DISKFILE
            fi
        fi
    ) done
}

gen_virt_mac() {
    echo 54:52:00`hexdump -n3 -e '/1 ":%02x"' /dev/random`
    # no longer supported :-(
    # python -c 'from virtinst.util import randomMAC; print randomMAC("qemu")'
}

get_next_ip_addr() {
    lastip=`$SUDOCMD virsh net-dumpxml $1 | fgrep "ip='$2"|sed "s/^.*ip='\([^']*\)'.*$/\1/"|sort -V|tail -1`
    if [ -z "$lastip" ] ; then
        echo $2.2
        return 0
    fi
    lastnum=`echo $lastip|cut -f4 -d.`
    echo $2.`expr $lastnum + 1`
    return 0
}

# $1 - network name - also used for bridge name
# $2 - domain name
# $3 - 3 element IP prefix e.g. 192.168.129
# $4 - hostname (not fqdn)
# $5 - MAC address
# this will define a new domain in dns with a new network
# The virt host will have the IP address xxx.xxx.xxx.1
# e.g. 192.168.129.2
# The given host will be added to the DNS with the IP address
# xxx.xxx.xxx.2 e.g. 192.168.100.2
# the network name should be a short, descriptive name, not
# the domain name
# the MAC address _must_ be the one passed to the --network mac=xxx
# argument of virt-install
# the network name _must_ be the one passed to the --network network=name
# argument of virt-install
create_virt_network2() {
    if $SUDOCMD virsh net-info $1 > /dev/null 2>&1 ; then
        echo virtual network $1 already exists
        $SUDOCMD virsh net-destroy $1
        $SUDOCMD virsh net-undefine $1
    fi
    netxml=`mktemp`
    cat > $netxml <<EOF
<network>
  <name>$1</name>
  <domain name='$2'/>
  <forward mode='nat'/>
  <bridge name='vir$1'/>
  <dns>
    <host ip='$3.2'>
      <!-- FQDN must come first -->
      <hostname>$4.$2</hostname>
      <hostname>$4</hostname>
    </host>
  </dns>
  <ip address='$3.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='$3.128' end='$3.254'/>
      <host mac='$5' name='$4' ip='$3.2'/>
    </dhcp>
  </ip>
</network>
EOF
    $SUDOCMD virsh net-define --file $netxml
    $SUDOCMD virsh net-start $1
#    $SUDOCMD service libvirtd restart
    rm -f $netxml
}

# this overrides the above - I don't know how to get 2 virtual networks
# to talk to each other, including IP/hostname resolution across all
# of them, without setting up my own DNS server and router
# so for now, just create a single virtual network for 192.168 and
# assign each sub-domain to a subnet
create_virt_network3() {
    # $1 must be the same - we are using the same virt network
    if $SUDOCMD virsh net-info $1 > /dev/null 2>&1 ; then
        echo using network $1
    else
        netxml=`mktemp`
        cat > $netxml <<EOF
<network>
  <name>$1</name>
  <forward mode='nat'/>
  <bridge name='vir$1'/>
  <dns>
  </dns>
  <ip address='192.168.0.1' netmask='255.255.0.0'>
    <dhcp>
      <range start='192.168.0.128' end='192.168.1.254'/>
    </dhcp>
  </ip>
</network>
EOF
        $SUDOCMD virsh net-define $netxml
        $SUDOCMD virsh net-start "$1"
        rm -f $netxml
    fi
    $SUDOCMD virsh net-update "$1" add ip-dhcp-host "<host mac='$5' name='$4' ip='$3.2'/>"
    # this doesn't work:
    # error: this function is not supported by the connection driver: can't update 'dns host' section of network 'netname'
    # $SUDOCMD virsh net-update "$1" add dns-host "<host ip='$3.2'><hostname>$4.$2</hostname><hostname>$4</hostname></host>"
    # so, resort to hacking xml <shudder>
    netxml=`mktemp`
    $SUDOCMD virsh net-dumpxml "$1" > $netxml
    sed -i -e "/<dns/ a\
\    <host ip='$3.2'><hostname>$4.$2</hostname><hostname>$4</hostname></host>
" $netxml
}

# do this in a sub-shell so we don't pollute the caller's environment
add_host_info() {
(
    . $1
    VM_MAC=${VM_MAC:-`gen_virt_mac`}
    if [ -z "$VM_IP" ] ; then
        VM_IP=`get_next_ip_addr $VM_NETWORK_NAME $VM_IP_PREFIX`
    fi
    cat >> $ipxml <<EOF
      <host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP'/>
EOF
    cat >> $dnsxml <<EOF
    <host ip='$VM_IP'>
      <hostname>$VM_NAME.$VM_DOMAIN</hostname>
      <hostname>$VM_NAME</hostname>
    </host>
EOF
)
}

create_virt_network() {
    # create virtual networks before creating hosts
    # each host is in two sections - the ip/dhcp section and the dns section
    VM_NETWORK_NAME=${VM_NETWORK_NAME:-ipaadtest}
    VM_NETWORK_IP=${VM_NETWORK_IP:-192.168.128.1}
    VM_NETWORK_MASK=${VM_NETWORK_MASK:-255.255.224.0}
    VM_NETWORK_RANGE=${VM_NETWORK_RANGE:-"start='192.168.128.2' end='192.168.128.254'"}
    if $SUDOCMD virsh net-info $VM_NETWORK_NAME > /dev/null 2>&1 ; then
        echo virtual network $VM_NETWORK_NAME already exists
        echo if you want to recreate it, run the following commands
        echo $SUDOCMD virsh net-destroy $VM_NETWORK_NAME
        echo $SUDOCMD virsh net-undefine $VM_NETWORK_NAME
        echo then run $0 again
        echo if you need to add VMs to the network, use $SUDOCMD virsh net-edit $VM_NETWORK_NAME
        echo "and add the <ip><dhcp><host> information, and the <dns><host> information"
        $SUDOCMD virsh net-start $VM_NETWORK_NAME || echo $VM_NETWORK_NAME is running
        return 0
    fi
    netxml=`mktemp`
    cat > $netxml <<EOF
<network>
  <name>$VM_NETWORK_NAME</name>
  <forward mode='nat'/>
  <bridge name='vir$VM_NETWORK_NAME'/>
EOF
    ipxml=`mktemp`
    cat > $ipxml <<EOF
  <ip address='$VM_NETWORK_IP' netmask='$VM_NETWORK_MASK'>
    <dhcp>
      <range $VM_NETWORK_RANGE/>
EOF
    dnsxml=`mktemp`
    cat > $dnsxml <<EOF
  <dns>
EOF
    for cf in "$@" ; do
        add_host_info "$cf"
    done
    cat $dnsxml >> $netxml
    echo '  </dns>' >> $netxml
    cat $ipxml >> $netxml
    echo '    </dhcp>' >> $netxml
    echo '  </ip>' >> $netxml
    echo '</network>' >> $netxml

    $SUDOCMD virsh net-define --file $netxml
    $SUDOCMD virsh net-start $VM_NETWORK_NAME
    rm -f $netxml $ipxml $dnsxml
}

# MAIN

install_packages || echo error installing packages

get_windows_image

create_virt_network "$@"

# Each AD needs the dns zone name and IP addr of each IPA server
# gather this information into a setup script
ss4dir=`mktemp -d`
trap "rm -rf $ss4dir" EXIT SIGINT SIGTERM
ss4=$ss4dir/setupscript4.cmd.in
cat > $ss4 <<EOF
echo Add IPA zone to windows DNS
EOF

for cf in $IPA_CONF_FILES ; do
    ( . $cf
    if [ -z "$VM_IP" ] ; then
        VM_IP=`$SUDOCMD virsh net-dumpxml $VM_NETWORK_NAME | grep "'"$VM_NAME"'"|sed "s/^.*ip='\([^']*\)'.*$/\1/"`
    fi
    cat >> $ss4 <<EOF
dnscmd 127.0.0.1 /ZoneAdd $VM_DOMAIN /Forwarder $VM_IP
EOF
    )
done

cat >> $ss4 <<EOF
@SETUP_PATH@\nextscript.cmd 5
EOF

# set up AD first - This is required for ipa trust-add to work
for cf in $AD_CONF_FILES ; do
    make-ad-vm.sh $globalconf $cf $ss4
done

# next, set up IPAs - give each IPA the AD conf files with
# admin name and password, domains, etc.
adconf=`mktemp`.conf
trap "rm -rf $ss4dir $adconf" EXIT SIGINT SIGTERM
cat > $adconf <<EOF
VM_EXTRA_FILES="\$VM_EXTRA_FILES $AD_CONF_FILES"
EOF

for cf in $IPA_CONF_FILES ; do
    setupvm.sh $globalconf $cf $adconf
done
