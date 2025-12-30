#!/bin/bash
set -e

# --- Install dependencies needed for Samba AD DC, Kerberos, and DNS ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba krb5-user winbind smbclient dnsutils iproute2 net-tools ldb-tools ldap-utils libsasl2-modules-gssapi-mit nginx

# --- Configure local DNS to use Samba's internal DNS ---
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

KDC_IP=$(hostname -I | awk '{print $1}')
sed -i "s/127.0.0.1 localhost/127.0.0.1 localhost\n$KDC_IP samba-ad-dc.corp.internal samba-ad-dc/" /etc/hosts

# --- Provision Samba AD domain if not already provisioned ---
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

# --- Create service users and enable strong encryption types ---
if ! samba-tool user list | grep -q "oracleuser"; then
    samba-tool user create oracleuser StrongPassword123!
fi

if ! samba-tool user list | grep -q "dnsupdater"; then
    samba-tool user create dnsupdater StrongPassword123!
fi

samba-tool group addmembers "DnsAdmins" dnsupdater || true

echo "Str0ngPassw0rd!" | kinit Administrator
samba-tool spn add oracle/oracle.corp.internal oracleuser || true

cat <<EOF | ldapmodify -Y GSSAPI -H ldap://localhost
dn: CN=oracleuser,CN=Users,DC=corp,DC=internal
changetype: modify
replace: msDS-SupportedEncryptionTypes
msDS-SupportedEncryptionTypes: 31
EOF

# --- Export keytabs and krb5.conf for other nodes to download ---
mkdir -p /var/www/html/artifacts
cp /etc/krb5.conf /var/www/html/artifacts/krb5.conf
samba-tool domain exportkeytab --principal=oracle/oracle.corp.internal@CORP.INTERNAL /var/www/html/artifacts/oracle.keytab
samba-tool domain exportkeytab --principal=dnsupdater@CORP.INTERNAL /var/www/html/artifacts/dnsupdater.keytab
chmod 644 /var/www/html/artifacts/*
systemctl restart nginx

echo "SPNs for oracleuser:"
samba-tool spn list oracleuser || true
echo "Keytab principals for oracle.keytab:"
klist -k /var/www/html/artifacts/oracle.keytab || true
