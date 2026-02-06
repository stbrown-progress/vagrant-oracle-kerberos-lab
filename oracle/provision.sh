#!/bin/bash
set -e
KDC_IP=$1
ORACLE_IP=$(hostname -I | awk '{print $1}')

echo "Configuring Oracle with KDC at $KDC_IP..."

# Point DNS at the KDC so Kerberos realm lookups work consistently.
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver $KDC_IP" > /etc/resolv.conf

# Download the Kerberos config and keytabs from the KDC.
mkdir -p /opt/artifacts
source /tmp/fetch_with_retry.sh

fetch_with_retry "http://$KDC_IP/artifacts/oracle.keytab" /opt/artifacts/oracle.keytab
fetch_with_retry "http://$KDC_IP/artifacts/oracleuser.keytab" /opt/artifacts/oracleuser.keytab
fetch_with_retry "http://$KDC_IP/artifacts/krb5.conf" /opt/artifacts/krb5.conf
fetch_with_retry "http://$KDC_IP/artifacts/dnsupdater.keytab" /opt/artifacts/dnsupdater.keytab

# Install Kerberos and DNS tooling for authenticated DNS updates.
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y krb5-user samba-common-bin dnsutils chrony

# --- Configure NTP to sync with the KDC ---
cat <<EOF > /etc/chrony/chrony.conf
server $KDC_IP iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
EOF
systemctl restart chrony
systemctl enable chrony

# Generate Oracle network config files used inside the container.
mkdir -p /opt/scripts

cat <<EOF > /opt/scripts/sqlnet.ora
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)
DISABLE_OOB=ON
SQLNET.EXPIRE_TIME=3
SQLNET.INBOUND_CONNECT_TIMEOUT = 0
SQLNET.AUTHENTICATION_SERVICES = (BEQ, KERBEROS5PRE, KERBEROS5)
SQLNET.KERBEROS5_KEYTAB = /tmp/keytabs/oracle.keytab
SQLNET.KERBEROS5_CONF = /tmp/keytabs/krb5.conf
SQLNET.AUTHENTICATION_KERBEROS5_SERVICE = oracle
SQLNET.KERBEROS5_CONF_MIT = TRUE
SQLNET.ALLOW_WEAK_CRYPTO_CLIENTS = FALSE
SQLNET.ENCRYPTION_SERVER = required
SQLNET.ENCRYPTION_TYPES_SERVER = (AES256)
SQLNET.CRYPTO_CHECKSUM_SERVER = required
SQLNET.CRYPTO_CHECKSUM_TYPES_SERVER = (SHA1, SHA256, SHA512)
TRACE_LEVEL_SERVER=16
DIAG_ADR_ENABLED=off
TRACE_DIRECTORY_SERVER=/tmp
TRACE_FILE_SERVER=server
EOF

# Register this host in Samba DNS using Kerberos auth and a keytab.
export KRB5_CONFIG=/opt/artifacts/krb5.conf
kinit -k -t /opt/artifacts/dnsupdater.keytab dnsupdater@CORP.INTERNAL
existing_ips=$(samba-tool dns query samba-ad-dc corp.internal oracle A -k yes 2>/dev/null | awk '/A: / {print $2}')
for ip in $existing_ips; do
    samba-tool dns delete samba-ad-dc corp.internal oracle A "$ip" -k yes || true
done
samba-tool dns add samba-ad-dc corp.internal oracle A $ORACLE_IP -k yes
kdestroy || true

# Verify DNS registration against the KDC to help diagnose resolution issues.
dig +short @$KDC_IP oracle.corp.internal || true

# Verify keytabs and Kerberos config are coherent for quick debugging.
export KRB5_CONFIG=/opt/artifacts/krb5.conf
klist -k /opt/artifacts/oracle.keytab || true
klist -k /opt/artifacts/oracleuser.keytab || true
kvno oracle/oracle.corp.internal || true

cat <<EOF > /opt/scripts/setup-sqlnet.sh
#!/bin/bash
set -e

# Ensure sqlnet.ora is placed where the image actually reads it.
targets=()
if [ -n "\$ORACLE_HOME" ]; then
  targets+=("\$ORACLE_HOME/network/admin")
fi

for dir in "\${targets[@]}"; do
  mkdir -p "\$dir"
  cp /opt/scripts/sqlnet.ora "\$dir/sqlnet.ora"
done
EOF
chmod +x /opt/scripts/setup-sqlnet.sh

cat <<EOF > /opt/scripts/create_test_user.sql
ALTER SESSION SET CONTAINER = FREEPDB1;
CREATE USER testuser IDENTIFIED BY testpassword;
GRANT CONNECT, RESOURCE TO testuser;
CREATE USER "oracleuser@CORP.INTERNAL" IDENTIFIED EXTERNALLY AS 'oracleuser@CORP.INTERNAL';
GRANT CONNECT, RESOURCE TO "oracleuser@CORP.INTERNAL";
EOF

# Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker vagrant
    systemctl enable docker
    systemctl start docker
fi

# Run Container
if [ ! "$(docker ps -q -f name=oracle)" ]; then
    if [ "$(docker ps -aq -f name=oracle)" ]; then docker rm oracle; fi
    
    echo "Starting Oracle Container..."
    docker run -d --name oracle \
      --restart unless-stopped \
      --net=host \
      -e ORACLE_PWD=Str0ngPassw0rd! \
      -v /opt/artifacts:/tmp/keytabs \
      -v /opt/scripts:/opt/scripts \
      -v /opt/scripts/sqlnet.ora:/opt/scripts/sqlnet.ora \
      -v /opt/scripts/setup-sqlnet.sh:/docker-entrypoint-initdb.d/setup-sqlnet.sh \
      -v /opt/scripts/create_test_user.sql:/docker-entrypoint-initdb.d/create_test_user.sql \
      container-registry.oracle.com/database/free:latest
else
    echo "Oracle is running."
fi
