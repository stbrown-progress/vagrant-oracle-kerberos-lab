# PowerShell Provisioning Script
param(
    [string]$KdcIp
)

$ErrorActionPreference = "Stop"

Write-Host "Configuring Windows Client with KDC at $KdcIp..."

# --- 1. Network & DNS ---
# Point DNS to the Samba AD DC so we can resolve oracle.corp.internal
Write-Host "Setting DNS to $KdcIp..."
Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $KdcIp

# Add KDC to hosts file for backup resolution
$hostsPath = "$env:windir\System32\drivers\etc\hosts"
if (-not (Select-String -Path $hostsPath -Pattern "samba-ad-dc.corp.internal")) {
    Add-Content -Path $hostsPath -Value "$KdcIp samba-ad-dc.corp.internal samba-ad-dc"
    Write-Host "Added KDC to hosts file."
}

# --- 2. Kerberos Configuration ---
# Even for domain-joined machines, having the config helps Oracle resolve realms correctly.
$krbUrl = "http://$KdcIp/artifacts/krb5.conf"
$destPath = "$env:SystemDrive\krb5.ini" 

Write-Host "Downloading krb5.conf from $krbUrl..."
try {
    # Save directly to C:\krb5.ini so it is accessible to all users (including SYSTEM services)
    Invoke-WebRequest -Uri $krbUrl -OutFile $destPath
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
    $secPass = ConvertTo-SecureString $adminPass -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential("$domainName\$adminUser", $secPass)
    
    # We do NOT use -Restart here because it breaks the Vagrant provisioning flow.
    # We will instruct the user to reload instead.
    Add-Computer -DomainName $domainName -Credential $cred -Force
    
    Write-Warning "######################################################"
    Write-Warning " DOMAIN JOIN SUCCESSFUL - REBOOT REQUIRED"
    Write-Warning " Please run 'vagrant reload' to apply changes."
    Write-Warning "######################################################"
}

# --- 4. Prepare Oracle Configuration ---
$oracleBase = "C:\oracle"
$icName = "instantclient_19_24"
$icPath = "$oracleBase\$icName"

New-Item -ItemType Directory -Force -Path "$icPath\network\admin" | Out-Null

# Generate sqlnet.ora
# Key Change: MSLSA cache allows Oracle to use the Windows Logon TGT
$sqlnetContent = @"
# Client-side SQLNET.ORA for Domain Joined Windows
NAMES.DIRECTORY_PATH= (TNSNAMES, EZCONNECT, HOSTNAME)
SQLNET.AUTHENTICATION_SERVICES = (KERBEROS5)
SQLNET.KERBEROS5_CONF = $destPath
SQLNET.KERBEROS5_CONF_MIT = TRUE
# Critical for domain joined usage: Use the Microsoft Logon Session Cache
SQLNET.KERBEROS5_CC_NAME = MSLSA:
"@
Set-Content -Path "$icPath\network\admin\sqlnet.ora" -Value $sqlnetContent

# --- 5. Create Test Script ---
$testScriptPath = "C:\Users\Public\Desktop\test_auth.ps1"

$testScript = @"
Write-Host "--- Testing Oracle Kerberos (Domain Joined) ---"

# 1. Set Environment Variables
`$Env:PATH = "$icPath;`$Env:PATH"

# 2. Check Auth Status
Write-Host "Checking Current User..."
whoami
Write-Host "Checking Kerberos Tickets (klist)..."
klist

# 3. Connect
Write-Host "Connecting to Oracle..."
# Note: We rely on the OS user ticket, so we just use /
sqlplus /@oracle.corp.internal:1521/XEPDB1

"@

New-Item -ItemType Directory -Force -Path "C:\Users\Public\Desktop" | Out-Null
Set-Content -Path $testScriptPath -Value $testScript

Write-Host "Provisioning Complete."
Write-Host "1. Unzip Oracle Instant Client to $icPath"
Write-Host "2. If you just joined the domain, run 'vagrant reload'"
Write-Host "3. Log in as CORP\oracleuser (Password: StrongPassword123!)"
