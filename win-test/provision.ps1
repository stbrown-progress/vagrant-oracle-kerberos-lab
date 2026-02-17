# win-test/provision.ps1 - Windows Client Orchestrator
#
# This is the main provisioning script for the Windows 10 test client.
# It handles basic network setup, then delegates to focused sub-scripts:
#   1. setup-domain-join.ps1 - Join the CORP.INTERNAL AD domain
#   2. setup-java.ps1        - Install Eclipse Temurin 21 LTS (JDK)
#   3. setup-rdp.ps1         - Enable Remote Desktop + firewall rule
#   4. setup-dashboard.ps1   - Install PowerShell dashboard as a service
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

# -- 1. Network Configuration ------------------------------------
# Point DNS to the Samba AD DC so we can resolve *.corp.internal.
# Use netsh to force static DNS -- Set-DnsClientServerAddress often
# gets overwritten by DHCP on Hyper-V external switches.
Write-Host "`n=== 1. Configuring DNS ==="

# Disable IPv6 on all adapters to prevent Windows from using the ISP's
# IPv6 DNS servers (via router advertisement) instead of our KDC.
Get-NetAdapter | ForEach-Object {
    Disable-NetAdapterBinding -Name $_.Name -ComponentID ms_tcpip6 -ErrorAction SilentlyContinue
}

# Set DNS via netsh on each adapter (more reliable than PowerShell cmdlet)
Get-NetAdapter | ForEach-Object {
    $adapterName = $_.Name
    Write-Host "  Setting DNS on adapter: $adapterName"
    netsh interface ip set dns name="$adapterName" static $KdcIp primary
    netsh interface ip set dns name="$adapterName" dhcp | Out-Null  # clear DHCP DNS
    netsh interface ip set dns name="$adapterName" static $KdcIp primary
}

# Set the DNS suffix search list so short names resolve under corp.internal
Set-DnsClientGlobalSetting -SuffixSearchList @("corp.internal") -ErrorAction SilentlyContinue
Get-NetAdapter | ForEach-Object {
    Set-DnsClient -InterfaceIndex $_.InterfaceIndex -ConnectionSpecificSuffix "corp.internal" -ErrorAction SilentlyContinue
}

# Prevent Windows from marking the network as "Public" and blocking WinRM
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Flush and restart DNS client to force it to use the new settings
ipconfig /flushdns | Out-Null
Restart-Service Dnscache -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# Verify and log the DNS configuration (show both IPv4 and IPv6 to confirm IPv6 is gone)
Write-Host "`nDNS configuration after update:"
Get-DnsClientServerAddress | Where-Object { $_.ServerAddresses.Count -gt 0 } |
    Format-Table InterfaceAlias, AddressFamily, ServerAddresses -AutoSize | Out-String | Write-Host

# Verify the Windows DNS client is actually querying the KDC.
# nslookup bypasses the DNS cache and queries the system DNS directly.
# We use cmd /c because nslookup writes to stderr even on success,
# which would trigger $ErrorActionPreference="Stop".
Write-Host "Verifying DNS resolution through the Windows DNS client..."
$maxDnsWait = 30
for ($i = 1; $i -le $maxDnsWait; $i++) {
    $nsResult = cmd /c "nslookup samba-ad-dc.corp.internal 2>&1"
    if ($nsResult -match $KdcIp) {
        Write-Host "DNS client is resolving via KDC (nslookup confirmed)."
        break
    }
    if ($i -eq $maxDnsWait) {
        Write-Warning "DNS client not yet resolving via KDC after 60s. Continuing anyway..."
    } else {
        Write-Host "  DNS client not ready ($i/$maxDnsWait), waiting 2s..."
        Start-Sleep -Seconds 2
    }
}

# -- 2. Connectivity Check ----------------------------------------
Write-Host "`n=== 2. Testing KDC Connectivity ==="
if (-not (Test-Connection -ComputerName $KdcIp -Count 1 -Quiet)) {
    Write-Error "Cannot ping KDC at $KdcIp. Check Hyper-V switches."
}
Write-Host "KDC is reachable at $KdcIp"

# -- 3. Download krb5.ini -----------------------------------------
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

# -- 4. Delegate to Sub-Scripts ------------------------------------
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
