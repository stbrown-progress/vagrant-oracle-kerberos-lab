# win-test/setup-dashboard.ps1 - Install PowerShell dashboard as a Windows service
#
# Uses NSSM (Non-Sucking Service Manager) to run dashboard-win.ps1 as a service.
# Downloads NSSM if not present, installs the service, opens firewall port 80.
# Idempotent: safe to run multiple times.

param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

$dashboardDir = "C:\vagrant-dashboard"
$nssmDir = "C:\nssm"
$nssmExe = "$nssmDir\nssm.exe"
$serviceName = "VagrantDashboard"

# ── Create dashboard directory and copy script ────────────────────
Write-Host "Setting up dashboard directory..."
New-Item -ItemType Directory -Force -Path $dashboardDir | Out-Null
Copy-Item -Path "C:\tmp\dashboard-win.ps1" -Destination "$dashboardDir\dashboard-win.ps1" -Force

# ── Download NSSM if not present ─────────────────────────────────
if (-not (Test-Path $nssmExe)) {
    Write-Host "Downloading NSSM..."
    New-Item -ItemType Directory -Force -Path $nssmDir | Out-Null

    $nssmUrl = "https://nssm.cc/release/nssm-2.24.zip"
    $nssmZip = "$env:TEMP\nssm.zip"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $nssmUrl -OutFile $nssmZip -UseBasicParsing

    # Extract just the 64-bit exe
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($nssmZip)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -like "*/win64/nssm.exe" } | Select-Object -First 1
        if ($entry) {
            $stream = $entry.Open()
            $fileStream = [System.IO.File]::Create($nssmExe)
            try {
                $stream.CopyTo($fileStream)
            } finally {
                $fileStream.Close()
                $stream.Close()
            }
            Write-Host "Extracted NSSM to $nssmExe"
        } else {
            Write-Error "Could not find win64/nssm.exe in downloaded archive."
        }
    } finally {
        $zip.Dispose()
    }
    Remove-Item $nssmZip -Force -ErrorAction SilentlyContinue
}

# ── Install/update the Windows service ───────────────────────────
$existingService = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existingService) {
    Write-Host "Service '$serviceName' already exists. Restarting..."
    & $nssmExe restart $serviceName 2>&1 | Out-Null
} else {
    Write-Host "Installing '$serviceName' service..."
    & $nssmExe install $serviceName powershell.exe "-ExecutionPolicy Bypass -File $dashboardDir\dashboard-win.ps1"
    & $nssmExe set $serviceName AppDirectory $dashboardDir
    & $nssmExe set $serviceName DisplayName "Vagrant Lab Dashboard"
    & $nssmExe set $serviceName Description "PowerShell HTTP dashboard for Vagrant lab status"
    & $nssmExe set $serviceName Start SERVICE_AUTO_START
    # Redirect stdout/stderr to log files for debugging
    & $nssmExe set $serviceName AppStdout "$dashboardDir\dashboard-stdout.log"
    & $nssmExe set $serviceName AppStderr "$dashboardDir\dashboard-stderr.log"
    & $nssmExe start $serviceName
    Write-Host "Service '$serviceName' installed and started."
}

# ── Open firewall port 80 ────────────────────────────────────────
$rule = Get-NetFirewallRule -DisplayName "Vagrant Dashboard HTTP" -ErrorAction SilentlyContinue
if (-not $rule) {
    Write-Host "Opening firewall port 80 for dashboard..."
    New-NetFirewallRule -DisplayName "Vagrant Dashboard HTTP" `
        -Direction Inbound -Protocol TCP -LocalPort 80 -Action Allow | Out-Null
} else {
    Write-Host "Firewall rule for port 80 already exists."
}

# Verify
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
Write-Host "Dashboard service status: $($svc.Status)"
Write-Host "Dashboard URL: http://localhost/dashboard"
