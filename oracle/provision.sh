#!/bin/bash
set -e
KDC_IP=$1
ORACLE_IP=$(hostname -I | awk '{print $1}')

echo "Configuring Oracle with KDC at $KDC_IP..."

# 1. Hostname Fixes
sed -i "/oracle/d" /etc/hosts
echo "$ORACLE_IP oracle.corp.internal oracle" >> /etc/hosts
echo "$KDC_IP samba-ad-dc.corp.internal samba-ad-dc" >> /etc/hosts

# 2. Download Artifacts
# We fetch the DATA we need from the KDC
mkdir -p /opt/oracle_keytab
wget -q http://$KDC_IP/artifacts/oracle.keytab -O /opt/oracle_keytab/oracle.keytab
wget -q http://$KDC_IP/artifacts/krb5.conf -O /opt/oracle_keytab/krb5.conf

# 3. Generate Oracle Configs (Self-Contained Logic)
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

cat <<EOF > /opt/scripts/setup-sqlnet.sh
#!/bin/bash
cp /opt/scripts/sqlnet.ora \$ORACLE_HOME/network/admin/sqlnet.ora
EOF
chmod +x /opt/scripts/setup-sqlnet.sh

cat <<EOF > /opt/scripts/create_test_user.sql
ALTER SESSION SET CONTAINER = XEPDB1;
CREATE USER testuser IDENTIFIED BY testpassword;
GRANT CONNECT, RESOURCE TO testuser;
CREATE USER "oracleuser@CORP.INTERNAL" IDENTIFIED EXTERNALLY AS 'oracleuser@CORP.INTERNAL';
GRANT CONNECT, RESOURCE TO "oracleuser@CORP.INTERNAL";
EOF

# 4. Install Docker
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker vagrant
    systemctl enable docker
    systemctl start docker
fi

# 5. Run Container
if [ ! "$(docker ps -q -f name=oracle)" ]; then
    if [ "$(docker ps -aq -f name=oracle)" ]; then docker rm oracle; fi
    
    echo "Starting Oracle Container..."
    docker run -d --name oracle \
      --restart unless-stopped \
      --net=host \
      --dns=$KDC_IP \
      -e ORACLE_PASSWORD=Str0ngPassw0rd! \
      -v /opt/oracle_keytab:/tmp/keytabs \
      -v /opt/scripts:/opt/scripts \
      -v /opt/scripts/sqlnet.ora:/opt/scripts/sqlnet.ora \
      -v /opt/scripts/setup-sqlnet.sh:/docker-entrypoint-initdb.d/setup-sqlnet.sh \
      -v /opt/scripts/create_test_user.sql:/docker-entrypoint-initdb.d/create_test_user.sql \
      gvenzl/oracle-xe:21-slim
else
    echo "Oracle is running."
fi
