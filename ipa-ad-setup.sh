#!/bin/bash

set -o errexit

# first file is the global (i.e. not server specific) config

globalconf=$1
. $globalconf
shift

install_packages() {
    # unrar is from rpmfusion
    # sudo yum localinstall -y http://download1.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-stable.noarch.rpm
    # unar is in f20
    PKGS_REQ=${PKGS_REQ:-"unrar unar qemu-img qemu-kvm libvirt virt-manager libguestfs-tools"}
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
    if ! $SUDOCMD test -f $WIN_VM_DISKFILE_BACKING ; then
        $SUDOCMD qemu-img convert -p -f vpc -O qcow2 $WIN_IMG_NAME.vhd $WIN_VM_DISKFILE_BACKING
    fi
    popd
}

gen_virt_mac() {
    echo 54:52:00`hexdump -n3 -e '/1 ":%02x"' /dev/random`
    # no longer supported :-(
    # python -c 'from virtinst.util import randomMAC; print randomMAC("qemu")'
}

# $1 - network name - also used for bridge name
# $2 - domain name
# $3 - 3 element IP prefix e.g. 192.168.100
# $4 - hostname (not fqdn)
# $5 - MAC address
# this will define a new domain in dns with a new network
# The virt host will have the IP address xxx.xxx.xxx.1
# e.g. 192.168.100.1
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
        echo virtual network $1 already exists - undefining
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
    cat >> $ipxml <<EOF
      <host mac='$VM_MAC' name='$VM_NAME' ip='$VM_IP_PREFIX.2'/>
EOF
    cat >> $dnsxml <<EOF
    <host ip='$VM_IP_PREFIX.2'>
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
    VM_NETWORK_IP=${VM_NETWORK_IP:-192.168.0.1}
    VM_NETWORK_RANGE=${VM_NETWORK_RANGE:-"start='192.168.0.128' end='192.168.1.254'"}
    if $SUDOCMD virsh net-info $VM_NETWORK_NAME > /dev/null 2>&1 ; then
        echo virtual network $VM_NETWORK_NAME already exists - undefining
        $SUDOCMD virsh net-destroy $VM_NETWORK_NAME || echo network not running
        $SUDOCMD virsh net-undefine $VM_NETWORK_NAME || echo network not defined
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

create_virt_network "$@"

for cf in "$@" ; do
    # first, do ipa
    case `basename $cf` in ipa*) ;; *) continue ;; esac
    setupvm.sh $globalconf $cf
done

for cf in "$@" ; do
    # next, do ad
    case `basename $cf` in ad*) ;; *) continue ;; esac
    make-ad-vm.sh $globalconf $cf
done
