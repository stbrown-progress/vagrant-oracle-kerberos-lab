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
kinit -k -t /opt/artifacts/oracleuser.keytab oracleuser@CORP.INTERNAL
klist
```

Expected: `klist` shows a valid TGT for `oracleuser@CORP.INTERNAL`.

## Request a service ticket for the Oracle SPN

```bash
kvno oracle/oracle.corp.internal
klist
```

Expected: `kvno` returns a key version number and `klist` shows a service
ticket for `oracle/oracle.corp.internal`.

## Common errors

- `Client 'oracle/oracle.corp.internal@CORP.INTERNAL' not found`: the principal
  is a service principal on a user, not a standalone login. Use
  `oracleuser@CORP.INTERNAL` to get a TGT, then run `kvno` to request the
  service ticket.
- `Cannot find KDC for realm`: DNS is not pointing at the KDC or SRV records are
  missing. Check `/etc/resolv.conf` and verify the `_kerberos._udp` record.

## Why a user keytab and a service keytab are different

Kerberos has two roles:

- User or machine principals (like `oracleuser@CORP.INTERNAL`) are used to log
  in and obtain a TGT. These are "clients" in the Kerberos database.
- Service principals (like `oracle/oracle.corp.internal@CORP.INTERNAL`) identify
  a service that accepts tickets. These are stored as SPNs on a user or machine
  account and are not used to log in directly.

You can use a user keytab to authenticate and then request a service ticket via
`kvno`. The service keytab is what the Oracle service uses to decrypt and accept
those tickets.

## Plain-English mental model

- Client principals (users or machines) are the identities that can log in and
  receive a TGT.
- SPNs (service names) are the identities that clients request tickets for.
- An SPN is stored on a user or machine account, which makes that account the
  owner of the service identity.

## Short diagram

```text
Client login (user/machine)                 Service identity (SPN)

oracleuser@CORP.INTERNAL  ---- owns ---->   oracle/oracle.corp.internal
        |                                                   |
        | kinit (TGT)                                       | keytab for service
        v                                                   v
   TGT issued                                     Service accepts ticket
        |
        | kvno oracle/oracle.corp.internal
        v
 Service ticket issued
```
