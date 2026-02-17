# win-test/setup-rdp.ps1 - Enable Remote Desktop access
#
# Enables RDP, opens the firewall, and grants the domain user 'winuser'
# local admin + Remote Desktop access.
# Idempotent: safe to run multiple times.

$ErrorActionPreference = "Stop"

# Enable Remote Desktop
Write-Host "Enabling Remote Desktop..."
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" `
    -Name "fDenyTSConnections" -Value 0

# Disable Network Level Authentication requirement (simplifies lab access)
Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" `
    -Name "UserAuthentication" -Value 0

# Open firewall for RDP (port 3389)
Write-Host "Configuring firewall for RDP..."
Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

# Add winuser to local groups (requires domain join + reboot to resolve the account)
$sysInfo = Get-CimInstance Win32_ComputerSystem
if ($sysInfo.PartOfDomain) {
    foreach ($group in @("Remote Desktop Users", "Administrators")) {
        try {
            Add-LocalGroupMember -Group $group -Member "CORP\winuser" -ErrorAction Stop
            Write-Host "Added CORP\winuser to $group."
        }
        catch {
            if ($_.Exception.Message -match "already a member") {
                Write-Host "CORP\winuser is already in $group."
            } else {
                Write-Warning "Could not add CORP\winuser to ${group}: $_"
            }
        }
    }
} else {
    Write-Host "Not yet domain-joined -- skipping winuser group membership (will be set after reload)."
}

# Verify RDP service is running
$rdpService = Get-Service TermService
Write-Host "RDP Service: $($rdpService.Status)"
