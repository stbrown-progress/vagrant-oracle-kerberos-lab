#!/bin/bash
set -e
KDC_IP=$1

echo "Configuring Test Client with KDC at $KDC_IP..."

# --- Install client tools for Kerberos and network checks ---
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y krb5-user libaio1 iputils-ping netcat wget unzip dnsutils chrony

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

# --- Pull Kerberos config from the KDC ---
source /tmp/fetch_with_retry.sh

fetch_with_retry "http://$KDC_IP/artifacts/krb5.conf" /etc/krb5.conf

# --- Prepare Oracle Instant Client layout and env vars ---
echo "Preparing Oracle Client configuration..."

IC_DIR="/opt/oracle/instantclient"

mkdir -p /opt/oracle

# Persist env vars for vagrant (guard against duplicate appends on re-provision)
if ! grep -q "TNS_ADMIN" /home/vagrant/.bashrc; then
    echo "export LD_LIBRARY_PATH=$IC_DIR:\$LD_LIBRARY_PATH" >> /home/vagrant/.bashrc
    echo "export PATH=$IC_DIR:\$PATH" >> /home/vagrant/.bashrc
    echo "export TNS_ADMIN=$IC_DIR/network/admin" >> /home/vagrant/.bashrc
fi

# --- Generate Oracle Instant Client install helper script ---
cat <<'EOF' > /home/vagrant/install-oracle.sh
#!/bin/bash
set -e

# Minimal Oracle Instant Client install (no ldconfig)

sudo apt-get update
sudo apt-get install -y wget unzip libaio1

wget https://download.oracle.com/otn_software/linux/instantclient/1929000/instantclient-basic-linux.x64-19.29.0.0.0dbru.zip
wget https://download.oracle.com/otn_software/linux/instantclient/1929000/instantclient-sqlplus-linux.x64-19.29.0.0.0dbru.zip

sudo mkdir -p /opt/oracle
sudo unzip -o instantclient-basic-linux.x64-19.29.0.0.0dbru.zip -d /opt/oracle
sudo unzip -o instantclient-sqlplus-linux.x64-19.29.0.0.0dbru.zip -d /opt/oracle

sudo rm -rf /opt/oracle/instantclient
sudo ln -s /opt/oracle/instantclient_19_29 /opt/oracle/instantclient

/opt/oracle/instantclient/sqlplus -V
EOF

chmod +x /home/vagrant/install-oracle.sh
chown vagrant:vagrant /home/vagrant/install-oracle.sh

# --- Configure SQLNET for Kerberos authentication ---
mkdir -p $IC_DIR/network/admin

cat <<EOF > $IC_DIR/network/admin/sqlnet.ora
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)
SQLNET.AUTHENTICATION_SERVICES = (KERBEROS5)
SQLNET.KERBEROS5_CONF = /etc/krb5.conf
SQLNET.AUTHENTICATION_KERBEROS5_SERVICE = oracle
SQLNET.KERBEROS5_CONF_MIT = TRUE
EOF

# --- Create a test script for Kerberos and Oracle connectivity ---
cat <<EOF > /home/vagrant/test_auth.sh
#!/bin/bash
IC_DIR="/opt/oracle/instantclient"
export LD_LIBRARY_PATH=$IC_DIR:\$LD_LIBRARY_PATH
export PATH=$IC_DIR:\$PATH
export TNS_ADMIN=$IC_DIR/network/admin

echo "--- Testing KDC Connectivity ---"
nc -zv samba-ad-dc.corp.internal 88

echo -e "\n--- Validating DNS for Oracle ---"
dig +short oracle.corp.internal || true

echo -e "\n--- Confirming SQL*Net config ---"
ls -l "\$TNS_ADMIN/sqlnet.ora"

echo -e "\n--- Requesting TGT ---"
kdestroy -A 2>/dev/null || true
echo "StrongPassword123!" | kinit oracleuser@CORP.INTERNAL
klist

echo -e "\n--- Requesting a service ticket for Oracle ---"
kvno oracle/oracle.corp.internal
klist

echo -e "\n--- Connecting to Oracle via SQLPlus (Kerberos) ---"
sqlplus -L /@oracle.corp.internal:1521/FREEPDB1 <<EXITSQL
PROMPT Successfully connected to Oracle!
SELECT 'Authenticated User: ' || USER FROM DUAL;
SELECT 'Authentication Method: ' || AUTHENTICATION_METHOD
FROM V\$SESSION_CONNECT_INFO
WHERE SID = SYS_CONTEXT('USERENV', 'SID');
EXITSQL
EOF

chmod +x /home/vagrant/test_auth.sh
chown vagrant:vagrant /home/vagrant/test_auth.sh

echo "Provisioning complete."
echo "SSH in as vagrant and run: ./install-oracle.sh"
echo "Then run: ./test_auth.sh"
