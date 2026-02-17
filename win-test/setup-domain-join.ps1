# win-test/setup-domain-join.ps1 - Join the CORP.INTERNAL AD domain
#
# Waits for DNS resolution via the Samba AD DC, then joins the domain.
# Idempotent: skips the join if the machine is already domain-joined.
#
# After a successful join, a reboot is required (vagrant reload).

param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

$domainName = "CORP.INTERNAL"
$adminUser = "Administrator"
$adminPass = "Str0ngPassw0rd!"

$sysInfo = Get-CimInstance Win32_ComputerSystem
if ($sysInfo.PartOfDomain) {
    Write-Host "Already joined to domain: $($sysInfo.Domain)"
    return
}

Write-Host "Joining domain $domainName..."

# Wait for DNS to start resolving via the KDC
# The DNS adapter change can take a moment to take effect.
$resolved = $false
for ($i = 1; $i -le 10; $i++) {
    try {
        $testDNS = Resolve-DnsName -Name "samba-ad-dc.corp.internal" -Type A -ErrorAction Stop
        Write-Host "DNS Resolution OK: $($testDNS.IPAddress)"
        $resolved = $true
        break
    }
    catch {
        Write-Host "DNS not ready yet ($i/10), retrying in 3s..."
        Start-Sleep -Seconds 3
    }
}

if (-not $resolved) {
    Write-Error "Cannot resolve samba-ad-dc.corp.internal after 10 attempts. Domain join will fail."
}

$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("$domainName\$adminUser", $secPass)

Add-Computer -DomainName $domainName -Credential $cred -Force

Write-Warning "!!! DOMAIN JOIN SUCCESSFUL !!!"
Write-Warning "You must run 'vagrant reload' to reboot and apply changes."
