# win-test/setup-java.ps1 - Install Eclipse Temurin 21 LTS (JDK)
#
# Downloads and silently installs the Temurin 21 JDK MSI.
# Sets JAVA_HOME as a system environment variable and adds it to PATH.
# Idempotent: skips installation if java.exe is already on PATH.

$ErrorActionPreference = "Stop"

# Check if Java is already installed
$javaCmd = Get-Command java -ErrorAction SilentlyContinue
if ($javaCmd) {
    Write-Host "Java already installed: $($javaCmd.Source)"
    & java -version 2>&1 | ForEach-Object { Write-Host $_ }
    return
}

Write-Host "Installing Eclipse Temurin 21 LTS..."

$temurinUrl = "https://api.adoptium.net/v3/installer/latest/21/ga/windows/x64/jdk/hotspot/normal/eclipse"
$msiPath = "$env:TEMP\temurin21.msi"

# Download the MSI installer
Write-Host "Downloading from Adoptium API..."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $temurinUrl -OutFile $msiPath -UseBasicParsing

# Silent install with JAVA_HOME and PATH integration
# ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome
Write-Host "Running MSI installer (silent)..."
$msiArgs = @(
    "/i", $msiPath,
    "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome",
    "/quiet", "/norestart",
    "/log", "$env:TEMP\temurin_install.log"
)
Start-Process msiexec.exe -ArgumentList $msiArgs -Wait -NoNewWindow

# Clean up installer
Remove-Item $msiPath -Force -ErrorAction SilentlyContinue

# Verify installation
# The MSI sets JAVA_HOME and PATH, but current session won't see it yet.
# Refresh PATH from registry for verification.
$machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
$env:Path = "$machinePath;$env:Path"
$javaHome = [System.Environment]::GetEnvironmentVariable("JAVA_HOME", "Machine")

if ($javaHome) {
    Write-Host "JAVA_HOME = $javaHome"
    & "$javaHome\bin\java" -version 2>&1 | ForEach-Object { Write-Host $_ }
} else {
    Write-Warning "JAVA_HOME not set. Check $env:TEMP\temurin_install.log for errors."
}
