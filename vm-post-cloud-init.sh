#!/bin/sh
# This file is used by cloud init to do the post vm startup setup of the
# new vm - it is run by root

set -o errexit

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

# DNS was set up - use ipa dns from now on - tell dhclient to leave resolv.conf alone
cat >> /etc/dhcp/dhclient-enter-hooks <<EOF
make_resolv_conf() {
    :
    # IPA is handling DNS, so leave resolv.conf alone
}
EOF
# NOTE - must be executable, even though it is only sourced
# script tests using -x file, not -f file
chmod +x /etc/dhcp/dhclient-enter-hooks
# NetworkManager does not use dhclient :-(
echo "dns=none" >> /etc/NetworkManager/NetworkManager.conf

dig SRV _ldap._tcp.$DOMAIN

echo "$VM_ROOTPW" | kinit admin

ipa-adtrust-install -U --netbios-name="$VM_NETBIOS_NAME" --enable-compat -a "$VM_ROOTPW"
# the above will restart dirsrv, so sleep for 60 seconds to give
# dirsrv a chance to start, and for named to reconnect and sync
# with dirsrv
sleep 60

ipasuffix=`sed -e '/^basedn=/ {s/basedn=//; p}' -e '/./ d' /etc/ipa/default.conf`

# save in case we need these later
save_VM_NAME=$VM_NAME
unset VM_NAME
save_VM_FQDN=$VM_FQDN
unset VM_FQDN
save_VM_DOMAIN=$VM_DOMAIN
unset VM_DOMAIN
save_VM_IP=$VM_IP
unset VM_IP
save_VM_IP_PREFIX=$VM_IP_PREFIX
unset VM_IP_PREFIX
for file in /mnt/ad*.conf ; do
(
    . $file
    if [ -n "$VM_FQDN" ] ; then
        ipaddr=`getent hosts $VM_FQDN|awk '{print $1}'`
    fi
    VM_IP=${ipaddr:-$VM_IP}
    ipa dnszone-add ${VM_DOMAIN}. --name-server=${VM_FQDN}. --admin-email="hostmaster@$VM_DOMAIN" --force --forwarder=$VM_IP --forward-policy=only --ip-address=$VM_IP
    # sleep to allow DNS information to propagate
    sleep 5
    ipa dnszone_find ${VM_DOMAIN}.
    ldapsearch -Y GSSAPI -b cn=dns,$ipasuffix idnsname=${VM_DOMAIN}.
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

kdestroy || echo no kerberos tickets
klist || echo no kerberos tickets

for file in /mnt/ad*.conf ; do
(
    . $file
    ucase=`echo "$VM_DOMAIN" | tr 'a-z' 'A-Z'`
    echo "$ADMINPASSWORD" | kinit ${ADMINNAME}@$ucase
    klist
    # get suffix
    suffix=`echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'`
    VM_AD_SUFFIX=${VM_AD_SUFFIX:-"$suffix"}
    # verify that we can authenticate using our kerberos credentials from
    # windows, and that we can use them to authenticate to AD
    ldapsearch -LLL -Y GSSAPI -h $VM_FQDN -s base -b "$VM_AD_SUFFIX"
    kdestroy
    # verify that we have an local account
    getent passwd ${ADMINNAME}@$VM_DOMAIN
    # verify that the adminname account is in the compat tree - the search pulls it in
    # NOTE: The entry does not exist in IPA/LDAP until requested explicitly by name and objectclass
    ldapsearch -x -LLL -b "cn=users,cn=compat,$ipasuffix" \
        '(&(objectclass=posixAccount)(uid='"${ADMINNAME}@$VM_DOMAIN"'))'
    # verify that we can use simple bind with password with the windows userid, in the compat tree
    ldapsearch -xLLL -D "uid=${ADMINNAME}@$VM_DOMAIN,cn=users,cn=compat,$ipasuffix" \
        -w "$ADMINPASSWORD" -s base -b "uid=${ADMINNAME}@$VM_DOMAIN,cn=users,cn=compat,$ipasuffix"
)
done
