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
# We must set DNS via WMI/netsh to make it truly static -- PowerShell's
# Set-DnsClientServerAddress can get overwritten by DHCP on Hyper-V.
Write-Host "`n=== 1. Configuring DNS ==="

# Set DNS on each adapter via WMI (survives DHCP renewal)
Get-NetAdapter | ForEach-Object {
    $adapterName = $_.Name
    $idx = $_.InterfaceIndex
    Write-Host "  Setting DNS on adapter: $adapterName (index $idx)"
    Set-DnsClientServerAddress -InterfaceIndex $idx -ServerAddresses $KdcIp
    # Also set the DNS suffix search list so short names resolve under corp.internal
    Set-DnsClient -InterfaceIndex $idx -ConnectionSpecificSuffix "corp.internal" -ErrorAction SilentlyContinue
}

# Set the global DNS suffix search list so "ping samba-ad-dc" resolves as .corp.internal
Set-DnsClientGlobalSetting -SuffixSearchList @("corp.internal") -ErrorAction SilentlyContinue

# Prevent Windows from marking the network as "Public" and blocking WinRM
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Clear DNS cache to pick up fresh records from the AD DC
Clear-DnsClientCache

# Verify and log the DNS configuration
Write-Host "`nDNS configuration after update:"
Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses.Count -gt 0 } |
    Format-Table InterfaceAlias, ServerAddresses -AutoSize | Out-String | Write-Host

# Wait for Windows to actually start using the new DNS server.
Write-Host "Waiting for DNS server change to take effect..."
for ($i = 1; $i -le 20; $i++) {
    try {
        $null = Resolve-DnsName -Name "samba-ad-dc.corp.internal" -Type A -DnsOnly -ErrorAction Stop
        Write-Host "DNS via KDC is working (resolved samba-ad-dc.corp.internal)."
        break
    }
    catch {
        if ($i -eq 20) {
            Write-Warning "DNS not responding after 40s. Check KDC is running."
        } else {
            Start-Sleep -Seconds 2
        }
    }
}

# -- 2. Connectivity Check ----------------------------------------
Write-Host "`n=== 2. Testing KDC Connectivity ==="
if (-not (Test-Connection -ComputerName $KdcIp -Count 1 -Quiet)) {
    Write-Error "Cannot ping KDC at $KdcIp. Check Hyper-V switches."
}
Write-Host "KDC is reachable at $KdcIp"

# -- 3. Download krb5.ini ----------------------------------------─
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

# -- 4. Delegate to Sub-Scripts ----------------------------------─
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
