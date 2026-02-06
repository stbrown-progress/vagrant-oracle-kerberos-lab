# Vagrant Oracle + Samba AD Kerberos Lab

A multi-VM Vagrant lab that builds an Oracle Database environment with Kerberos authentication backed by a Samba Active Directory domain controller. Includes Linux and Windows test clients for end-to-end auth testing.

## Architecture

```
┌──────────────────────────────────────────────────┐
│              KDC  (samba-ad-dc)                   │
│  Samba AD DC · Kerberos KDC · Internal DNS        │
│  Serves keytabs + krb5.conf via Nginx (HTTP)      │
└───────────┬──────────────┬───────────────────────┘
            │              │
   ┌────────┴───┐   ┌──────┴──────┐   ┌────────────┐
   │  Oracle VM │   │  Test Client │   │ Win Client  │
   │  (Docker)  │   │   (Linux)   │   │ (Win 10)    │
   │  23c Free  │   │  SQLPlus    │   │ Domain-join │
   └────────────┘   └─────────────┘   └─────────────┘
```

## Prerequisites

- **Hyper-V** enabled (Windows Pro/Enterprise/Server)
- **Vagrant** >= 2.3 with the Hyper-V provider
- An **external Hyper-V virtual switch** (bridged) — Vagrant will prompt you to select one
- Admin shell for `vagrant up` (Hyper-V requires elevation)

## Quick Start

VMs must be started in order because later VMs depend on the KDC:

```powershell
# 1. Start the domain controller (writes .kdc_ip for other VMs)
cd kdc
vagrant up

# 2. Start the Oracle database server
cd ../oracle
vagrant up

# 3. Start test clients (can be started in parallel)
cd ../test
vagrant up

cd ../win-test
vagrant up
# After first boot: vagrant reload   (to complete domain join reboot)
```

## VMs

| VM | Directory | Box | RAM | Purpose |
|----|-----------|-----|-----|---------|
| samba-ad-dc | `kdc/` | generic/ubuntu2204 | 1 GB | Samba AD DC, Kerberos KDC, DNS |
| oracle-db | `oracle/` | generic/ubuntu2204 | 4 GB | Oracle 23c Free in Docker |
| test-client | `test/` | generic/ubuntu2204 | 1 GB | Linux client with Oracle Instant Client |
| win-client | `win-test/` | gusztavvargadr/windows-10 | 4 GB | Domain-joined Windows 10 |

## Domain Details

| Setting | Value |
|---------|-------|
| Realm / Domain | `CORP.INTERNAL` |
| NetBIOS name | `CORP` |
| Domain Admin | `Administrator` / `Str0ngPassw0rd!` |
| Oracle service account | `oracleuser` / `StrongPassword123!` |
| DNS updater account | `dnsupdater` / `StrongPassword123!` |
| Oracle SYS password | `Str0ngPassw0rd!` |
| Oracle test user | `testuser` / `testpassword` |

## Testing Kerberos Authentication

From the **test client** VM:

```bash
vagrant ssh              # from the test/ directory
./install-oracle.sh      # one-time Oracle Instant Client install
./test_auth.sh           # runs full Kerberos auth test
```

The test script will:
1. Verify KDC connectivity (port 88)
2. Resolve `oracle.corp.internal` via DNS
3. Obtain a TGT for `oracleuser@CORP.INTERNAL`
4. Request a service ticket for `oracle/oracle.corp.internal`
5. Connect to Oracle via SQLPlus using Kerberos
6. Query the session authentication method

## How It Works

### IP Discovery
The KDC writes its IP to `.kdc_ip` after boot. All other VMs read this file at `vagrant up` time and pass it to their provisioning scripts.

### Artifact Distribution
The KDC exports keytabs and `krb5.conf` to `/var/www/html/artifacts/` and serves them via Nginx. Other VMs download these over HTTP during provisioning.

### Dynamic DNS
The Oracle VM authenticates to the KDC with a dedicated `dnsupdater` keytab, removes stale A records, and registers its current IP in Samba DNS.

### Time Sync
All Linux VMs run `chrony`. The KDC syncs with `pool.ntp.org` and acts as a local NTP server. Other VMs sync to the KDC to prevent Kerberos clock-skew failures.

### Host File Management
Vagrant triggers automatically update the Windows host machine's `hosts` file so you can reach VMs by name (e.g., `oracle.corp.internal`). Entries are cleaned up on `vagrant destroy`.

## Troubleshooting

### DNS not resolving
- Verify `/etc/resolv.conf` points to the KDC IP
- Check `dig oracle.corp.internal` from inside the VM
- Ensure `_kerberos._udp.corp.internal` SRV record exists: `dig _kerberos._udp.corp.internal SRV`

### Kerberos auth failures
- Check clock skew: `chronyc tracking` on both VMs (must be < 5 min)
- Verify keytab: `klist -k /opt/artifacts/oracle.keytab`
- Test TGT manually: `kinit -k -t /opt/artifacts/oracleuser.keytab oracleuser@CORP.INTERNAL`
- Check SPN: `samba-tool spn list oracleuser` (on KDC)

### Oracle container not starting
- Check status: `docker ps -a`
- View logs: `docker logs -f oracle`
- Verify sqlnet.ora placement: `docker exec oracle cat $ORACLE_HOME/network/admin/sqlnet.ora`

### Windows domain join fails
- Verify DNS: `Resolve-DnsName samba-ad-dc.corp.internal`
- Ping KDC: `Test-Connection <KDC_IP>`
- Check network profile is Private (not Public)
- Review Event Viewer > Windows Logs > System

## Project Structure

```
vagrant-lab/
├── README.md                    # This file
├── .gitignore
├── .kdc_ip                      # Auto-generated KDC IP (gitignored)
├── lib/
│   ├── hosts_trigger.rb         # Shared Vagrant trigger for hosts file mgmt
│   └── fetch_with_retry.sh      # Shared download-with-retry helper
├── kdc/
│   ├── Vagrantfile
│   ├── provision.sh
│   └── README.md
├── oracle/
│   ├── Vagrantfile
│   ├── provision.sh
│   └── README.md
├── test/
│   ├── Vagrantfile
│   ├── provision.sh
│   └── README.md
└── win-test/
    ├── Vagrantfile
    └── provision.ps1
```
