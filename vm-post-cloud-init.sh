#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

# set our selinux policy - NOTE: this is only needed during cloud
# init, to handle the cloud_init_t transitions
if semodule -l |grep cloudinit ; then
    echo cloudinit selinux module installed - skipping
else
    semodule -i /mnt/cloudinit.pp
fi

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
        END {if (!dom) {dom="test"}; print dom}
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
netbios=`echo $DOMAIN | sed -e 's/\.//g' | tr '[a-z]' '[A-Z]'`
VM_NETBIOS_NAME=${VM_NETBIOS_NAME:-"$netbios"}

# ipa setup needs a lot of entropy
# use rngd to provide a lot of entropy in /dev/random
# this requires setting up a para-virtualized random source
# for the vm e.g. virt-install --rng /dev/random
# without this, it is possible to hang during the kerberos server
# setup, and in general, ipa install will be much slower if it
# has to wait for /dev/random
rngd -r /dev/hwrng

ipa-server-install -r "$REALM" -n "$DOMAIN" -p "$VM_ROOTPW" -a "$VM_ROOTPW" -N --hostname=$HOST --setup-dns --forwarder=$FWDR -U

dig SRV _ldap._tcp.$DOMAIN

echo "$VM_ROOTPW" | kinit admin

ipa-adtrust-install -U --netbios-name="$VM_NETBIOS_NAME" -a "$VM_ROOTPW"
# the above will restart dirsrv, so sleep for 60 seconds to give
# dirsrv a chance to start, and for named to reconnect and sync
# with dirsrv
sleep 60

# save in case we need these later
save_VM_NAME=$VM_NAME
unset VM_NAME
save_VM_FQDN=$VM_FQDN
unset VM_FQDN
save_VM_DOMAIN=$VM_DOMAIN
unset VM_DOMAIN
save_VM_IP=$VM_IP
unset VM_IP
for file in /mnt/ad*.conf ; do
(
    . $file
    ipaddr=`getent hosts $VM_FQDN|awk '{print $1}'`
    VM_IP=${VM_IP:-$ipaddr}
    ipa dnszone-add ${VM_DOMAIN}. --name-server=${VM_FQDN}. --admin-email="hostmaster@$VM_DOMAIN" --force --forwarder=$VM_IP --forward-policy=only --ip-address=$VM_IP
    # sleep to allow DNS information to propagate
    sleep 5
    ipa dnszone_find ${VM_DOMAIN}.
    ldapsearch -Y GSSAPI -b cn=dns,dc=ipa1dom,dc=test idnsname=${VM_DOMAIN}.
    dig SRV _ldap._tcp.$VM_DOMAIN
    echo "$ADMINPASSWORD" | ipa trust-add --type=ad $VM_DOMAIN --admin $ADMINNAME --password
    # create a mapping rule for upper case domain to lower case
    ucase=`echo "$VM_DOMAIN" | tr 'a-z' 'A-Z'`
    # find the [realms] section of the krb5.conf - find the ipa realm - only
    # between the beginning of this realm definition and the first close
    # brace, insert our auth_to_local map before the close brace
    sed -i '/^\[realms\]/,/^}/ { /^ *'"$REALM"' /,/^}$/ { /^}$/i\
  auth_to_local = RULE:[1:$1@$0](^.*@'"$ucase"'$)s/@'"$ucase"'/@'"$VM_DOMAIN"'/
}
}
' /etc/krb5.conf

)
done

# add the DEFAULT auth_to_local rule
    sed -i '/^\[realms\]/,/^}/ { /^ *'"$REALM"' /,/^}$/ { /^}$/i\
  auth_to_local = DEFAULT
}
}
' /etc/krb5.conf

service krb5kdc restart
service sssd restart

kdestroy
klist

for file in /mnt/ad*.conf ; do
(
    . $file
    ucase=`echo "$VM_DOMAIN" | tr 'a-z' 'A-Z'`
    echo "$ADMINPASSWORD" | kinit ${ADMINNAME}@$ucase
    klist
    # get suffix
    suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
    VM_AD_SUFFIX=${VM_AD_SUFFIX:-"$suffix"}
    ldapsearch -LLL -Y GSSAPI -h $VM_FQDN -s base -b "$VM_AD_SUFFIX"
    kdestroy
)
done

touch $VM_WAIT_FILE
