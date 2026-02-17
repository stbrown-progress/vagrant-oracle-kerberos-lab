#!/bin/bash
# test/provision.sh - Test client VM provisioning
#
# This VM acts as a Kerberos-enabled client for testing Oracle
# authentication. It downloads keytabs from the KDC, sets up DNS,
# and deploys helper scripts for interactive testing.
#
# After provisioning, SSH in as 'vagrant' and run:
#   ./install-oracle.sh   - Install Oracle Instant Client
#   ./kinit-keytab.sh     - Obtain a Kerberos TGT via keytab
#   ./test_auth.sh        - End-to-end Kerberos + Oracle auth test
#
set -e
KDC_IP=$1

echo "==> Configuring Test Client (KDC: $KDC_IP)"

# =====================================================================
# 1. Install packages
# =====================================================================
# krb5-user: Kerberos client tools (kinit, klist, kvno)
# libaio1: Required by Oracle Instant Client
# default-jdk: For JDBC Kerberos testing
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    krb5-user libaio1 iputils-ping netcat wget unzip \
    dnsutils chrony default-jdk nginx fcgiwrap

# =====================================================================
# 2. Configure NTP to sync with the KDC
# =====================================================================
cat <<EOF > /etc/chrony/chrony.conf
server $KDC_IP iburst
driftfile /var/lib/chrony/chrony.drift
makestep 1.0 3
EOF
systemctl restart chrony
systemctl enable chrony

# =====================================================================
# 3. Configure DNS to resolve via the KDC (Samba AD DNS)
# =====================================================================
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver $KDC_IP" > /etc/resolv.conf

# Also add KDC to /etc/hosts as a fallback
sed -i "/samba-ad-dc/d" /etc/hosts
echo "$KDC_IP samba-ad-dc.corp.internal samba-ad-dc" >> /etc/hosts

# Quick DNS validation for troubleshooting
dig +short oracle.corp.internal || true

# =====================================================================
# 4. Download Kerberos config and keytab from the KDC
# =====================================================================
source /tmp/fetch_with_retry.sh

fetch_with_retry "http://$KDC_IP/artifacts/krb5.conf"         /etc/krb5.conf
fetch_with_retry "http://$KDC_IP/artifacts/oracleuser.keytab" /home/vagrant/oracleuser.keytab
chown vagrant:vagrant /home/vagrant/oracleuser.keytab
chmod 600 /home/vagrant/oracleuser.keytab

# =====================================================================
# 5. Prepare Oracle Instant Client directory and environment
# =====================================================================
IC_DIR="/opt/oracle/instantclient"
mkdir -p /opt/oracle

# Persist env vars for the vagrant user's shell sessions.
# Guarded against duplicate appends on re-provision.
if ! grep -q "TNS_ADMIN" /home/vagrant/.bashrc; then
    echo "export LD_LIBRARY_PATH=$IC_DIR:\$LD_LIBRARY_PATH" >> /home/vagrant/.bashrc
    echo "export PATH=$IC_DIR:\$PATH" >> /home/vagrant/.bashrc
    echo "export TNS_ADMIN=$IC_DIR/network/admin" >> /home/vagrant/.bashrc
fi

# =====================================================================
# 6. Deploy helper scripts and config files
# =====================================================================
# Shell scripts -> vagrant home (executable)
for f in install-oracle.sh test_auth.sh kinit-keytab.sh; do
    cp "/tmp/lib/$f" "/home/vagrant/$f"
    chmod +x "/home/vagrant/$f"
    chown vagrant:vagrant "/home/vagrant/$f"
done

# iSQL connection files -> vagrant home
for f in connect.isql connect-kerb.isql; do
    cp "/tmp/lib/$f" "/home/vagrant/$f"
    chown vagrant:vagrant "/home/vagrant/$f"
done

# Client-side sqlnet.ora for Kerberos authentication
mkdir -p "$IC_DIR/network/admin"
cp /tmp/lib/sqlnet-client.ora "$IC_DIR/network/admin/sqlnet.ora"

# =====================================================================
# 7. Deploy status dashboard
# =====================================================================
source /tmp/setup-dashboard.sh

echo ""
echo "==========================================="
echo "  Test client provisioning complete."
echo "  Java: $(java -version 2>&1 | head -1)"
echo "  Dashboard: http://test-client/dashboard"
echo ""
echo "  Next steps (SSH in as vagrant):"
echo "    ./install-oracle.sh   # Install Oracle Instant Client"
echo "    ./kinit-keytab.sh     # Get Kerberos ticket"
echo "    ./test_auth.sh        # Run end-to-end auth test"
echo "==========================================="
