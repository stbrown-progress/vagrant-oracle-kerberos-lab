# win-test/provision.ps1 - Windows Client Orchestrator
#
# This is the main provisioning script for the Windows 10 test client.
# It handles basic network setup, then delegates to focused sub-scripts:
#   1. setup-domain-join.ps1 — Join the CORP.INTERNAL AD domain
#   2. setup-java.ps1        — Install Eclipse Temurin 21 LTS (JDK)
#   3. setup-rdp.ps1         — Enable Remote Desktop + firewall rule
#   4. setup-dashboard.ps1   — Install PowerShell dashboard as a service
#
# Usage: provision.ps1 -KdcIp <ip-address>
# Called by Vagrant with the KDC IP from ../.kdc_ip

param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

Write-Host "=============================================="
Write-Host "  Windows Client Provisioning"
Write-Host "=============================================="
Write-Host "Target KDC IP: $KdcIp"

# ── 1. Network Configuration ─────────────────────────────────────
# Point DNS to the Samba AD DC so we can resolve *.corp.internal
Write-Host "`n=== 1. Configuring DNS ==="
Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $KdcIp

# Prevent Windows from marking the network as "Public" and blocking WinRM
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Clear DNS cache to pick up fresh records from the AD DC
Clear-DnsClientCache

# ── 2. Connectivity Check ────────────────────────────────────────
Write-Host "`n=== 2. Testing KDC Connectivity ==="
if (-not (Test-Connection -ComputerName $KdcIp -Count 1 -Quiet)) {
    Write-Error "Cannot ping KDC at $KdcIp. Check Hyper-V switches."
}
Write-Host "KDC is reachable at $KdcIp"

# ── 3. Download krb5.ini ─────────────────────────────────────────
# Windows Kerberos reads C:\krb5.ini for realm/KDC configuration
Write-Host "`n=== 3. Downloading Kerberos Configuration ==="
$krbUrl = "http://$KdcIp/artifacts/krb5.conf"
$destPath = "$env:SystemDrive\krb5.ini"
try {
    Invoke-WebRequest -Uri $krbUrl -OutFile $destPath -UseBasicParsing
    Write-Host "Downloaded krb5.ini to $destPath"
}
catch {
    Write-Warning "Failed to download krb5.conf from $krbUrl. Ensure KDC is up."
}

# ── 4. Delegate to Sub-Scripts ───────────────────────────────────
# Sub-scripts are uploaded by Vagrant's file provisioner to C:\tmp\

Write-Host "`n=== 4. Domain Join ==="
& C:\tmp\setup-domain-join.ps1 -KdcIp $KdcIp

Write-Host "`n=== 5. Java Installation ==="
& C:\tmp\setup-java.ps1

Write-Host "`n=== 6. Remote Desktop ==="
& C:\tmp\setup-rdp.ps1

Write-Host "`n=== 7. Dashboard Service ==="
& C:\tmp\setup-dashboard.ps1 -KdcIp $KdcIp

Write-Host "`n=============================================="
Write-Host "  Provisioning Complete"
Write-Host "=============================================="
