# win-test/setup-domain-join.ps1 - Join the CORP.INTERNAL AD domain
#
# Waits for DNS resolution via the Samba AD DC, then joins the domain.
# Handles three scenarios:
#   1. Not domain-joined -> join the domain
#   2. Domain-joined and DC is reachable -> skip (already good)
#   3. Domain-joined but DC was rebuilt -> remove from old domain, re-join
#
# After a successful join, a reboot is required (vagrant reload).

param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

$domainName = "CORP.INTERNAL"
$adminUser = "Administrator"
$adminPass = "Str0ngPassw0rd!"

# -- Check current domain status ----------------------------------
$sysInfo = Get-CimInstance Win32_ComputerSystem
if ($sysInfo.PartOfDomain) {
    Write-Host "Machine reports domain membership: $($sysInfo.Domain)"

    # Verify the DC actually recognizes us (catches rebuilt-KDC scenario)
    $scQuery = nltest /sc_query:CORP.INTERNAL 2>&1 | Out-String
    if ($scQuery -match "NERR_Success") {
        Write-Host "Secure channel to DC is healthy. No action needed."
        return
    }

    # DC was rebuilt -- the old trust relationship is broken.
    # Remove from the (dead) domain so we can re-join the new one.
    Write-Warning "Secure channel verification failed -- DC was likely rebuilt."
    Write-Warning "Removing from stale domain..."
    try {
        # Use local admin creds to leave since domain creds won't work
        Remove-Computer -Force -ErrorAction Stop
        Write-Warning "Removed from old domain. Reboot needed before re-join."
        Write-Warning "Run 'vagrant reload' then 'vagrant provision' to complete."
        return
    }
    catch {
        # If Remove-Computer fails, force it via registry
        Write-Warning "Remove-Computer failed ($_). Forcing via WMI..."
        $compSys = Get-WmiObject Win32_ComputerSystem
        $result = $compSys.UnjoinDomainOrWorkgroup($null, $null, 0)
        if ($result.ReturnValue -eq 0) {
            Write-Warning "Forced domain removal. Run 'vagrant reload' then 'vagrant provision'."
            return
        }
        Write-Error "Could not remove from stale domain. Manual intervention required."
    }
}

# -- Wait for DNS resolution via the new KDC ----------------------
Write-Host "Joining domain $domainName..."

$maxRetries = 30
$resolved = $false
for ($i = 1; $i -le $maxRetries; $i++) {
    try {
        $testDNS = Resolve-DnsName -Name "samba-ad-dc.corp.internal" -Type A -ErrorAction Stop
        Write-Host "DNS Resolution OK: $($testDNS.IPAddress)"
        $resolved = $true
        break
    }
    catch {
        Write-Host "DNS not ready yet ($i/$maxRetries), retrying in 3s..."
        Start-Sleep -Seconds 3
    }
}

if (-not $resolved) {
    Write-Error "Cannot resolve samba-ad-dc.corp.internal after $maxRetries attempts (90s). Domain join will fail."
}

# -- Join the domain ----------------------------------------------
$secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential("$domainName\$adminUser", $secPass)

Add-Computer -DomainName $domainName -Credential $cred -Force

Write-Warning "!!! DOMAIN JOIN SUCCESSFUL !!!"
Write-Warning "You must run 'vagrant reload' to reboot and apply changes."
