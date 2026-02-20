# Vagrant Oracle + Samba AD Kerberos Lab

A multi-VM Vagrant lab that builds an Oracle Database environment with Kerberos authentication backed by a Samba Active Directory domain controller. Includes Linux and Windows test clients for end-to-end auth testing, plus constrained delegation (S4U2Proxy) support.

## Architecture

```
┌──────────────────────────────────────────────────┐
│              KDC  (samba-ad-dc)                   │
│  Samba AD DC · Kerberos KDC · Internal DNS        │
│  Serves keytabs + krb5.conf + jaas.conf via Nginx │
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
- An **external Hyper-V virtual switch** (bridged) -- Vagrant will prompt you to select one
- Admin shell for `vagrant up` (Hyper-V requires elevation)

## Quick Start

From an **elevated PowerShell** prompt (Hyper-V requires admin):

```powershell
# Bring up all VMs in dependency order (KDC -> Oracle -> Test -> Win-test)
lab up

# Or start a single VM
lab up oracle

# Check status of all VMs
lab status

# Gracefully shut down all VMs (preserves state)
lab stop

# Resume halted VMs (KDC first, refreshes .kdc_ip, then dependents)
lab start

# Tear down everything
lab down
```

You can also manage individual VMs directly:

```powershell
cd kdc
vagrant up          # start
vagrant ssh         # connect
vagrant destroy -f  # tear down
```

**Note:** After the Windows client's first boot, run `vagrant reload` from `win-test/` to complete the domain join reboot.

## Lab Lifecycle Manager (`lab`)

All lifecycle operations go through the unified `lab.ps1` script (or `lab.bat` wrapper):

| Action | Description |
|--------|-------------|
| `lab up [vm]` | Create and provision VMs from scratch |
| `lab down [vm]` | Destroy VMs permanently |
| `lab stop [vm]` | Gracefully shut down VMs (preserves state) |
| `lab start [vm]` | Resume halted VMs and re-provision |
| `lab provision [vm]` | Re-provision running VMs (push config changes without restart) |
| `lab status` | Show the state of all VMs |
| `lab rebuild-kdc` | Destroy and rebuild the KDC, re-provision running dependents |

**Boot order:** `kdc -> oracle -> test -> win-test` (reverse for stop/down)

The KDC must always start first. It provides DNS, Kerberos, and keytab services that all other VMs depend on. On Hyper-V, VMs get dynamic IPs; the KDC IP is saved to `.kdc_ip` and read by other VMs at Vagrantfile parse time.

### When to use `provision` vs `rebuild-kdc`

- **`lab provision`** -- Use after editing provisioning scripts (setup-users.sh, setup-samba.sh, etc.). Re-runs all provisioners on running VMs. Fast, non-destructive. Good for pushing config changes like updated krb5.conf, new keytabs, or JAAS config.
- **`lab rebuild-kdc`** -- Use when the KDC is in a broken state and needs a clean slate. Destroys the KDC VM, recreates it, and re-provisions all running dependents. Linux VMs recover automatically; the Windows client needs manual domain re-join steps (printed by the script).

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
| Constrained delegation service | `webappuser` / `StrongPassword123!` |
| Windows test user | `winuser` / `StrongPassword123!` |
| Oracle SYS password | `Str0ngPassw0rd!` |
| Oracle test user | `testuser` / `testpassword` |

### Service Principal Names (SPNs)

| SPN | Account | Purpose |
|-----|---------|---------|
| `oracle/oracle.corp.internal` | oracleuser | Oracle listener Kerberos auth |
| `HTTP/webapp.corp.internal` | webappuser | Constrained delegation service |

### Constrained Delegation

`webappuser` is configured for S4U2Self (protocol transition) + S4U2Proxy, allowing it to impersonate any AD user and obtain a service ticket to `oracle/oracle.corp.internal` on their behalf. This enables scenarios where a web application authenticates a user and connects to Oracle as that user without needing their password.

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
The KDC writes its IP to `.kdc_ip` after boot (via a Vagrant `after :up` trigger). All other VMs read this file at `vagrant up` time and pass it to their provisioning scripts. The `lab start` action starts the KDC first, waits for `.kdc_ip` to refresh, then starts dependents.

### Artifact Distribution
The KDC exports keytabs, `krb5.conf`, and `jaas.conf` to `/var/www/html/artifacts/` and serves them via Nginx. Other VMs download these over HTTP during provisioning.

Available artifacts:
- `krb5.conf` -- Kerberos client config (forces TCP via `udp_preference_limit = 1`)
- `oracle.keytab` -- Oracle listener service principal
- `oracleuser.keytab` -- Oracle DB user keytab
- `dnsupdater.keytab` -- DNS registration service keytab
- `winuser.keytab` -- Windows domain user keytab
- `webappuser.keytab` -- Constrained delegation service keytab
- `jaas.conf` -- JAAS login configurations for Java/JDBC testing

### Dynamic DNS
The Oracle VM authenticates to the KDC with a dedicated `dnsupdater` keytab, removes stale A records, and registers its current IP in Samba DNS.

### Time Sync
All Linux VMs run `chrony`. The KDC syncs with `pool.ntp.org` and acts as a local NTP server. Other VMs sync to the KDC to prevent Kerberos clock-skew failures.

### Host File Management
Vagrant triggers automatically update the Windows host machine's `hosts` file so you can reach VMs by name (e.g., `oracle.corp.internal`). Entries are cleaned up on `vagrant destroy`.

## Testing

### Linux Test Client

SSH into the test client and run the end-to-end auth test:

```bash
vagrant ssh  # from test/

# Install Oracle Instant Client (first time only)
./install-oracle.sh

# Run end-to-end Kerberos auth test
./test_auth.sh

# Or test keytab-based auth
./kinit-keytab.sh
```

### Constrained Delegation (from host)

The `test/ConstrainedDelegationTest.java` demonstrates S4U2Self + S4U2Proxy. It authenticates as `webappuser` via keytab, impersonates `winuser`, and connects to Oracle as that user. Requires the DataDirect Oracle JDBC driver on the classpath.

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
- "Empty nameStrings" from DataDirect JDBC: usually `KRB_ERR_RESPONSE_TOO_BIG` (error 52) -- ensure `udp_preference_limit = 1` is in krb5.conf

### Oracle container not starting
- Check status: `docker ps -a`
- View logs: `docker logs -f oracle`
- Verify sqlnet.ora placement: `docker exec oracle cat $ORACLE_HOME/network/admin/sqlnet.ora`

### Windows domain join fails
- Verify DNS: `Resolve-DnsName samba-ad-dc.corp.internal`
- Ping KDC: `Test-Connection <KDC_IP>`
- Check network profile is Private (not Public)
- Review Event Viewer > Windows Logs > System

### sqlnet.ora missing after install-oracle.sh
- `install-oracle.sh` replaces the `/opt/oracle/instantclient` symlink, which can destroy the sqlnet.ora deployed by provisioning
- Fix: re-run `./install-oracle.sh` (it now restores sqlnet.ora) or `lab provision test`

## Project Structure

```
vagrant-lab/
├── README.md                    # This file
├── lab.ps1                      # Unified lifecycle manager (up/down/stop/start/provision/status/rebuild-kdc)
├── lab.bat                      # Thin wrapper for lab.ps1
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
│   ├── setup-users.sh           # AD users, SPNs, delegation, encryption, keytab export
│   ├── jaas.conf                # JAAS login configurations (deployed to artifacts)
│   └── dashboard-kdc.sh         # KDC status dashboard CGI script
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
│   └── dashboard-oracle.sh      # Oracle status dashboard CGI script
├── test/
│   ├── Vagrantfile
│   ├── provision.sh             # Orchestrator: packages, NTP, DNS, helpers
│   ├── install-oracle.sh        # Oracle Instant Client installer
│   ├── kinit-keytab.sh          # Kerberos TGT helper (keytab-based)
│   ├── test_auth.sh             # End-to-end Kerberos + Oracle auth test
│   ├── ConstrainedDelegationTest.java  # S4U2Self + S4U2Proxy Java test
│   ├── connect.isql             # Password-based Oracle connection script
│   ├── connect-kerb.isql        # Kerberos-based Oracle connection script
│   ├── sqlnet-client.ora        # SQL*Net client Kerberos config
│   └── dashboard-test.sh        # Test client status dashboard CGI script
└── win-test/
    ├── Vagrantfile
    ├── provision.ps1             # Orchestrator: DNS, connectivity, delegates
    ├── setup-domain-join.ps1     # AD domain join with DNS wait loop
    ├── setup-rdp.ps1             # Enable RDP + firewall + user access
    ├── setup-dashboard.ps1       # NSSM service install for dashboard
    └── dashboard-win.ps1         # PowerShell HTTP listener dashboard
```
