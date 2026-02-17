#!/bin/bash
# oracle/provision.sh - Oracle Database VM provisioning orchestrator
#
# This is the main entry point called by Vagrant. It configures base
# system settings (DNS, NTP, artifacts download), then delegates to
# focused sub-scripts for DNS registration, Docker, and DB setup.
#
# Sub-scripts (uploaded by Vagrant file provisioner):
#   /tmp/setup-dns-registration.sh - Register this VM's IP in Samba DNS
#   /tmp/setup-docker.sh           - Install Docker, run Oracle container
#   /tmp/setup-oracle-db.sh        - Wait for DB, deploy sqlnet.ora, create users
#   /tmp/setup-dashboard.sh        - Nginx + CGI status dashboard (shared)
#
# Config files (uploaded to /tmp/scripts/):
#   sqlnet.ora       - Oracle server-side Kerberos network config
#   create_users.sql - Idempotent DB user creation
#   check_cdb.sql    - CDB readiness check
#   check_pdb.sql    - PDB readiness check
#
set -e
KDC_IP=$1
ORACLE_IP=$(hostname -I | awk '{print $1}')

echo "==> Configuring Oracle VM (KDC: $KDC_IP, Oracle: $ORACLE_IP)"

# =====================================================================
# 1. Configure DNS to resolve via the KDC (Samba AD DNS)
# =====================================================================
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver $KDC_IP" > /etc/resolv.conf

# =====================================================================
# 2. Download Kerberos config and keytabs from the KDC
# =====================================================================
mkdir -p /opt/artifacts
source /tmp/fetch_with_retry.sh

fetch_with_retry "http://$KDC_IP/artifacts/oracle.keytab"     /opt/artifacts/oracle.keytab
fetch_with_retry "http://$KDC_IP/artifacts/oracleuser.keytab" /opt/artifacts/oracleuser.keytab
fetch_with_retry "http://$KDC_IP/artifacts/krb5.conf"         /opt/artifacts/krb5.conf
fetch_with_retry "http://$KDC_IP/artifacts/dnsupdater.keytab" /opt/artifacts/dnsupdater.keytab

# =====================================================================
# 3. Install packages
# =====================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y krb5-user samba-common-bin dnsutils chrony nginx fcgiwrap

# =====================================================================
# 4. Configure NTP to sync with the KDC
# =====================================================================
cat <<EOF > /etc/chrony/chrony.conf
server $KDC_IP iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
EOF
systemctl restart chrony
systemctl enable chrony

# =====================================================================
# 5. Deploy config files to the shared /opt/scripts volume
# =====================================================================
# These files are bind-mounted into the Oracle container.
mkdir -p /opt/scripts
cp /tmp/scripts/sqlnet.ora       /opt/scripts/sqlnet.ora
cp /tmp/scripts/create_users.sql /opt/scripts/create_users.sql
cp /tmp/scripts/check_cdb.sql    /opt/scripts/check_cdb.sql
cp /tmp/scripts/check_pdb.sql    /opt/scripts/check_pdb.sql

# Helper script that runs inside the container as an initdb entrypoint
# to deploy sqlnet.ora into ORACLE_HOME/network/admin/.
cat <<'EOF' > /opt/scripts/setup-sqlnet.sh
#!/bin/bash
set -e
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

# =====================================================================
# 6. Register this VM's IP in Samba DNS
# =====================================================================
source /tmp/setup-dns-registration.sh

# =====================================================================
# 7. Verify keytabs (quick diagnostic output)
# =====================================================================
export KRB5_CONFIG=/opt/artifacts/krb5.conf
echo "==> Keytab verification:"
klist -k /opt/artifacts/oracle.keytab || true
klist -k /opt/artifacts/oracleuser.keytab || true
kvno oracle/oracle.corp.internal || true

# =====================================================================
# 8. Install Docker and start Oracle container
# =====================================================================
source /tmp/setup-docker.sh

# =====================================================================
# 9. Wait for DB readiness, deploy sqlnet.ora, create users
# =====================================================================
source /tmp/setup-oracle-db.sh

# =====================================================================
# 10. Deploy status dashboard
# =====================================================================
source /tmp/setup-dashboard.sh

echo ""
echo "==========================================="
echo "  Oracle VM provisioning complete."
echo "  Dashboard: http://oracle/dashboard"
echo "==========================================="
