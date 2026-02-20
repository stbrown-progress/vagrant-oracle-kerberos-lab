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

From an **elevated PowerShell** prompt (Hyper-V requires admin):

```powershell
# Bring up all VMs in dependency order (KDC → Oracle → clients)
.\up.ps1

# Or start a single VM
.\up.ps1 oracle

# Tear down everything
.\down.ps1

# Tear down a single VM
.\down.ps1 test
```

You can also manage individual VMs directly:

```powershell
cd kdc
vagrant up          # start
vagrant ssh         # connect
vagrant destroy -f  # tear down
```

**Note:** After the Windows client's first boot, run `vagrant reload` from `win-test/` to complete the domain join reboot.

### Rebuilding the KDC (UNTESTED!)

If you need to destroy and recreate the KDC without losing your other VMs:

```powershell
.\rebuild-kdc.ps1
```

This destroys the KDC, rebuilds it from scratch, and re-provisions all running VMs with the new KDC IP and fresh keytabs. Linux VMs recover automatically. The Windows client requires extra steps after the script (domain re-join + reboots) — the script prints instructions.

## VMs

| VM | Directory | Box | RAM | Purpose |
|----|-----------|-----|-----|---------|
| samba-ad-dc | `kdc/` | generic/ubuntu2204 | 1 GB | Samba AD DC, Kerberos KDC, DNS |
| oracle-db | `oracle/` | generic/ubuntu2204 | 4 GB | Oracle 23c Free in Docker |
| test-client | `test/` | generic/ubuntu2204 | 1 GB | Linux client with Oracle Instant Client |
| win-client | `win-test/` | gusztavvargadr/windows-10 | 4 GB | Domain-joined Windows 10 (RDP, Java, Dashboard) |

## Domain Details

| Setting | Value |
|---------|-------|
| Realm / Domain | `CORP.INTERNAL` |
| NetBIOS name | `CORP` |
| Domain Admin | `Administrator` / `Str0ngPassw0rd!` |
| Oracle service account | `oracleuser` / `StrongPassword123!` |
| DNS updater account | `dnsupdater` / `StrongPassword123!` |
| Oracle SYS password | `Str0ngPassw0rd!` |
| Windows test user | `winuser` / `StrongPassword123!` |
| Oracle test user | `testuser` / `testpassword` |

## Windows Client (RDP)

After the Windows client is provisioned and rebooted (`vagrant reload`):

```
# Connect via RDP (from the host machine)
mstsc /v:win-client.corp.internal

# Login as the domain user
Username: CORP\winuser
Password: StrongPassword123!
```

The Windows client has:
- **Domain membership**: Joined to `CORP.INTERNAL`
- **RDP**: Enabled for remote desktop access
- **Dashboard**: Status page at `http://win-client/dashboard`

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
├── up.ps1                       # Orchestrator: bring up VMs in order
├── down.ps1                     # Orchestrator: tear down VMs
├── rebuild-kdc.ps1              # Destroy + rebuild KDC, re-provision dependents
├── .gitignore
├── .kdc_ip                      # Auto-generated KDC IP (gitignored)
├── lib/
│   ├── hosts_trigger.rb         # Shared Vagrant trigger for Windows hosts file
│   ├── fetch_with_retry.sh      # Shared download-with-retry helper
│   ├── dashboard-common.sh      # Shared dashboard HTML/CSS helpers
│   └── setup-dashboard.sh       # Shared Nginx + CGI dashboard deployment
├── kdc/
│   ├── Vagrantfile
│   ├── provision.sh             # Orchestrator: packages, NTP, DNS, delegates
│   ├── setup-samba.sh           # Samba AD domain provisioning + krb5.conf
│   ├── setup-users.sh           # AD users, SPNs, encryption, keytab export
│   ├── dashboard-kdc.sh         # KDC status dashboard CGI script
│   └── README.md
├── oracle/
│   ├── Vagrantfile
│   ├── provision.sh             # Orchestrator: packages, NTP, DNS, delegates
│   ├── setup-dns-registration.sh # Register VM IP in Samba DNS via keytab
│   ├── setup-docker.sh          # Install Docker, run Oracle Free container
│   ├── setup-oracle-db.sh       # Wait for DB, deploy sqlnet.ora, create users
│   ├── sqlnet.ora               # Oracle server-side Kerberos network config
│   ├── create_users.sql         # Idempotent DB user creation (FREEPDB1)
│   ├── check_cdb.sql            # CDB readiness check query
│   ├── check_pdb.sql            # PDB readiness check query
│   ├── dashboard-oracle.sh      # Oracle status dashboard CGI script
│   └── README.md
├── test/
│   ├── Vagrantfile
│   ├── provision.sh             # Orchestrator: packages, NTP, DNS, helpers
│   ├── dashboard-test.sh        # Test client status dashboard CGI script
│   ├── install-oracle.sh        # Oracle Instant Client installer
│   ├── kinit-keytab.sh          # Kerberos TGT helper (keytab-based)
│   ├── test_auth.sh             # End-to-end Kerberos + Oracle auth test
│   ├── connect.isql             # Password-based Oracle connection script
│   ├── connect-kerb.isql        # Kerberos-based Oracle connection script
│   ├── sqlnet-client.ora        # SQL*Net client Kerberos config
│   └── README.md
└── win-test/
    ├── Vagrantfile
    ├── provision.ps1             # Orchestrator: DNS, connectivity, delegates
    ├── setup-domain-join.ps1     # AD domain join with DNS wait loop
    ├── setup-java.ps1            # Eclipse Temurin 21 LTS (JDK) installation
    ├── setup-rdp.ps1             # Enable RDP + firewall + user access
    ├── setup-dashboard.ps1       # NSSM service install for dashboard
    └── dashboard-win.ps1         # PowerShell HTTP listener dashboard
```
