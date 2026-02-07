#!/bin/bash
IC_DIR="/opt/oracle/instantclient"
export LD_LIBRARY_PATH=/opt/oracle/instantclient:$LD_LIBRARY_PATH
export PATH=/opt/oracle/instantclient:$PATH
export TNS_ADMIN=/opt/oracle/instantclient/network/admin

echo "--- Testing KDC Connectivity ---"
nc -zv samba-ad-dc.corp.internal 88

echo -e "\n--- Validating DNS for Oracle ---"
dig +short oracle.corp.internal || true

echo -e "\n--- Confirming SQL*Net config ---"
ls -l "$TNS_ADMIN/sqlnet.ora"

echo -e "\n--- Requesting TGT ---"
kdestroy -A 2>/dev/null || true
echo "StrongPassword123!" | kinit oracleuser@CORP.INTERNAL
klist

echo -e "\n--- Requesting a service ticket for Oracle ---"
kvno oracle/oracle.corp.internal
klist

echo -e "\n--- Connecting to Oracle via SQLPlus (Kerberos) ---"
sqlplus -L /@oracle.corp.internal:1521/FREEPDB1 <<EXITSQL
PROMPT Successfully connected to Oracle!
SELECT 'Authenticated User: ' || USER FROM DUAL;
SELECT 'Authentication Method: ' || AUTHENTICATION_METHOD
FROM V$SESSION_CONNECT_INFO
WHERE SID = SYS_CONTEXT('USERENV', 'SID');
EXITSQL
