#!/bin/bash
# oracle/setup-dns-registration.sh - Register Oracle VM in Samba DNS
#
# Uses the 'dnsupdater' service account (via keytab) to authenticate
# against the Samba AD DC and register this VM's A record. This allows
# other VMs to resolve "oracle.corp.internal" to the current dynamic IP.
#
# Expects: $KDC_IP and $ORACLE_IP set by the calling script

export KRB5_CONFIG=/opt/artifacts/krb5.conf

# ── Authenticate as dnsupdater ───────────────────────────────────
kinit -k -t /opt/artifacts/dnsupdater.keytab dnsupdater@CORP.INTERNAL

# ── Replace any stale A records with the current IP ──────────────
existing_ips=$(samba-tool dns query samba-ad-dc corp.internal oracle A \
    -k yes 2>/dev/null | awk '/A: / {print $2}')

for ip in $existing_ips; do
    samba-tool dns delete samba-ad-dc corp.internal oracle A "$ip" -k yes || true
done

samba-tool dns add samba-ad-dc corp.internal oracle A "$ORACLE_IP" -k yes
kdestroy || true

# ── Verify the registration ─────────────────────────────────────
echo "==> DNS lookup for oracle.corp.internal:"
dig +short @"$KDC_IP" oracle.corp.internal || true
