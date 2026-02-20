#!/bin/bash
# test/test_auth.sh - End-to-end Kerberos authentication test for Oracle
#
# Tests: prerequisites -> KDC connectivity -> DNS -> kinit -> kvno -> sqlplus
# Exits on first failure so you can see exactly where the chain breaks.
set -e

IC_DIR="/opt/oracle/instantclient"
export LD_LIBRARY_PATH=$IC_DIR:$LD_LIBRARY_PATH
export PATH=$IC_DIR:$PATH
export TNS_ADMIN=$IC_DIR/network/admin

# --- Prerequisites ---
echo "--- Checking prerequisites ---"

if ! command -v sqlplus &>/dev/null; then
    echo "FAIL: sqlplus not found. Run ./install-oracle.sh first."
    exit 1
fi

if [ ! -f "$TNS_ADMIN/sqlnet.ora" ]; then
    echo "FAIL: $TNS_ADMIN/sqlnet.ora not found."
    echo "  Re-run ./install-oracle.sh or: lab provision test"
    exit 1
fi

if [ ! -f /etc/krb5.conf ]; then
    echo "FAIL: /etc/krb5.conf not found. Run: lab provision test"
    exit 1
fi

echo "OK: sqlplus, sqlnet.ora, krb5.conf all present"

# --- KDC Connectivity ---
echo -e "\n--- Testing KDC Connectivity ---"
nc -zv samba-ad-dc.corp.internal 88

# --- DNS ---
echo -e "\n--- Validating DNS for Oracle ---"
ORACLE_IP=$(dig +short oracle.corp.internal)
if [ -z "$ORACLE_IP" ]; then
    echo "FAIL: oracle.corp.internal does not resolve"
    exit 1
fi
echo "$ORACLE_IP"

# --- SQL*Net config ---
echo -e "\n--- SQL*Net config ---"
cat "$TNS_ADMIN/sqlnet.ora"

# --- Kerberos TGT ---
echo -e "\n--- Requesting TGT ---"
kdestroy -A 2>/dev/null || true
echo "StrongPassword123!" | kinit oracleuser@CORP.INTERNAL
klist

# --- Service ticket ---
echo -e "\n--- Requesting a service ticket for Oracle ---"
kvno oracle/oracle.corp.internal
klist

# --- Oracle connection ---
echo -e "\n--- Connecting to Oracle via SQLPlus (Kerberos) ---"
sqlplus -L /@oracle.corp.internal:1521/FREEPDB1 <<EXITSQL
PROMPT Successfully connected to Oracle!
select
    'USER=' || user ||
    ' | AUTH_METHOD=' || sys_context('userenv', 'authentication_method') ||
    ' | IDENTITY='   || sys_context('userenv', 'authenticated_identity')
    as "SESSION_INFO"
from dual;
EXITSQL
