#!/bin/bash
# kdc/setup-samba.sh - Provision and configure the Samba AD Domain Controller
#
# This script handles:
#   1. First-run domain provisioning (samba-tool domain provision)
#   2. Generating a krb5.conf suitable for Java/JDBC Kerberos clients
#   3. Starting/restarting the Samba AD DC service
#   4. Registering the KDC's A record in Samba DNS
#
# Expects: $KDC_IP set by the calling script (provision.sh)

# ── First-run: provision the Samba AD domain ─────────────────────
# We use smb.conf.bak as a sentinel — if it exists, the domain was
# already provisioned on a previous run.
if [ ! -f /etc/samba/smb.conf.bak ]; then
    echo "==> Provisioning new Samba AD domain: CORP.INTERNAL"

    # Disable the standalone Samba services — the AD DC role replaces them
    systemctl stop smbd nmbd winbind
    systemctl disable smbd nmbd winbind
    systemctl unmask samba-ad-dc

    # Back up the default smb.conf before provisioning overwrites it
    mv /etc/samba/smb.conf /etc/samba/smb.conf.bak

    samba-tool domain provision \
        --use-rfc2307 \
        --realm=CORP.INTERNAL \
        --domain=CORP \
        --server-role=dc \
        --dns-backend=SAMBA_INTERNAL \
        --adminpass='Str0ngPassw0rd!' \
        --option="dns forwarder=8.8.8.8"
fi

# ── Generate krb5.conf ───────────────────────────────────────────
# Samba's auto-generated krb5.conf is too minimal — it uses
# dns_lookup_kdc=true and lacks an explicit KDC address.
# We write an explicit config that all VMs will download.
#
# udp_preference_limit = 1 forces TCP for all Kerberos traffic.
# Without this, Java's GSSAPI sends the forwarded-TGT TGS-REQ
# over UDP. The KDC response exceeds the UDP MTU and Samba returns
# KRB_ERR_RESPONSE_TOO_BIG (error 52) with an empty sname, which
# DataDirect JDBC surfaces as "Empty nameStrings not allowed".
# Java retries AS-REQ and normal TGS-REQ over TCP automatically,
# but does NOT retry the delegation TGS-REQ — so we force TCP.
cat <<EOF > /etc/krb5.conf
[libdefaults]
    default_realm = CORP.INTERNAL
    dns_lookup_realm = false
    dns_lookup_kdc = false
    udp_preference_limit = 1
    ticket_lifetime = 24h
    forwardable = true
    proxiable = true
    allow_weak_crypto = true

[realms]
    CORP.INTERNAL = {
        kdc = samba-ad-dc.corp.internal
        admin_server = samba-ad-dc.corp.internal
        default_domain = corp.internal
    }

[domain_realm]
    .corp.internal = CORP.INTERNAL
    corp.internal = CORP.INTERNAL
    .CORP.INTERNAL = CORP.INTERNAL
    CORP.INTERNAL = CORP.INTERNAL
EOF

# ── Start the Samba AD DC service ────────────────────────────────
systemctl enable samba-ad-dc
systemctl restart samba-ad-dc
echo "==> Waiting 15s for Samba AD DC to initialise..."
sleep 15

# ── Register the KDC A record in DNS ────────────────────────────
# On every provision (including re-provisions with a new Hyper-V IP),
# replace any stale A records for samba-ad-dc with the current IP.
echo "==> Registering DNS A record: samba-ad-dc -> $KDC_IP"
existing_ips=$(samba-tool dns query localhost corp.internal samba-ad-dc A \
    -U Administrator --password='Str0ngPassw0rd!' 2>/dev/null \
    | awk '/A: / {print $2}') || true

for old_ip in $existing_ips; do
    samba-tool dns delete localhost corp.internal samba-ad-dc A "$old_ip" \
        -U Administrator --password='Str0ngPassw0rd!' || true
done

samba-tool dns add localhost corp.internal samba-ad-dc A "$KDC_IP" \
    -U Administrator --password='Str0ngPassw0rd!' || true
