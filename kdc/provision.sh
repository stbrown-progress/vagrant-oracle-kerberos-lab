#!/bin/bash
set -e

# --- 1. Install Dependencies ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba krb5-user winbind smbclient dnsutils iproute2 net-tools ldb-tools ldap-utils libsasl2-modules-gssapi-mit nginx

# --- 2. Network & DNS ---
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

KDC_IP=$(hostname -I | awk '{print $1}')
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost\n$KDC_IP samba-ad-dc.corp.internal samba-ad-dc/" /etc/hosts

# --- 3. Provision Samba ---
systemctl stop smbd nmbd winbind
systemctl disable smbd nmbd winbind
systemctl unmask samba-ad-dc

if [ ! -f /etc/samba/smb.conf.bak ]; then
    echo "Provisioning Domain..."
    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
    
    # CRITICAL FIX: Added "dns forwarder" so clients can resolve internet domains via the KDC
    samba-tool domain provision \
        --use-rfc2307 \
        --realm=CORP.INTERNAL \
        --domain=CORP \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass='Str0ngPassw0rd!' \
        --option="dns forwarder=8.8.8.8"
        
    cp /var/lib/samba/private/krb5.conf /etc/krb5.conf
fi

systemctl enable samba-ad-dc
systemctl restart samba-ad-dc
sleep 15

# --- 4. Users & Encryption ---
if ! samba-tool user list | grep -q "oracleuser"; then
    samba-tool user create oracleuser StrongPassword123!
fi

echo "Str0ngPassw0rd!" | kinit Administrator
samba-tool spn add kerberos/oracle.corp.internal oracleuser || true

cat <<EOF | ldapmodify -Y GSSAPI -H ldap://localhost
dn: CN=oracleuser,CN=Users,DC=corp,DC=internal
changetype: modify
replace: msDS-SupportedEncryptionTypes
msDS-SupportedEncryptionTypes: 31
EOF

# --- 5. Export Artifacts (DATA ONLY) ---
mkdir -p /var/www/html/artifacts
cp /etc/krb5.conf /var/www/html/artifacts/krb5.conf
samba-tool domain exportkeytab --principal=kerberos/oracle.corp.internal@CORP.INTERNAL /var/www/html/artifacts/oracle.keytab
chmod 644 /var/www/html/artifacts/*
systemctl restart nginx
