#!/bin/bash
# Oracle VM Status Dashboard - CGI Script
source /usr/local/lib/dashboard-common.sh

dashboard_begin "Oracle Database — Status Dashboard"
dashboard_nav

dashboard_run_section "Docker Container Status" \
    "docker ps -a --filter name=oracle --no-trunc --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'"

# lsnrctl needs the oracle user's environment (ORACLE_HOME, PATH, etc.).
# Use "docker exec --user oracle" with a login shell to load the profile.
lsnr_output=$(docker exec --user oracle oracle bash -lc "lsnrctl status" 2>&1) || true
dashboard_section "Oracle Listener Status" \
    "docker exec --user oracle oracle bash -lc \"lsnrctl status\"" \
    "$lsnr_output"

dashboard_run_section "PDB Status" \
    "docker exec oracle sqlplus -s / as sysdba @/opt/scripts/check_pdb.sql"

# DB users query — use a SQL file on the shared volume
cat <<'EOSQL' > /opt/scripts/dashboard_users.sql
ALTER SESSION SET CONTAINER = FREEPDB1;
SET LINESIZE 120
SET PAGESIZE 50
COLUMN username FORMAT A40
SELECT username FROM all_users WHERE username IN ('TESTUSER','ORACLEUSER@CORP.INTERNAL','SYS','SYSTEM') ORDER BY username;
EXIT;
EOSQL
dashboard_run_section "Database Users (FREEPDB1)" \
    "docker exec oracle sqlplus -s / as sysdba @/opt/scripts/dashboard_users.sql"

dashboard_run_section "Keytab: oracle.keytab" \
    "KRB5_CONFIG=/opt/artifacts/krb5.conf klist -k /opt/artifacts/oracle.keytab"

dashboard_run_section "Keytab: oracleuser.keytab" \
    "KRB5_CONFIG=/opt/artifacts/krb5.conf klist -k /opt/artifacts/oracleuser.keytab"

dashboard_run_section "DNS: oracle.corp.internal" \
    "dig +short oracle.corp.internal"

dashboard_run_section "NTP Status" \
    "chronyc tracking"

# Show the sqlnet.ora deployed inside the container
sqlnet_output=$(docker exec oracle bash -c 'cat $(ls -d /opt/oracle/product/*/dbhome*/network/admin/sqlnet.ora 2>/dev/null | head -1) 2>/dev/null || echo "sqlnet.ora not found"') || true
dashboard_section "SQL*Net Configuration (inside container)" \
    "cat \$ORACLE_HOME/network/admin/sqlnet.ora" \
    "$sqlnet_output"

# Show the tail of the most recent server trace file (one per connection)
dashboard_run_section "Oracle Server Trace (latest, last 50 lines)" \
    "docker exec oracle bash -c 'f=\$(ls -t /tmp/server*.trc 2>/dev/null | head -1); [ -n \"\$f\" ] && echo \"\$f\" && echo \"---\" && tail -50 \"\$f\" || echo \"No trace files found\"'" \
    ""

dashboard_run_section "Docker Logs (last 30 lines)" \
    "docker logs oracle --tail 30" \
    ""

dashboard_end
