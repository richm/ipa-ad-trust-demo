#!/bin/sh

# this script is executed at the kickstart post-install phase
# inside of the chroot jail
# we can't do very much because systemd doesn't work
# so we set up the "real" post-install script to be
# run after the first boot into the new, real OS

# the user must provide a file in /root called *ipa*.conf
# which will provide the hostname, domain name, passwords, etc.

# set our selinux policy - NOTE: this is only needed during cloud
# init, to handle the cloud_init_t transitions
semodule -i /mnt/cloudinit.pp

mydir=`dirname $0`
for file in $mydir/*ipa*.conf ; do
    . $file
done

function getdomain() {
    dom=$(domainname)
    if [ -n "$dom" -a "$dom" != '(none)' ]; then
        echo $dom
        return 0
    fi
    awk '
        /^domain / {dom=$2 ; exit}
        /^search / {dom=$2 ; exit}
        END {if (!dom) {dom="local"}; print dom}
    ' /etc/resolv.conf
}

function getns() {
    awk '
        /^nameserver / {ns=$2 ; exit}
        END {if (!ns) {ns="127.0.0.1"}; print ns}
    ' /etc/resolv.conf
}

DOMAIN=$VM_DOMAIN
DOMAIN=${DOMAIN:-ipa.$(getdomain)}
REALM=$VM_REALM
REALM=${REALM:-$(echo $DOMAIN | tr 'a-z' 'A-Z')}
HOST=$VM_FQDN
HOST=${HOST:-$(hostname)}
FWDR=$VM_FORWARDER
FWDR=${FWDR:-$(getns)}

ipa-server-install -r "$REALM" -n "$DOMAIN" -p "$VM_ROOTPW" -a "$VM_ROOTPW" -N --hostname=$HOST --setup-dns --forwarder=$FWDR -U

touch $VM_WAIT_FILE
