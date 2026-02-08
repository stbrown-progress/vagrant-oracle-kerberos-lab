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
apt-get install -y krb5-user samba-common-bin dnsutils chrony nginx fcgiwrap

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

cat <<'EOF' > /opt/scripts/setup-sqlnet.sh
#!/bin/bash
set -e

# Detect ORACLE_HOME — entrypoint scripts may run as oracle or root.
OH="$ORACLE_HOME"
if [ -z "$OH" ]; then
    OH=$(ls -d /opt/oracle/product/*/dbhome* 2>/dev/null | head -1)
fi

if [ -n "$OH" ]; then
    mkdir -p "$OH/network/admin"
    cp /opt/scripts/sqlnet.ora "$OH/network/admin/sqlnet.ora"
    echo "setup-sqlnet.sh: deployed sqlnet.ora to $OH/network/admin/"
else
    echo "setup-sqlnet.sh: WARNING — could not determine ORACLE_HOME"
fi
EOF
chmod +x /opt/scripts/setup-sqlnet.sh

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
      container-registry.oracle.com/database/free:latest
else
    echo "Oracle is running."
fi

# Write SQL helper scripts to the shared volume so docker exec can run them.
cat <<'EOF' > /opt/scripts/check_cdb.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT 1 FROM DUAL;
EXIT;
EOF

cat <<'EOF' > /opt/scripts/check_pdb.sql
WHENEVER SQLERROR EXIT SQL.SQLCODE
SELECT open_mode FROM v$pdbs WHERE name='FREEPDB1';
EXIT;
EOF

cat <<'EOF' > /opt/scripts/create_users.sql
ALTER SESSION SET CONTAINER = FREEPDB1;

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM all_users WHERE username = 'TESTUSER';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER testuser IDENTIFIED BY testpassword';
    EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO testuser';
    DBMS_OUTPUT.PUT_LINE('Created testuser');
  END IF;
END;
/

DECLARE
  v_count NUMBER;
BEGIN
  SELECT COUNT(*) INTO v_count FROM all_users WHERE username = 'ORACLEUSER@CORP.INTERNAL';
  IF v_count = 0 THEN
    EXECUTE IMMEDIATE 'CREATE USER "oracleuser@CORP.INTERNAL" IDENTIFIED EXTERNALLY AS ''oracleuser@CORP.INTERNAL''';
    EXECUTE IMMEDIATE 'GRANT CONNECT, RESOURCE TO "oracleuser@CORP.INTERNAL"';
    DBMS_OUTPUT.PUT_LINE('Created oracleuser@CORP.INTERNAL');
  END IF;
END;
/

SELECT username FROM all_users WHERE username IN ('TESTUSER', 'ORACLEUSER@CORP.INTERNAL');
EXIT;
EOF

# Wait for the DB to be fully ready before creating users.
# The entrypoint-initdb scripts are unreliable for PDB operations because
# the PDB may not be open yet when they run.
echo "Waiting for Oracle DB to be ready (this may take several minutes on first run)..."
for i in $(seq 1 60); do
    if docker exec oracle sqlplus -s / as sysdba @/opt/scripts/check_cdb.sql > /dev/null 2>&1; then
        echo "Oracle CDB is up after ${i}0 seconds."
        break
    fi
    sleep 10
done

# Wait for FREEPDB1 to be open
for i in $(seq 1 30); do
    status=$(docker exec oracle sqlplus -s / as sysdba @/opt/scripts/check_pdb.sql 2>/dev/null | grep -o "READ WRITE" || true)
    if [ "$status" = "READ WRITE" ]; then
        echo "FREEPDB1 is open."
        break
    fi
    echo "Waiting for FREEPDB1 to open ($i/30)..."
    sleep 10
done

# Deploy sqlnet.ora inside the container.
# docker exec runs as root without Oracle's profile, so $ORACLE_HOME may be
# unset.  Detect it from the oracle user's environment instead.
docker exec oracle bash -c '
OH=$(su - oracle -c "echo \$ORACLE_HOME" 2>/dev/null)
if [ -z "$OH" ]; then
    OH=$(ls -d /opt/oracle/product/*/dbhome* 2>/dev/null | head -1)
fi
if [ -n "$OH" ]; then
    mkdir -p "$OH/network/admin"
    cp /opt/scripts/sqlnet.ora "$OH/network/admin/sqlnet.ora"
    echo "Deployed sqlnet.ora to $OH/network/admin/"
else
    echo "WARNING: Could not determine ORACLE_HOME inside container"
fi
'

# Create test users (idempotent — skips if they already exist)
docker exec oracle sqlplus -s / as sysdba @/opt/scripts/create_users.sql

# --- Deploy Status Dashboard ---
cat <<'EOF' > /etc/nginx/sites-available/default
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    root /var/www/html;
    index index.html;
    server_name _;

    location / {
        try_files $uri $uri/ =404;
        autoindex on;
    }

    location = /dashboard {
        gzip off;
        include /etc/nginx/fastcgi_params;
        fastcgi_param SCRIPT_FILENAME /usr/local/lib/dashboard-vm.sh;
        fastcgi_pass unix:/var/run/fcgiwrap.socket;
    }
}
EOF

cp /tmp/dashboard-common.sh /usr/local/lib/dashboard-common.sh
cp /tmp/dashboard-vm.sh /usr/local/lib/dashboard-vm.sh
chmod +x /usr/local/lib/dashboard-vm.sh

mkdir -p /etc/systemd/system/fcgiwrap.service.d
cat <<'EOF' > /etc/systemd/system/fcgiwrap.service.d/override.conf
[Service]
User=root
Group=root
EOF
systemctl daemon-reload
systemctl enable fcgiwrap
systemctl restart fcgiwrap
systemctl enable nginx
systemctl restart nginx

echo "Oracle setup complete."
