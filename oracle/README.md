# Oracle VM Kerberos Checks

Use these steps from the Oracle VM (not inside the Docker container) to verify
that Kerberos is working and the keytab is valid.

## DNS and realm discovery

```bash
dig +short samba-ad-dc.corp.internal
dig +short _kerberos._udp.corp.internal SRV
```

Expected: the KDC IP for the first command and a SRV record pointing at
`samba-ad-dc.corp.internal` for the second.

## Verify the keytab contents

```bash
klist -k /opt/artifacts/oracle.keytab
```

Expected: `oracle/oracle.corp.internal@CORP.INTERNAL` appears in the list.

## Obtain a TGT using the keytab

```bash
export KRB5_CONFIG=/opt/artifacts/krb5.conf
kinit -k -t /opt/artifacts/oracle.keytab oracle/oracle.corp.internal@CORP.INTERNAL
klist
```

Expected: `klist` shows a valid TGT for the oracle principal.

## Common errors

- `Client 'oracle/oracle.corp.internal@CORP.INTERNAL' not found`: the principal
  was not created in the KDC or the KDC was provisioned before the SPN change.
  Re-provision the KDC and fetch a new keytab.
- `Cannot find KDC for realm`: DNS is not pointing at the KDC or SRV records are
  missing. Check `/etc/resolv.conf` and verify the `_kerberos._udp` record.
