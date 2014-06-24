#!/bin/sh

set -x
set -o errexit

sudo subscription-manager register --username="YOUR_RHN_USERNAME" --password="YOUR_RHN_PASSWORD"

get_ipa_fqdn() {
(
    . $1
    echo $VM_FQDN
)
}

get_ipa_suffix() {
(
    . $1
    echo $VM_DOMAIN | sed -e 's/^/dc=/' -e 's/\./,dc=/g'
)
}

mydir=`dirname $0`
for file in $mydir/ipa*.conf ; do
    case $file in
    *ipa2client.conf) . $file ;;
    *ipa*.conf) IPA_FQDN=`get_ipa_fqdn $file`
                IPA_SUFFIX=`get_ipa_suffix $file`
                ;;
    esac
done

channels="rhel-6-server-optional-debug-rpms
rhel-6-server-eus-supplementary-rpms
rhel-6-server-rpms
rhel-6-server-debug-rpms
rhel-6-server-rh-common-debug-rpms
rhel-6-server-eus-optional-rpms
rhel-6-server-openstack-4.0-debug-rpms
rhel-6-server-optional-rpms
rhel-6-server-supplementary-debuginfo
rhel-6-server-extras-debuginfo
rhel-6-server-eus-optional-debug-rpms
rhel-6-server-openstack-4.0-source-rpms
rhel-6-server-supplementary-rpms
rhel-6-server-rh-common-rpms
rhel-6-server-eus-supplementary-debuginfo
rhel-6-server-openstack-4.0-rpms
rhel-6-server-eus-debug-rpms
rhel-6-server-eus-rh-common-debug-rpms"

for ch in $channels ; do
    sudo subscription-manager repos --enable=$ch
done

# could be a transient problem, but there seems to be some conflict with update and syslinux
yum -y erase syslinux || echo no syslinux package installed
yum -y update
yum -y install openstack-packstack

# packstack uses ssh on localhost, even
ssh-keygen -t rsa -f /root/.ssh/id_rsa -N ""
cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
HOME=/root packstack --allinone

# find the service user ids and passwords for the following components
SERVICE_COMPONENTS="nova glance neutron swift ceilometer cinder"
CONFIG_ROOT_DIR=/etc

get_username() {
    # can't use openstack-config here because we don't know the section
    awk -F'[= ]+' '
        /^#/ {next}
        /^admin_user *=/ {admin_user=$2}
        /^os_username *=/ {os_username=$2}
        END {if (admin_user) {print admin_user} else if (os_username) {print os_username}}
    ' "$@"
}

get_password() {
    # can't use openstack-config here because we don't know the section
    awk -F'[= ]+' '
        /^#/ {next}
        /^admin_password *=/ {admin_pw=$2}
        /^os_password *=/ {os_pw=$2}
        END {if (admin_pw) {print admin_pw} else if (os_pw) {print os_pw}}
    ' "$@"
}

make_user_entry() {
    echo echo $2 \| ipa user-add --first=$1 --last=User --homedir=/var/lib/$1 --shell=/sbin/nologin --password $1
}

asgn_t="user_project_metadata" # assignment in later versions - table name
act_col="user_id" # actor_id in later versions - column name
id_col="id" # id column name
user_t="user" # user table name
name_col="name" # user name column
proj_t="project" # project/tenant table name

fix_keystone_tables_for_userid() {
    # new user_id is $1
    # What are we doing?
    # When switching from sql to ldap, you have to use the ldap userid (the user.name column)
    # as the keystone user id instead of the uuid, since the user table won't be used anymore,
    # and the key in the user table is the uuid - so, use the user name as the user_id
    # in the $asgn_t table
    mysql ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
        ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname" <<EOF
update $asgn_t set $act_col = '$1' where $act_col = (select $id_col from $user_t where $name_col = '$1');
EOF
}

make_keystone_user_admin() {
    # make the userid 'keystone' an admin user
    mysql ${m_host:+"--host=$m_host"} ${m_port:+"--port=$m_port"} \
        ${m_user:+"--user=$m_user"} ${m_pass:+"--password=$m_pass"} "$m_dbname" <<EOF
INSERT into $asgn_t
VALUES ('keystone',
        (SELECT $proj_t.id from $proj_t where $proj_t.$name_col = 'admin'),
        CONCAT('{"roles":[{"id":"',
               (SELECT role.id from role where role.name = 'admin'),
               '"}]}')
       );
EOF
}

# $1 is user id - $2 is role name - $3 is tenant/project name
enable_keystone_user() {
    keystone user-role-add --user-id "$1" \
        --role "$2" --tenant "$3"
}

use_ldap_in_keystone() {
    cp -p $CONFIG_ROOT_DIR/keystone/keystone.conf $CONFIG_ROOT_DIR/keystone/keystone.conf.orig
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf identity driver keystone.identity.backends.ldap.Identity
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf assignment driver keystone.assignment.backends.sql.Assignment
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap url ldap://$IPA_FQDN
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap user_tree_dn cn=users,cn=compat,$IPA_SUFFIX
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap user_objectclass posixAccount
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap user_id_attribute uid
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap user_name_attribute uid
    openstack-config --set $CONFIG_ROOT_DIR/keystone/keystone.conf ldap user_mail_attribute mail
}

# use openstack-config to get/set values in openstack config files

# grab the mysql connection parameters
url=`grep ^connection $CONFIG_ROOT_DIR/keystone/keystone.conf|sed 's/^connection[ ]*=[ ]*//'`
# url looks like this: mysql://username:password@hostname:port/dbname
m_userpass=`echo "$url"|sed 's,^.*//\([^@]*\)@.*$,\1,'`
m_hostport=`echo "$url"|sed 's,^.*@\([^/]*\)/.*$,\1,'`
m_dbname=`echo "$url"|sed 's,^.*/\([^/]*\)$,\1,'`
m_user=`echo "$m_userpass"|cut -s -f1 -d:`
if [ -z "$m_user" ] ; then # no pass
    m_user="$m_userpass"
fi
m_pass=`echo "$m_userpass"|cut -s -f2 -d:`
m_host=`echo "$m_hostport"|cut -s -f1 -d:`
if [ -z "$m_host" ] ; then # no port
    m_host="$m_hostport"
fi
m_port=`echo "$m_hostport"|cut -s -f2 -d:`

userfile=/root/userfile.ipa

shopt -s nullglob
for comp in $SERVICE_COMPONENTS ; do
    if [ -d $CONFIG_ROOT_DIR/$comp ]; then
        username=`get_username $CONFIG_ROOT_DIR/$comp/*.conf $CONFIG_ROOT_DIR/$comp/*.ini`
        if [ -z "$username" ] ; then
            echo WARNING: component $comp has no username in $CONFIG_ROOT_DIR/$comp/*.conf
            continue
        fi
        password=`get_password $CONFIG_ROOT_DIR/$comp/*.conf $CONFIG_ROOT_DIR/$comp/*.ini`
        if [ -z "$password" ] ; then
            echo WARNING: component $comp has no password in $CONFIG_ROOT_DIR/$comp/*.conf
            continue
        fi
        make_user_entry "$username" "$password" >> $userfile
        fix_keystone_tables_for_userid "$username"
    fi
done

make_user_entry keystone $VM_ROOTPW >> $userfile
make_keystone_user_admin
use_ldap_in_keystone

echo Need to add users from userfile.ipa to ipa server
echo Need to restart openstack servers
