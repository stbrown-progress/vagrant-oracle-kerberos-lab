#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Destroys and rebuilds the KDC, then re-provisions dependent VMs.
.DESCRIPTION
    Use this when you need a fresh KDC (new AD database, new keytabs) without
    losing your Oracle, test, or Windows client VMs.

    Steps:
      1. Destroy the KDC VM
      2. Rebuild the KDC (new IP, fresh AD domain, new keytabs)
      3. Re-provision all running VMs so they pick up the new KDC IP,
         download fresh keytabs, and reconfigure DNS/NTP

    For the Windows client, the domain trust will be broken by the KDC rebuild.
    This script re-provisions it to detect and remove the stale domain join.
    After the script completes, you'll need to:
      1. vagrant reload  (from win-test/)  - reboot after domain removal
      2. vagrant provision (from win-test/) - re-join the new domain
      3. vagrant reload  (from win-test/)  - reboot after re-join
#>

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

function Invoke-InDir {
    param([string]$Dir, [string]$Command)
    Push-Location (Join-Path $Root $Dir)
    try {
        Invoke-Expression $Command
        if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
            Write-Warning "$Command failed in $Dir (exit code $LASTEXITCODE)"
        }
    }
    finally {
        Pop-Location
    }
}

# -- Step 1: Destroy the KDC --------------------------------------
Write-Host "`n=== Step 1: Destroying KDC ===" -ForegroundColor Yellow
Invoke-InDir "kdc" "vagrant destroy -f"

# -- Step 2: Rebuild the KDC --------------------------------------
Write-Host "`n=== Step 2: Rebuilding KDC ===" -ForegroundColor Cyan
Invoke-InDir "kdc" "vagrant up --provider=hyperv"

Write-Host "`nNew KDC IP: $(Get-Content (Join-Path $Root '.kdc_ip'))" -ForegroundColor Green

# -- Step 3: Re-provision running VMs ----------------------------─
# vagrant provision only works on running VMs; halted ones are skipped.
$dependentVMs = @("oracle", "test", "win-test")

foreach ($vm in $dependentVMs) {
    $vmDir = Join-Path $Root $vm
    Push-Location $vmDir
    try {
        $status = vagrant status --machine-readable 2>&1 | Out-String
        if ($status -match "state,running") {
            Write-Host "`n=== Re-provisioning $vm ===" -ForegroundColor Cyan
            vagrant provision
        } else {
            Write-Host "`n=== Skipping $vm (not running) ===" -ForegroundColor DarkGray
        }
    }
    finally {
        Pop-Location
    }
}

# -- Summary ------------------------------------------------------
Write-Host "`n=============================================="  -ForegroundColor Green
Write-Host "  KDC Rebuild Complete"                            -ForegroundColor Green
Write-Host "=============================================="  -ForegroundColor Green
Write-Host ""
Write-Host "Linux VMs (oracle, test) should be fully functional now."
Write-Host ""
Write-Host "Windows client needs manual steps to complete domain re-join:"
Write-Host "  cd win-test"
Write-Host "  vagrant reload            # reboot after domain removal"
Write-Host "  vagrant provision         # re-join new domain"
Write-Host "  vagrant reload            # reboot to apply domain join"
Write-Host ""
