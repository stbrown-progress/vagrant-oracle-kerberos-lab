#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Brings up Vagrant VMs in dependency order.
.DESCRIPTION
    Starts the KDC first, then Oracle, then test clients in parallel.
    Pass a VM name to start just one: .\up.ps1 oracle
.PARAMETER Name
    Optional VM name: kdc, oracle, test, win-test
#>
param(
    [ValidateSet("kdc", "oracle", "test", "win-test")]
    [string]$Name
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

function Start-VM {
    param([string]$Dir)
    Write-Host "`n=== Starting $Dir ===" -ForegroundColor Cyan
    Push-Location (Join-Path $Root $Dir)
    try {
        vagrant up --provider=hyperv
        if ($LASTEXITCODE -ne 0) { throw "vagrant up failed for $Dir" }
    }
    finally {
        Pop-Location
    }
}

if ($Name) {
    Start-VM $Name
    return
}

# 1. KDC must come up first (DNS, Kerberos, keytab server)
Start-VM "kdc"

# 2. Oracle depends on KDC for DNS registration and keytabs
Start-VM "oracle"

# 3. Test clients only need the KDC — start them in parallel
Write-Host "`n=== Starting test clients in parallel ===" -ForegroundColor Cyan
$jobs = @()
$jobs += Start-Job -ScriptBlock {
    param($Dir)
    Set-Location $Dir
    vagrant up --provider=hyperv 2>&1
} -ArgumentList (Join-Path $Root "test")

$jobs += Start-Job -ScriptBlock {
    param($Dir)
    Set-Location $Dir
    vagrant up --provider=hyperv 2>&1
} -ArgumentList (Join-Path $Root "win-test")

$jobs | ForEach-Object {
    $_ | Receive-Job -Wait -AutoRemoveJob
}

Write-Host "`n=== All VMs started ===" -ForegroundColor Green
