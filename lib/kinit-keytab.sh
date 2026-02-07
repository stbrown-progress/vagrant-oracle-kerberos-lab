#!/bin/bash
# Obtain a Kerberos TGT using the oracleuser keytab.
# Usage: ./kinit-keytab.sh

KEYTAB="$HOME/oracleuser.keytab"

if [ ! -f "$KEYTAB" ]; then
    echo "ERROR: Keytab not found at $KEYTAB"
    echo "The provisioner should have downloaded it. Try:"
    echo "  wget -q http://\$(awk '/nameserver/{print \$2}' /etc/resolv.conf)/artifacts/oracleuser.keytab"
    exit 1
fi

kdestroy -A 2>/dev/null || true
kinit -kt "$KEYTAB" oracleuser@CORP.INTERNAL
echo "TGT obtained:"
klist
