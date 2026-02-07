# Oracle VM

Ubuntu 22.04 host running Oracle 23c Free in Docker with Kerberos authentication
configured against the Samba AD DC (KDC).

## Access

```bash
# From the oracle/ directory
vagrant ssh

# Docker container shell
vagrant ssh -c "docker exec -it oracle bash"
```

## Validation Steps

Run these after provisioning to confirm Oracle and Kerberos are healthy.

### 1. DNS Resolution

```bash
dig +short samba-ad-dc.corp.internal
dig +short oracle.corp.internal
```

Both should return IP addresses. `oracle.corp.internal` should resolve to this
VM's own IP (registered dynamically via `samba-tool dns`).

### 2. NTP / Time Sync

```bash
chronyc tracking
```

Look for `Leap status: Normal` and a small `System time` offset. Kerberos
requires clocks to be within 5 minutes.

### 3. Keytab Verification

```bash
export KRB5_CONFIG=/opt/artifacts/krb5.conf
klist -k /opt/artifacts/oracle.keytab
klist -k /opt/artifacts/oracleuser.keytab
```

Expected principals:
- `oracle.keytab`: `oracle/oracle.corp.internal@CORP.INTERNAL`
- `oracleuser.keytab`: `oracleuser@CORP.INTERNAL`

### 4. Kerberos TGT

```bash
export KRB5_CONFIG=/opt/artifacts/krb5.conf
kinit -k -t /opt/artifacts/oracleuser.keytab oracleuser@CORP.INTERNAL
klist
```

Expected: a valid TGT for `oracleuser@CORP.INTERNAL`.

### 5. Service Ticket

```bash
kvno oracle/oracle.corp.internal
klist
```

Expected: `kvno` returns a version number and `klist` shows a service ticket
for `oracle/oracle.corp.internal@CORP.INTERNAL`.

### 6. Oracle Container Status

```bash
docker ps -f name=oracle
docker logs oracle --tail 20
```

The container should be `Up` and the logs should show `DATABASE IS READY TO USE!`.

### 7. Database Connectivity

```bash
docker exec oracle sqlplus -s / as sysdba @/opt/scripts/check_pdb.sql
```

Expected output includes `READ WRITE`, confirming `FREEPDB1` is open.

### 8. Verify DB Users

```bash
docker exec oracle sqlplus -s / as sysdba @/opt/scripts/create_users.sql
```

This is idempotent. Expected output includes both `TESTUSER` and
`ORACLEUSER@CORP.INTERNAL` in the query results.

### 9. Test Password Login

```bash
docker exec -it oracle sqlplus testuser/testpassword@localhost:1521/FREEPDB1
```

### 10. SQL*Net (Kerberos) Configuration

Verify `sqlnet.ora` is deployed inside the container:

```bash
docker exec oracle bash -c 'cat $ORACLE_HOME/network/admin/sqlnet.ora 2>/dev/null || cat /opt/oracle/product/*/dbhome*/network/admin/sqlnet.ora'
```

Should show `SQLNET.AUTHENTICATION_SERVICES = (BEQ, KERBEROS5PRE, KERBEROS5)`.

## Architecture

```text
Host VM (Ubuntu 22.04)
  |
  +-- /opt/artifacts/        Keytabs + krb5.conf (downloaded from KDC)
  |     oracle.keytab        Service keytab for Oracle SPN
  |     oracleuser.keytab    User keytab for oracleuser
  |     dnsupdater.keytab    Keytab for dynamic DNS registration
  |     krb5.conf            Kerberos realm config
  |
  +-- /opt/scripts/          Shared into container via Docker volume
  |     sqlnet.ora           Oracle network config (Kerberos enabled)
  |     setup-sqlnet.sh      Entrypoint script to deploy sqlnet.ora
  |     check_cdb.sql        Health check for CDB readiness
  |     check_pdb.sql        Health check for FREEPDB1 readiness
  |     create_users.sql     Idempotent user creation script
  |
  +-- Docker container (--net=host)
        Oracle 23c Free
        Port 1521 (listener)
        PDB: FREEPDB1
```

## Kerberos Principals

| Principal | Purpose | Keytab |
|-----------|---------|--------|
| `oracleuser@CORP.INTERNAL` | User login, obtains TGTs | `oracleuser.keytab` |
| `oracle/oracle.corp.internal@CORP.INTERNAL` | Service SPN, Oracle accepts tickets with this | `oracle.keytab` |
| `dnsupdater@CORP.INTERNAL` | Registers Oracle's A record in Samba DNS | `dnsupdater.keytab` |

## DB Users

| Username | Auth Method | Purpose |
|----------|-------------|---------|
| `testuser` | Password (`testpassword`) | Basic connectivity testing |
| `oracleuser@CORP.INTERNAL` | Kerberos (externally identified) | Kerberos SSO testing |

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Container not starting | Image not pulled yet | First run pulls ~4GB; check `docker logs oracle` |
| `FREEPDB1` not open | DB still initializing | Wait; check with `check_pdb.sql` (can take 5+ min on first run) |
| `sqlnet.ora` not found in container | `ORACLE_HOME` detection failed | Run the deploy command manually (see step 10) |
| `kinit: Cannot find KDC` | DNS not pointing at KDC | Check `/etc/resolv.conf` has KDC IP |
| `kinit: Clock skew too great` | Time drift > 5 minutes | Run `sudo chronyc makestep` |
| DNS registration failed | `dnsupdater` keytab stale | Re-provision KDC to re-export keytabs, then re-provision Oracle |
| `ORA-01017: invalid credentials` | DB users not created | Run `docker exec oracle sqlplus -s / as sysdba @/opt/scripts/create_users.sql` |

## Why `--net=host`?

The Oracle container uses `--net=host` so it shares the VM's network stack.
This means:
- The listener binds directly to port 1521 on the VM's IP
- Kerberos reverse DNS lookups resolve correctly (no Docker NAT)
- `--dns` flags are ignored with `--net=host` (DNS comes from the host's `/etc/resolv.conf`)
