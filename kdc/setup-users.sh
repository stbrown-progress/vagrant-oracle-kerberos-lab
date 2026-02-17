#!/bin/bash
# kdc/setup-users.sh - Create AD service accounts, SPNs, and export keytabs
#
# This script handles:
#   1. Creating the 'oracleuser' account (Oracle DB Kerberos principal)
#   2. Creating the 'dnsupdater' account (dynamic DNS registration)
#   3. Setting SPNs and encryption types for Kerberos auth
#   4. Exporting keytabs for other VMs to download via Nginx
#
# Expects: Samba AD DC is running and $KDC_IP is set

# ── Create service accounts (idempotent) ─────────────────────────

# oracleuser — the Kerberos principal that Oracle DB authenticates as.
# Oracle maps this to the DB user "oracleuser@CORP.INTERNAL".
if ! samba-tool user list | grep -q "oracleuser"; then
    echo "==> Creating AD user: oracleuser"
    samba-tool user create oracleuser StrongPassword123!
fi

# dnsupdater — used by the Oracle VM to register its own DNS A record
# in Samba DNS via Kerberos-authenticated samba-tool commands.
if ! samba-tool user list | grep -q "dnsupdater"; then
    echo "==> Creating AD user: dnsupdater"
    samba-tool user create dnsupdater StrongPassword123!
fi

# dnsupdater needs DnsAdmins membership to modify DNS records
samba-tool group addmembers "DnsAdmins" dnsupdater || true

# ── Disable password expiry for service accounts ────────────────
samba-tool user setexpiry Administrator --noexpiry || true
samba-tool user setexpiry oracleuser   --noexpiry || true
samba-tool user setexpiry dnsupdater   --noexpiry || true

# ── Register SPN for Oracle Kerberos authentication ──────────────
# The SPN "oracle/oracle.corp.internal" is what Oracle clients use
# to request a service ticket. It must be mapped to the oracleuser
# account so the keytab can decrypt those tickets.
echo "Str0ngPassw0rd!" | kinit Administrator
samba-tool spn add oracle/oracle.corp.internal oracleuser || true

# ── Enable strong Kerberos encryption types ──────────────────────
# Value 31 = DES-CBC-CRC(1) + DES-CBC-MD5(2) + RC4-HMAC(4) +
#            AES128(8) + AES256(16). This ensures AES is available
# for Oracle's Kerberos implementation.
cat <<EOF | ldapmodify -Y GSSAPI -H ldap://localhost
dn: CN=oracleuser,CN=Users,DC=corp,DC=internal
changetype: modify
replace: msDS-SupportedEncryptionTypes
msDS-SupportedEncryptionTypes: 31
EOF

# ── Export keytabs for other VMs ─────────────────────────────────
# Keytabs are served via Nginx at http://<kdc-ip>/artifacts/
# so oracle and test VMs can download them during their provisioning.
#
# IMPORTANT: samba-tool exportkeytab APPENDS to existing files,
# so we must delete stale keytabs first to avoid duplicate entries.
echo "==> Exporting keytabs to /var/www/html/artifacts/"
mkdir -p /var/www/html/artifacts
cp /etc/krb5.conf /var/www/html/artifacts/krb5.conf
rm -f /var/www/html/artifacts/*.keytab

# oracle.keytab — service principal for the Oracle listener
samba-tool domain exportkeytab \
    --principal=oracle/oracle.corp.internal@CORP.INTERNAL \
    /var/www/html/artifacts/oracle.keytab

# oracleuser.keytab — user principal for client-side kinit
samba-tool domain exportkeytab \
    --principal=oracleuser@CORP.INTERNAL \
    /var/www/html/artifacts/oracleuser.keytab

# dnsupdater.keytab — used by the Oracle VM to register DNS records
samba-tool domain exportkeytab \
    --principal=dnsupdater@CORP.INTERNAL \
    /var/www/html/artifacts/dnsupdater.keytab

chmod 644 /var/www/html/artifacts/*

# ── Verification output ─────────────────────────────────────────
echo ""
echo "==> SPNs for oracleuser:"
samba-tool spn list oracleuser || true
echo ""
echo "==> Keytab principals:"
for kt in oracle.keytab oracleuser.keytab dnsupdater.keytab; do
    echo "--- $kt ---"
    klist -k /var/www/html/artifacts/$kt || true
done
