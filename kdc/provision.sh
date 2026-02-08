#!/bin/bash
set -e

# --- Install dependencies needed for Samba AD DC, Kerberos, and DNS ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y samba krb5-user winbind smbclient dnsutils iproute2 net-tools ldb-tools ldap-utils libsasl2-modules-gssapi-mit nginx fcgiwrap chrony

# --- Configure NTP so Kerberos clock-skew stays under 5 minutes ---
cat <<EOF > /etc/chrony/chrony.conf
server pool.ntp.org iburst
allow 192.168.0.0/16
allow 172.16.0.0/12
allow 10.0.0.0/8
local stratum 10
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
EOF
systemctl restart chrony
systemctl enable chrony

# --- Configure local DNS to use Samba's internal DNS ---
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# Get the current IP (grabbing the first non-loopback IP)
KDC_IP=$(hostname -I | awk '{print $1}')
echo "Current Machine IP detected as: $KDC_IP"

# Clean /etc/hosts: Remove any existing lines for the KDC to prevent duplicates
sed -i '/samba-ad-dc.corp.internal/d' /etc/hosts

# Add the clean, current IP entry
echo "$KDC_IP samba-ad-dc.corp.internal samba-ad-dc" >> /etc/hosts

# If Samba is already running (re-provision), update the A record to match the current IP.
# We use samba-tool dns directly instead of samba_dnsupdate (which is very slow due to
# TSIG failures against the SAMBA_INTERNAL DNS backend).
if systemctl is-active --quiet samba-ad-dc; then
    echo "Samba is running. Updating A record for samba-ad-dc..."
    existing_ips=$(samba-tool dns query localhost corp.internal samba-ad-dc A -U Administrator --password='Str0ngPassw0rd!' 2>/dev/null | awk '/A: / {print $2}') || true
    for old_ip in $existing_ips; do
        samba-tool dns delete localhost corp.internal samba-ad-dc A "$old_ip" -U Administrator --password='Str0ngPassw0rd!' || true
    done
    samba-tool dns add localhost corp.internal samba-ad-dc A "$KDC_IP" -U Administrator --password='Str0ngPassw0rd!' || true
fi

if [ ! -f /etc/samba/smb.conf.bak ]; then
    echo "Provisioning Domain..."

    # --- Provision Samba AD domain if not already provisioned ---
    systemctl stop smbd nmbd winbind
    systemctl disable smbd nmbd winbind
    systemctl unmask samba-ad-dc

    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak
    
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

# Ensure Samba is running
systemctl enable samba-ad-dc
systemctl restart samba-ad-dc
sleep 15

# --- Ensure the KDC A record is correct after (re)start ---
echo "Registering A record: samba-ad-dc -> $KDC_IP"
existing_ips=$(samba-tool dns query localhost corp.internal samba-ad-dc A -U Administrator --password='Str0ngPassw0rd!' 2>/dev/null | awk '/A: / {print $2}') || true
for old_ip in $existing_ips; do
    samba-tool dns delete localhost corp.internal samba-ad-dc A "$old_ip" -U Administrator --password='Str0ngPassw0rd!' || true
done
samba-tool dns add localhost corp.internal samba-ad-dc A "$KDC_IP" -U Administrator --password='Str0ngPassw0rd!' || true

# --- Create service users and enable strong encryption types ---
if ! samba-tool user list | grep -q "oracleuser"; then
    samba-tool user create oracleuser StrongPassword123!
fi

if ! samba-tool user list | grep -q "dnsupdater"; then
    samba-tool user create dnsupdater StrongPassword123!
fi

samba-tool group addmembers "DnsAdmins" dnsupdater || true

samba-tool user setexpiry Administrator --noexpiry || true
samba-tool user setexpiry oracleuser --noexpiry || true
samba-tool user setexpiry dnsupdater --noexpiry || true

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
# Remove stale keytabs before export to prevent duplicate entries on re-provision
rm -f /var/www/html/artifacts/*.keytab
samba-tool domain exportkeytab --principal=oracle/oracle.corp.internal@CORP.INTERNAL /var/www/html/artifacts/oracle.keytab
samba-tool domain exportkeytab --principal=oracleuser@CORP.INTERNAL /var/www/html/artifacts/oracleuser.keytab
samba-tool domain exportkeytab --principal=dnsupdater@CORP.INTERNAL /var/www/html/artifacts/dnsupdater.keytab
chmod 644 /var/www/html/artifacts/*

# --- Configure Nginx with directory listing and CGI dashboard ---
cat <<'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    root /var/www/html;
    index index.html index.htm;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
        autoindex on;
        autoindex_exact_size on;
        autoindex_localtime on;
    }

    location = /dashboard {
        gzip off;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/local/lib/dashboard-vm.sh;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
    }
}
EOF

# --- Deploy Status Dashboard ---
cp /tmp/dashboard-common.sh /usr/local/lib/dashboard-common.sh
cp /tmp/dashboard-vm.sh /usr/local/lib/dashboard-vm.sh
sed -i 's/\r$//' /usr/local/lib/dashboard-common.sh /usr/local/lib/dashboard-vm.sh
chmod +x /usr/local/lib/dashboard-vm.sh

# Run fcgiwrap as root so dashboard can access systemctl, samba-tool, etc.
mkdir -p /etc/systemd/system/fcgiwrap.service.d
cat <<'EOF' > /etc/systemd/system/fcgiwrap.service.d/override.conf
[Service]
User=root
Group=root
EOF
systemctl daemon-reload
systemctl stop fcgiwrap.service fcgiwrap.socket 2>/dev/null || true
systemctl enable fcgiwrap.socket
systemctl start fcgiwrap.socket

systemctl restart nginx

echo "SPNs for oracleuser:"
samba-tool spn list oracleuser || true
echo "Keytab principals for oracle.keytab:"
klist -k /var/www/html/artifacts/oracle.keytab || true
echo "Keytab principals for oracleuser.keytab:"
klist -k /var/www/html/artifacts/oracleuser.keytab || true

echo "Provisioning Complete. IP is $KDC_IP"
