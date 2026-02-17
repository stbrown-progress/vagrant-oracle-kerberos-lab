#!/bin/bash
# oracle/setup-oracle-db.sh - Wait for Oracle DB readiness and configure it
#
# This script:
#   1. Waits for the CDB (Container Database) to accept connections
#   2. Waits for FREEPDB1 (Pluggable Database) to be in READ WRITE mode
#   3. Deploys sqlnet.ora inside the container for Kerberos auth
#   4. Creates test database users (idempotent)

# =====================================================================
# 1. Wait for CDB to be ready
# =====================================================================
echo "==> Waiting for Oracle CDB (this may take several minutes on first run)..."
for i in $(seq 1 60); do
    if docker exec oracle sqlplus -s / as sysdba @/opt/scripts/check_cdb.sql > /dev/null 2>&1; then
        echo "==> Oracle CDB is up after ${i}0 seconds."
        break
    fi
    sleep 10
done

# =====================================================================
# 2. Wait for FREEPDB1 to open
# =====================================================================
echo "==> Waiting for FREEPDB1 to be in READ WRITE mode..."
for i in $(seq 1 30); do
    status=$(docker exec oracle sqlplus -s / as sysdba \
        @/opt/scripts/check_pdb.sql 2>/dev/null \
        | grep -o "READ WRITE" || true)
    if [ "$status" = "READ WRITE" ]; then
        echo "==> FREEPDB1 is open."
        break
    fi
    echo "    Waiting for FREEPDB1 ($i/30)..."
    sleep 10
done

# =====================================================================
# 3. Deploy sqlnet.ora inside the container
# =====================================================================
# docker exec runs as root without Oracle's env, so we detect
# ORACLE_HOME from the oracle user's profile.
docker exec oracle bash -c '
OH=$(su - oracle -c "echo \$ORACLE_HOME" 2>/dev/null)
if [ -z "$OH" ]; then
    OH=$(ls -d /opt/oracle/product/*/dbhome* 2>/dev/null | head -1)
fi
if [ -n "$OH" ]; then
    mkdir -p "$OH/network/admin"
    cp /opt/scripts/sqlnet.ora "$OH/network/admin/sqlnet.ora"
    echo "==> Deployed sqlnet.ora to $OH/network/admin/"
else
    echo "WARNING: Could not determine ORACLE_HOME inside container"
fi
'

# =====================================================================
# 4. Create test users (idempotent — skips if they already exist)
# =====================================================================
echo "==> Creating database users..."
docker exec oracle sqlplus -s / as sysdba @/opt/scripts/create_users.sql
