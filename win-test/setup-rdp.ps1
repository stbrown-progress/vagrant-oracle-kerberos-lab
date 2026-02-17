# win-test/setup-rdp.ps1 - Enable Remote Desktop access
#
# Enables RDP, opens the firewall, and grants the domain user 'winuser'
# access to log in via Remote Desktop.
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

# Ensure the Remote Desktop Users group exists and add winuser
# This only works after domain join + reboot, so we try gracefully.
$sysInfo = Get-CimInstance Win32_ComputerSystem
if ($sysInfo.PartOfDomain) {
    try {
        Add-LocalGroupMember -Group "Remote Desktop Users" -Member "CORP\winuser" -ErrorAction Stop
        Write-Host "Added CORP\winuser to Remote Desktop Users group."
    }
    catch {
        if ($_.Exception.Message -match "already a member") {
            Write-Host "CORP\winuser is already in Remote Desktop Users."
        } else {
            Write-Warning "Could not add CORP\winuser to RDP group: $_"
            Write-Warning "This is expected before domain join reboot. Re-run provisioning after 'vagrant reload'."
        }
    }
} else {
    Write-Host "Not yet domain-joined -- skipping winuser RDP group membership (will be set after reload)."
}

# Verify RDP service is running
$rdpService = Get-Service TermService
Write-Host "RDP Service: $($rdpService.Status)"
