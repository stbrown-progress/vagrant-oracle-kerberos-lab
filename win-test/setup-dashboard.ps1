# win-test/setup-dashboard.ps1 - Install PowerShell dashboard as a scheduled task
#
# Registers dashboard-win.ps1 as a scheduled task that runs at startup under SYSTEM.
# Opens firewall port 80 for HTTP access.
# Idempotent: safe to run multiple times.

param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

$dashboardDir = "C:\vagrant-dashboard"
$scriptPath = "$dashboardDir\dashboard-win.ps1"
$taskName = "VagrantDashboard"

# -- Create dashboard directory and copy script ----------------------
Write-Host "Setting up dashboard directory..."
New-Item -ItemType Directory -Force -Path $dashboardDir | Out-Null
Copy-Item -Path "C:\tmp\dashboard-win.ps1" -Destination $scriptPath -Force

# -- Register scheduled task -----------------------------------------
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Task '$taskName' already exists. Stopping and re-registering..."
    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}

Write-Host "Registering '$taskName' scheduled task..."
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
    -WorkingDirectory $dashboardDir

$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 1) `
    -ExecutionTimeLimit (New-TimeSpan -Days 365)

Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description "PowerShell HTTP dashboard for Vagrant lab status" | Out-Null

# Start it now
Start-ScheduledTask -TaskName $taskName
Start-Sleep -Seconds 2
Write-Host "Task '$taskName' registered and started."

# -- Open firewall port 80 -------------------------------------------
$rule = Get-NetFirewallRule -DisplayName "Vagrant Dashboard HTTP" -ErrorAction SilentlyContinue
if (-not $rule) {
    Write-Host "Opening firewall port 80 for dashboard..."
    New-NetFirewallRule -DisplayName "Vagrant Dashboard HTTP" `
        -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
} else {
    Write-Host "Firewall rule for port 80 already exists."
}

# -- Verify -----------------------------------------------------------
$task = Get-ScheduledTask -TaskName $taskName
Write-Host "Dashboard task state: $($task.State)"
Write-Host "Dashboard URL: http://localhost/dashboard"
