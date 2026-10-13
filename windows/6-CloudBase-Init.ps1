# =======================================================================
# FILE: 6-CloudBase-Init.ps1
# VERSION: 4.1
# =======================================================================
# Installs CloudBase-Init and deploys configuration files.
#
# Optional: needed if you want MWS to inject the Administrator password
# via metadata on first boot.
#
# Does NOT run Sysprep - use 7-Sysprep.ps1 for that.
# Idempotent: safe to run multiple times.
# Universal PowerShell 5.1 (Windows Server 2019-2025).
# ASCII-only. No here-strings.
# =======================================================================

$SCRIPT_VERSION = "4.1"
$ErrorActionPreference = "Continue"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

$Global:Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$Global:Hostname  = $env:COMPUTERNAME
$Global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($Global:ScriptDir)) {
    try { $Global:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}
if ([string]::IsNullOrEmpty($Global:ScriptDir)) { $Global:ScriptDir = (Get-Location).Path }

$Global:LogDir = Join-Path $Global:ScriptDir "logs"
if (-not (Test-Path -LiteralPath $Global:LogDir)) {
    try { New-Item -Path $Global:LogDir -ItemType Directory -Force | Out-Null }
    catch { $Global:LogDir = $env:USERPROFILE }
}
$Global:ToolsDir = Join-Path $Global:ScriptDir "tools"
$Global:CfgDir   = Join-Path $Global:ScriptDir "configs-cloudbase-init"
$Global:LogPath  = Join-Path $Global:LogDir ("6-CloudBase-Init_v{0}_{1}_{2}.log" -f $SCRIPT_VERSION, $Global:Timestamp, $Global:Hostname)

$CbUrl = "https://github.com/cloudbase/cloudbase-init/releases/download/1.1.6/CloudbaseInitSetup_1_1_6_x64.msi"

# =======================================================================
# LOGGING
# =======================================================================

function Write-Log {
    param([string]$Message, [string]$Level = "Info")
    if ($null -eq $Message) { return }
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$time] [$Level] $Message"
    $line | Out-File -FilePath $Global:LogPath -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    $colorMap = @{ Info="White"; Success="Green"; Warning="Yellow"; Error="Red"; Action="Cyan"; Skip="DarkGray" }
    $col = if ($colorMap.ContainsKey($Level)) { $colorMap[$Level] } else { "White" }
    Write-Host $line -ForegroundColor $col
}

function Write-Section {
    param([string]$Title)
    Write-Log ""
    Write-Log "=========================================================="
    Write-Log "===== [$Title] ====="
    Write-Log "=========================================================="
}

function Test-UrlReachable {
    param([string]$Url)
    try {
        $hostName = ([Uri]$Url).Host
        return [bool](Test-NetConnection -ComputerName $hostName -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch { return $false }
}

# =======================================================================
# MAIN
# =======================================================================

Write-Log "=== 6-CloudBase-Init.ps1 v$SCRIPT_VERSION ==="
Write-Log "Log file: $Global:LogPath"

# --- STEP 0: PREFLIGHT ---
Write-Section "STEP 0. PREFLIGHT"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Log "ERROR: Not running as Administrator" -Level Error
    Read-Host "Press Enter to exit"
    return
}
Write-Log "Admin Rights: OK" -Level Success

# --- STEP 1: GET INSTALLER ---
Write-Section "STEP 1. GET CLOUDBASE-INIT INSTALLER"

$installer      = "$env:TEMP\CloudbaseInitSetup.msi"
$localInstaller = Join-Path $Global:ToolsDir "CloudbaseInitSetup_x64.msi"

if (Test-Path -LiteralPath $localInstaller) {
    Write-Log "Found local installer: $localInstaller" -Level Success
    Copy-Item -Path $localInstaller -Destination $installer -Force
} else {
    Write-Log "Local installer not found in tools\, will download" -Level Info
    if (-not (Test-UrlReachable -Url $CbUrl)) {
        Write-Log "ERROR: Cannot reach $CbUrl" -Level Error
        Write-Log "Place CloudbaseInitSetup_x64.msi in tools\ and re-run." -Level Error
        Read-Host "Press Enter to exit"
        return
    }
    Write-Log "Downloading CloudBase-Init..." -Level Action
    try {
        Invoke-WebRequest -Uri $CbUrl -OutFile $installer -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
        $sz = [math]::Round((Get-Item $installer).Length / 1MB, 1)
        Write-Log "Downloaded: ${sz} MB" -Level Success
    } catch {
        Write-Log "Download failed: $($_.Exception.Message)" -Level Error
        Read-Host "Press Enter to exit"
        return
    }
}

if (-not (Test-Path -LiteralPath $installer)) {
    Write-Log "ERROR: installer not found at $installer" -Level Error
    Read-Host "Press Enter to exit"
    return
}

# --- STEP 2: INSTALL CLOUDBASE-INIT ---
Write-Section "STEP 2. INSTALL CLOUDBASE-INIT"

$alreadyInstalled = $false
try {
    $svc = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
    if ($svc) { $alreadyInstalled = $true }
} catch {}

if ($alreadyInstalled) {
    Write-Log "CloudBase-Init service already exists. Reinstalling..." -Level Info
} else {
    Write-Log "Installing CloudBase-Init..." -Level Action
}

try {
    $p = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i `"$installer`" /qn /norestart" `
        -Wait -PassThru -NoNewWindow -ErrorAction Stop
    Write-Log "MSI exit code: $($p.ExitCode)" -Level Success
} catch {
    Write-Log "Install failed: $($_.Exception.Message)" -Level Error
    Read-Host "Press Enter to exit"
    return
}

Start-Sleep -Seconds 3

$svc = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-Log "ERROR: CloudBase-Init service not found after install" -Level Error
    Read-Host "Press Enter to exit"
    return
}
Write-Log "Service installed: $($svc.Status) / $($svc.StartType)" -Level Success

# --- STEP 3: DEPLOY CONFIG FILES ---
Write-Section "STEP 3. DEPLOY CONFIG FILES"

$cbConfDir = Join-Path $env:ProgramFiles "Cloudbase Solutions\Cloudbase-Init\conf"
if (-not (Test-Path -LiteralPath $cbConfDir)) {
    Write-Log "ERROR: CloudBase-Init conf directory not found at $cbConfDir" -Level Error
    Read-Host "Press Enter to exit"
    return
}
Write-Log "Target conf directory: $cbConfDir" -Level Info

$configsToDeploy = @(
    "cloudbase-init.conf",
    "cloudbase-init-unattend.conf"
)

$deployed = 0
foreach ($cfg in $configsToDeploy) {
    $src = Join-Path $Global:CfgDir $cfg
    $dst = Join-Path $cbConfDir   $cfg
    if (Test-Path -LiteralPath $src) {
        Copy-Item -Path $src -Destination $dst -Force
        Write-Log "Deployed: $cfg" -Level Success
        $deployed++
    } else {
        Write-Log "WARNING: source config not found: $src" -Level Warning
    }
}

if ($deployed -eq 0) {
    Write-Log "No config files were deployed from $Global:CfgDir" -Level Warning
}

# --- STEP 4: ENABLE SERVICE ---
Write-Section "STEP 4. ENABLE SERVICE"

try {
    Set-Service -Name "cloudbase-init" -StartupType Automatic -ErrorAction Stop
    Write-Log "cloudbase-init: StartupType = Automatic" -Level Success
} catch {
    Write-Log "Set StartupType failed: $($_.Exception.Message)" -Level Warning
}

$svc = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -ne "Running") {
    try {
        Start-Service -Name "cloudbase-init" -ErrorAction Stop
        Write-Log "cloudbase-init: started" -Level Success
    } catch {
        Write-Log "Start-Service failed: $($_.Exception.Message)" -Level Warning
        Write-Log "The service will start on next boot." -Level Info
    }
}

# --- STEP 5: SUMMARY ---
Write-Section "STEP 5. SUMMARY"

$svc          = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
$confMain     = Test-Path -LiteralPath (Join-Path $cbConfDir "cloudbase-init.conf")
$confUnattend = Test-Path -LiteralPath (Join-Path $cbConfDir "cloudbase-init-unattend.conf")

Write-Log ""
Write-Log "---- STATUS ----"
Write-Log "  Service status     : $(if ($svc) { $svc.Status } else { 'NOT FOUND' })" -Level Info
Write-Log "  Service start type : $(if ($svc) { $svc.StartType } else { 'n/a' })" -Level Info
Write-Log "  cloudbase-init.conf          : $(if ($confMain)     { 'present' } else { 'MISSING' })" -Level Info
Write-Log "  cloudbase-init-unattend.conf : $(if ($confUnattend) { 'present' } else { 'MISSING' })" -Level Info
Write-Log ""
Write-Log "CloudBase-Init installation complete." -Level Success
Write-Log ""
Write-Log "NEXT STEP:" -Level Info
Write-Log "  Run 7-Sysprep.ps1 to generalize the system before export" -Level Info
Write-Log "  as a golden image. Without Sysprep, CloudBase-Init will"  -Level Info
Write-Log "  not inject a new password on first boot in MWS."          -Level Info
Write-Log ""
Write-Log "Log saved to: $Global:LogPath" -Level Info
Write-Log ""
Read-Host "Press Enter to close"