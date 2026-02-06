# PowerShell Provisioning Script
param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

Write-Host "--- Configuring Windows Client ---"
Write-Host "Target KDC IP: $KdcIp"

# Point DNS to the Samba AD DC so we can resolve oracle.corp.internal
Write-Host "Setting DNS to $KdcIp..."
Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $KdcIp

# Prevent Windows from marking the network as "Public" and blocking WinRM
Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private

# Clear DNS cache to ensure we don't hold onto old records
Clear-DnsClientCache

# Connectivity Check
Write-Host "Testing connectivity to KDC..."
if (-not (Test-Connection -ComputerName $KdcIp -Count 1 -Quiet)) {
    Write-Error "Cannot ping KDC at $KdcIp. Check Hyper-V switches."
}

# Kerberos configuration
$krbUrl = "http://$KdcIp/artifacts/krb5.conf"
$destPath = "$env:SystemDrive\krb5.ini" 

try {
    # Save directly to C:\krb5.ini so it is accessible to all users (including SYSTEM services)
    Invoke-WebRequest -Uri $krbUrl -OutFile $destPath -UseBasicParsing
    Write-Host "Downloaded krb5.ini successfully."
}
catch {
    Write-Warning "Failed to download krb5.conf. Ensure KDC is up."
}

# --- 3. Domain Join ---
$domainName = "CORP.INTERNAL"
$adminUser = "Administrator"
$adminPass = "Str0ngPassw0rd!" # Matches the password set in KDC provision.sh

$sysInfo = Get-CimInstance Win32_ComputerSystem
if ($sysInfo.PartOfDomain) {
    Write-Host "Machine is already joined to domain: $($sysInfo.Domain)"
}
else {
    Write-Host "Joining domain $domainName..."

    # Verify DNS resolution first
    try {
        $testDNS = Resolve-DnsName -Name "samba-ad-dc.corp.internal" -Type A -ErrorAction Stop
        Write-Host "DNS Resolution OK: $($testDNS.IPAddress)"
    }
    catch {
        Write-Error "Cannot resolve samba-ad-dc.corp.internal. Domain Join will fail."
    }

    $secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential("$domainName\$adminUser", $secPass)
    
    Add-Computer -DomainName $domainName -Credential $cred -Force
    
    Write-Warning "!!! DOMAIN JOIN SUCCESSFUL !!!"
    Write-Warning "You must run 'vagrant reload' to reboot and apply changes."
}
