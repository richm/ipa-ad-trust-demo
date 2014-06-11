#!/bin/sh

# this script is executed at the kickstart post-install phase
# inside of the chroot jail
# we can't do very much because systemd doesn't work
# so we set up the "real" post-install script to be
# run after the first boot into the new, real OS

# the user must provide a file in /root called *ipa*.conf
# which will provide the hostname, domain name, passwords, etc.

mydir=`dirname $0`
for file in $mydir/*ipa*.conf ; do
    . $file
done

# create a script named $name, have it run at boot, then disable and erase it
name=setup-ipa-firstboot

scriptpath=/var/lib/$name.sh

# create our systemd unit service file
cat > /etc/systemd/system/$name.service <<EOF
[Unit]
Description=Setup IPA at first boot after install

[Service]
ExecStart=$scriptpath
Type=oneshot

[Install]
WantedBy=multi-user.target
EOF

cat > $scriptpath <<EOF
#!/bin/sh
function getdomain() {
    dom=\$(domainname)
    if [ -n "\$dom" -a "\$dom" != '(none)' ]; then
        echo \$dom
        return 0
    fi
    awk '
        /^domain / {dom=\$2 ; exit}
        /^search / {dom=\$2 ; exit}
        END {if (!dom) {dom="local"}; print dom}
    ' /etc/resolv.conf
}

function getns() {
    awk '
        /^nameserver / {ns=\$2 ; exit}
        END {if (!ns) {ns="127.0.0.1"}; print ns}
    ' /etc/resolv.conf
}

DOMAIN=$VM_DOMAIN
DOMAIN=\${DOMAIN:-ipa.\$(getdomain)}
REALM=$VM_REALM
REALM=\${REALM:-\$(echo \$DOMAIN | tr 'a-z' 'A-Z')}
HOST=$VM_FQDN
HOST=\${HOST:-\$(hostname)}
FWDR=$VM_FORWARDER
FWDR=\${FWDR:-\$(getns)}

ipa-server-install -r "\$REALM" -n "\$DOMAIN" -p "$VM_ROOTPW" -a "$VM_ROOTPW" -N --hostname=\$HOST --setup-dns --forwarder=\$FWDR -U

# lastly, disable and remove this script
systemctl disable $name.service
rm -f $scriptpath
EOF

chmod +x $scriptpath

systemctl enable $name.service
