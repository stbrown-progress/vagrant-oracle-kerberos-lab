#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Destroys Vagrant VMs in reverse dependency order.
.DESCRIPTION
    Tears down test clients first, then Oracle, then KDC.
    Pass a VM name to destroy just one: .\down.ps1 oracle
.PARAMETER Name
    Optional VM name: kdc, oracle, test, win-test
#>
param(
    [ValidateSet("kdc", "oracle", "test", "win-test")]
    [string]$Name
)

$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot

function Stop-VM {
    param([string]$Dir)
    Write-Host "`n=== Destroying $Dir ===" -ForegroundColor Yellow
    Push-Location (Join-Path $Root $Dir)
    try {
        vagrant destroy -f
    }
    finally {
        Pop-Location
    }
}

if ($Name) {
    Stop-VM $Name
    return
}

# Reverse dependency order: clients first, then Oracle, then KDC
Stop-VM "win-test"
Stop-VM "test"
Stop-VM "oracle"
Stop-VM "kdc"

Write-Host "`n=== All VMs destroyed ===" -ForegroundColor Green
