#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Vagrant lab lifecycle manager.
.DESCRIPTION
    Unified script for managing the multi-VM Vagrant lab.
    Run without arguments for usage information.
.PARAMETER Action
    The lifecycle action: up, down, stop, start, status, rebuild-kdc
.PARAMETER Name
    Optional VM name: kdc, oracle, test, win-test
#>
param(
    [string]$Action,
    [string]$Name
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

# --- VM definitions (dependency order) ---
$VMs         = @("kdc", "oracle", "test", "win-test")
$VMsReversed = @("win-test", "test", "oracle", "kdc")
$ValidVMs    = @("kdc", "oracle", "test", "win-test")
$ValidActions = @("up", "down", "stop", "start", "status", "rebuild-kdc")

# ---------------------------------------------------------
# Help
# ---------------------------------------------------------

function Show-Help {
    Write-Host ""
    Write-Host "  Vagrant Lab Manager" -ForegroundColor Cyan
    Write-Host "  ===================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  USAGE:  lab <action> [machine]" -ForegroundColor White
    Write-Host ""
    Write-Host "  ACTIONS:" -ForegroundColor Yellow
    Write-Host "    up              Create and provision VMs from scratch"
    Write-Host "    down            Destroy VMs permanently"
    Write-Host "    stop            Gracefully shut down VMs"
    Write-Host "    start           Resume halted VMs and re-provision"
    Write-Host "    status          Show the state of all VMs"
    Write-Host "    rebuild-kdc     Destroy and rebuild the KDC, re-provision running dependents"
    Write-Host ""
    Write-Host "  MACHINES:" -ForegroundColor Yellow
    Write-Host "    kdc             Samba AD Domain Controller [DNS, Kerberos, keytab server]"
    Write-Host "    oracle          Oracle 23c Free database [Docker, Kerberos auth]"
    Write-Host "    test            Linux test client [Oracle Instant Client, kinit]"
    Write-Host "    win-test        Windows 10 domain-joined client"
    Write-Host ""
    Write-Host "  EXAMPLES:" -ForegroundColor Yellow
    Write-Host "    lab up                  Bring up the entire lab"
    Write-Host "    lab up oracle           Create just the Oracle VM"
    Write-Host "    lab stop                Gracefully shut down all VMs"
    Write-Host "    lab stop test           Shut down just the test VM"
    Write-Host "    lab start               Resume all VMs after a stop"
    Write-Host "    lab start oracle        Resume just the Oracle VM"
    Write-Host "    lab down                Destroy all VMs"
    Write-Host "    lab status              Show status of all VMs"
    Write-Host "    lab rebuild-kdc         Rebuild the KDC from scratch"
    Write-Host ""
    Write-Host "  BOOT ORDER:" -ForegroundColor Yellow
    Write-Host "    Start/Up:   kdc -> oracle -> test -> win-test"
    Write-Host "    Stop/Down:  win-test -> test -> oracle -> kdc"
    Write-Host ""
    Write-Host "    The KDC must always start first. It provides DNS, Kerberos, and"
    Write-Host "    keytab services that all other VMs depend on. On Hyper-V, VMs get"
    Write-Host "    dynamic IPs; the KDC IP is saved to .kdc_ip and read by other VMs"
    Write-Host "    at Vagrantfile parse time."
    Write-Host ""
}

# ---------------------------------------------------------
# Helpers
# ---------------------------------------------------------

function Invoke-VagrantInDir {
    param(
        [string]$Dir,
        [string]$Command,
        [string]$Label
    )
    $vmDir = Join-Path $Root $Dir
    if (-not (Test-Path $vmDir)) {
        Write-Warning "Directory not found: $vmDir"
        return
    }
    if ($Label) {
        Write-Host "`n=== $Label ===" -ForegroundColor Cyan
    }
    Push-Location $vmDir
    try {
        Invoke-Expression $Command
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            throw "$Command failed for $Dir (exit code $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}

function Get-VmStatus {
    param([string]$Dir)
    $vmDir = Join-Path $Root $Dir
    if (-not (Test-Path $vmDir)) { return "not found" }
    Push-Location $vmDir
    try {
        $raw = vagrant status --machine-readable 2>&1 | Out-String
        if ($raw -match "state,running")      { return "running" }
        if ($raw -match "state,saved")        { return "saved" }
        if ($raw -match "state,poweroff")     { return "stopped" }
        if ($raw -match "state,off")          { return "stopped" }
        if ($raw -match "state,not_created")  { return "not created" }
        if ($raw -match "state,(\w+)") { return $Matches[1] }
        return "unknown"
    }
    finally {
        Pop-Location
    }
}

# ---------------------------------------------------------
# Actions
# ---------------------------------------------------------

function Invoke-Up {
    param([string]$VM)
    if ($VM) {
        Invoke-VagrantInDir $VM "vagrant up --provider=hyperv" "Creating $VM"
        return
    }
    foreach ($v in $VMs) {
        Invoke-VagrantInDir $v "vagrant up --provider=hyperv" "Creating $v"
    }
    Write-Host "`n=== All VMs created ===" -ForegroundColor Green
}

function Invoke-Down {
    param([string]$VM)
    if ($VM) {
        Invoke-VagrantInDir $VM "vagrant destroy -f" "Destroying $VM"
        return
    }
    foreach ($v in $VMsReversed) {
        Invoke-VagrantInDir $v "vagrant destroy -f" "Destroying $v"
    }
    Write-Host "`n=== All VMs destroyed ===" -ForegroundColor Green
}

function Invoke-Stop {
    param([string]$VM)
    if ($VM) {
        Invoke-VagrantInDir $VM "vagrant halt" "Stopping $VM"
        return
    }
    foreach ($v in $VMsReversed) {
        Invoke-VagrantInDir $v "vagrant halt" "Stopping $v"
    }
    Write-Host "`n=== All VMs stopped ===" -ForegroundColor Green
}

function Invoke-Start {
    param([string]$VM)
    if ($VM) {
        Invoke-VagrantInDir $VM "vagrant up" "Starting $VM"
        return
    }
    # KDC must start first so .kdc_ip is refreshed before other Vagrantfiles parse it
    Invoke-VagrantInDir "kdc" "vagrant up" "Starting kdc"

    $kdcIpFile = Join-Path $Root ".kdc_ip"
    if (Test-Path $kdcIpFile) {
        $ip = (Get-Content $kdcIpFile).Trim()
        Write-Host "  KDC IP: $ip" -ForegroundColor Green
    } else {
        Write-Warning ".kdc_ip not found after starting KDC -- dependent VMs may fail"
    }

    # Start remaining VMs - they read .kdc_ip at Vagrantfile parse time
    foreach ($v in @("oracle", "test", "win-test")) {
        Invoke-VagrantInDir $v "vagrant up" "Starting $v"
    }
    Write-Host "`n=== All VMs started ===" -ForegroundColor Green
}

function Invoke-Status {
    Write-Host ""
    Write-Host "  VM Status" -ForegroundColor Cyan
    Write-Host "  =========" -ForegroundColor Cyan
    Write-Host ""

    $kdcIpFile = Join-Path $Root ".kdc_ip"
    if (Test-Path $kdcIpFile) {
        $ip = (Get-Content $kdcIpFile).Trim()
        Write-Host "  KDC IP [from .kdc_ip]: $ip" -ForegroundColor DarkGray
        Write-Host ""
    }

    foreach ($v in $VMs) {
        $state = Get-VmStatus $v
        $color = switch ($state) {
            "running"     { "Green" }
            "stopped"     { "Yellow" }
            "poweroff"    { "Yellow" }
            "saved"       { "DarkYellow" }
            "not created" { "DarkGray" }
            default       { "Red" }
        }
        $display = $v.PadRight(12)
        Write-Host "  $display $state" -ForegroundColor $color
    }
    Write-Host ""
}

function Invoke-RebuildKdc {
    # Step 1: Destroy the KDC
    Write-Host "`n=== Step 1: Destroying KDC ===" -ForegroundColor Yellow
    Invoke-VagrantInDir "kdc" "vagrant destroy -f"

    # Step 2: Rebuild the KDC
    Write-Host "`n=== Step 2: Rebuilding KDC ===" -ForegroundColor Cyan
    Invoke-VagrantInDir "kdc" "vagrant up --provider=hyperv"

    $kdcIpFile = Join-Path $Root ".kdc_ip"
    if (Test-Path $kdcIpFile) {
        $newIp = (Get-Content $kdcIpFile).Trim()
        Write-Host "`nNew KDC IP: $newIp" -ForegroundColor Green
    }

    # Step 3: Re-provision running dependent VMs
    foreach ($v in @("oracle", "test", "win-test")) {
        $state = Get-VmStatus $v
        if ($state -eq "running") {
            Write-Host "`n=== Re-provisioning $v ===" -ForegroundColor Cyan
            Invoke-VagrantInDir $v "vagrant provision"
        } else {
            Write-Host "`n=== Skipping $v [$state] ===" -ForegroundColor DarkGray
        }
    }

    # Summary
    Write-Host "`n==============================================" -ForegroundColor Green
    Write-Host "  KDC Rebuild Complete"                           -ForegroundColor Green
    Write-Host "==============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "Linux VMs [oracle, test] should be fully functional now."
    Write-Host ""
    Write-Host "Windows client needs manual steps to complete domain re-join:"
    Write-Host "  lab start win-test"
    Write-Host "  Then from win-test/:"
    Write-Host "    vagrant reload           reboot after domain removal"
    Write-Host "    vagrant provision        re-join new domain"
    Write-Host "    vagrant reload           reboot to apply domain join"
    Write-Host ""
}

# ---------------------------------------------------------
# Main
# ---------------------------------------------------------

# Validate action
if (-not $Action -or $Action -notin $ValidActions) {
    if ($Action) {
        Write-Host "`n  Unknown action: '$Action'" -ForegroundColor Red
    }
    Show-Help
    exit 1
}

# Validate machine name
if ($Name -and $Name -notin $ValidVMs) {
    Write-Host "`n  Unknown machine: '$Name'" -ForegroundColor Red
    $validList = $ValidVMs -join ", "
    Write-Host "  Valid machines: $validList" -ForegroundColor Yellow
    exit 1
}

# rebuild-kdc doesn't take a machine name
if ($Action -eq "rebuild-kdc" -and $Name) {
    Write-Host "`n  rebuild-kdc does not accept a machine name" -ForegroundColor Red
    exit 1
}

# Dispatch
switch ($Action) {
    "up"          { Invoke-Up $Name }
    "down"        { Invoke-Down $Name }
    "stop"        { Invoke-Stop $Name }
    "start"       { Invoke-Start $Name }
    "status"      { Invoke-Status }
    "rebuild-kdc" { Invoke-RebuildKdc }
}
