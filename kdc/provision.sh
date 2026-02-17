#!/bin/bash
# kdc/provision.sh - Samba AD Domain Controller provisioning orchestrator
#
# This is the main entry point called by Vagrant. It installs packages,
# configures base system settings (NTP, DNS, /etc/hosts), then delegates
# to focused sub-scripts for Samba and user/keytab management.
#
# Sub-scripts (uploaded by Vagrant file provisioner):
#   /tmp/setup-samba.sh      - Domain provisioning, krb5.conf, DNS registration
#   /tmp/setup-users.sh      - AD users, SPNs, encryption types, keytab export
#   /tmp/setup-dashboard.sh  - Nginx + CGI status dashboard (shared across VMs)
#
set -e

# Strip Windows carriage returns from uploaded scripts (developed on Windows)
sed -i 's/\r$//' /tmp/setup-samba.sh /tmp/setup-users.sh /tmp/setup-dashboard.sh

# =====================================================================
# 1. Install packages
# =====================================================================
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    samba krb5-user winbind smbclient \
    dnsutils iproute2 net-tools \
    ldb-tools ldap-utils libsasl2-modules-gssapi-mit \
    nginx fcgiwrap chrony

# =====================================================================
# 2. Configure NTP (Kerberos requires clocks within 5 minutes)
# =====================================================================
# The KDC serves as the NTP source for all other VMs in the lab.
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

# =====================================================================
# 3. Configure DNS to use Samba's internal DNS server
# =====================================================================
systemctl stop systemd-resolved
systemctl disable systemd-resolved
rm -f /etc/resolv.conf
echo "nameserver 127.0.0.1" > /etc/resolv.conf

# =====================================================================
# 4. Detect IP and update /etc/hosts
# =====================================================================
# Hyper-V assigns dynamic IPs, so we detect and register on every run.
KDC_IP=$(hostname -I | awk '{print $1}')
echo "==> KDC IP detected: $KDC_IP"

sed -i '/samba-ad-dc.corp.internal/d' /etc/hosts
echo "$KDC_IP samba-ad-dc.corp.internal samba-ad-dc" >> /etc/hosts

# If Samba is already running (re-provision), update the DNS A record
# immediately so other VMs can still resolve us during the rest of setup.
if systemctl is-active --quiet samba-ad-dc; then
    echo "==> Samba already running — updating A record before re-provision"
    existing_ips=$(samba-tool dns query localhost corp.internal samba-ad-dc A \
        -U Administrator --password='Str0ngPassw0rd!' 2>/dev/null \
        | awk '/A: / {print $2}') || true
    for old_ip in $existing_ips; do
        samba-tool dns delete localhost corp.internal samba-ad-dc A "$old_ip" \
            -U Administrator --password='Str0ngPassw0rd!' || true
    done
    samba-tool dns add localhost corp.internal samba-ad-dc A "$KDC_IP" \
        -U Administrator --password='Str0ngPassw0rd!' || true
fi

# =====================================================================
# 5. Provision Samba AD domain, generate krb5.conf, register DNS
# =====================================================================
source /tmp/setup-samba.sh

# =====================================================================
# 6. Create AD users, SPNs, and export keytabs
# =====================================================================
source /tmp/setup-users.sh

# =====================================================================
# 7. Deploy status dashboard
# =====================================================================
source /tmp/setup-dashboard.sh

echo ""
echo "========================================="
echo "  KDC provisioning complete. IP: $KDC_IP"
echo "  Dashboard: http://samba-ad-dc/dashboard"
echo "========================================="
