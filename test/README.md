# Test Client VM

Ubuntu 22.04 Linux client for validating Kerberos authentication and Oracle
connectivity against the lab environment.

## Access

```bash
# From the test/ directory
vagrant ssh

# Or via SSH/SFTP on the forwarded port
ssh -p 2224 vagrant@127.0.0.1    # password: vagrant
sftp -P 2224 vagrant@127.0.0.1
```

## Validation Steps

Run these after provisioning to confirm the test client is healthy.

### 1. DNS Resolution

```bash
# Resolve the KDC
dig +short samba-ad-dc.corp.internal

# Resolve the Oracle VM
dig +short oracle.corp.internal
```

Both should return IP addresses. If they fail, check that `/etc/resolv.conf`
points to the KDC IP:

```bash
cat /etc/resolv.conf
```

### 2. KDC Connectivity

```bash
nc -zv samba-ad-dc.corp.internal 88
```

Expected: `Connection to samba-ad-dc.corp.internal 88 port [tcp/kerberos] succeeded!`

### 3. Kerberos TGT via Password

```bash
kdestroy -A 2>/dev/null
echo "StrongPassword123!" | kinit oracleuser@CORP.INTERNAL
klist
```

Expected: `klist` shows a valid TGT for `oracleuser@CORP.INTERNAL` with an
expiration time in the future.

### 4. Kerberos TGT via Keytab

The `oracleuser.keytab` is available on the KDC web server. Download it first:

```bash
wget -q http://$(cat /etc/resolv.conf | awk '/nameserver/{print $2}')/artifacts/oracleuser.keytab
```

Then authenticate with it:

```bash
kdestroy -A 2>/dev/null
kinit -kt oracleuser.keytab oracleuser@CORP.INTERNAL
klist
```

> **Note:** You must specify the principal (`oracleuser@CORP.INTERNAL`) when
> using `-kt`. Without it, `kinit` defaults to `host/localhost@` which is not
> in the keytab.

### 5. Service Ticket for Oracle

After obtaining a TGT (steps 3 or 4):

```bash
kvno oracle/oracle.corp.internal
klist
```

Expected: `kvno` returns a version number and `klist` shows a service ticket
for `oracle/oracle.corp.internal@CORP.INTERNAL`.

### 6. NTP / Time Sync

Kerberos requires clocks to be within 5 minutes. Verify:

```bash
chronyc tracking
```

Look for `Leap status: Normal` and a small `System time` offset.

## Oracle Instant Client

The provisioner creates a helper script to install Oracle Instant Client
(required for `sqlplus` connectivity from this VM):

```bash
./install-oracle.sh
```

This downloads and installs Oracle Instant Client 19.29 to
`/opt/oracle/instantclient`. After install, reload your shell:

```bash
source ~/.bashrc
sqlplus -V
```

## Testing Oracle Connectivity

After installing the Instant Client, use the generated test script:

```bash
./test_auth.sh
```

This script performs the full end-to-end test:
1. KDC connectivity check (port 88)
2. DNS resolution for `oracle.corp.internal`
3. SQL*Net config verification
4. TGT acquisition for `oracleuser`
5. Service ticket request for `oracle/oracle.corp.internal`
6. SQL*Plus Kerberos login to `FREEPDB1`

### Manual SQLPlus Test (Password Auth)

```bash
sqlplus testuser/testpassword@oracle.corp.internal:1521/FREEPDB1
```

### Manual SQLPlus Test (Kerberos Auth)

```bash
kinit -kt oracleuser.keytab oracleuser@CORP.INTERNAL
sqlplus -L /@oracle.corp.internal:1521/FREEPDB1
```

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| `dig` returns nothing | DNS not pointing at KDC | Check `/etc/resolv.conf` has KDC IP |
| `kinit: Cannot find KDC` | DNS SRV records missing or unreachable | Verify `dig _kerberos._udp.corp.internal SRV` returns a result |
| `kinit: Clock skew too great` | Time drift > 5 minutes | Run `sudo chronyc makestep` to force sync |
| `kinit: Cannot determine realm for host` | Missing principal in `kinit -kt` command | Add `oracleuser@CORP.INTERNAL` after the keytab path |
| `ORA-12170: TNS:Connect Timeout` | Oracle VM not reachable or listener down | Check `dig oracle.corp.internal` and `nc -zv oracle.corp.internal 1521` |
| `ORA-01017: invalid credentials` | DB user not created or wrong auth method | Verify users exist on the Oracle VM (see oracle/README.md) |
