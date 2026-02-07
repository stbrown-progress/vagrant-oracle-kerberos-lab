#!/bin/bash
set -e
KDC_IP=$1

echo "Configuring Test Client with KDC at $KDC_IP..."

# --- Install client tools for Kerberos, network checks, and Java ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y krb5-user libaio1 iputils-ping netcat wget unzip dnsutils chrony default-jdk

# --- Configure NTP to sync with the KDC ---
cat <<EOF > /etc/chrony/chrony.conf
server $KDC_IP iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
EOF
systemctl restart chrony
systemctl enable chrony

# --- Point DNS at the KDC so domain names resolve via Samba ---
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver $KDC_IP" > /etc/resolv.conf

# Ensure the KDC hostname always resolves locally.
sed -i "/samba-ad-dc/d" /etc/hosts
echo "$KDC_IP samba-ad-dc.corp.internal samba-ad-dc" >> /etc/hosts

# Validate DNS resolution through the KDC early for easier troubleshooting.
dig +short oracle.corp.internal || true

# --- Pull Kerberos config and keytab from the KDC ---
source /tmp/fetch_with_retry.sh

fetch_with_retry "http://$KDC_IP/artifacts/krb5.conf" /etc/krb5.conf
fetch_with_retry "http://$KDC_IP/artifacts/oracleuser.keytab" /home/vagrant/oracleuser.keytab
chown vagrant:vagrant /home/vagrant/oracleuser.keytab
chmod 600 /home/vagrant/oracleuser.keytab

# --- Prepare Oracle Instant Client layout and env vars ---
IC_DIR="/opt/oracle/instantclient"
mkdir -p /opt/oracle

# Persist env vars for vagrant (guard against duplicate appends on re-provision)
if ! grep -q "TNS_ADMIN" /home/vagrant/.bashrc; then
    echo "export LD_LIBRARY_PATH=$IC_DIR:\$LD_LIBRARY_PATH" >> /home/vagrant/.bashrc
    echo "export PATH=$IC_DIR:\$PATH" >> /home/vagrant/.bashrc
    echo "export TNS_ADMIN=$IC_DIR/network/admin" >> /home/vagrant/.bashrc
fi

# --- Deploy files from lib/ (uploaded by Vagrant file provisioner) ---
# Helper scripts → vagrant home
for f in install-oracle.sh test_auth.sh kinit-keytab.sh; do
    cp "/tmp/lib/$f" "/home/vagrant/$f"
    chmod +x "/home/vagrant/$f"
    chown vagrant:vagrant "/home/vagrant/$f"
done

# ISQL connection files → vagrant home
for f in connect.isql connect-kerb.isql; do
    cp "/tmp/lib/$f" "/home/vagrant/$f"
    chown vagrant:vagrant "/home/vagrant/$f"
done

# Client sqlnet.ora → Instant Client network/admin
mkdir -p "$IC_DIR/network/admin"
cp /tmp/lib/sqlnet-client.ora "$IC_DIR/network/admin/sqlnet.ora"

echo "Provisioning complete."
echo "Java version: $(java -version 2>&1 | head -1)"
echo "SSH in as vagrant and run: ./install-oracle.sh"
echo "Then run: ./test_auth.sh or ./kinit-keytab.sh"
