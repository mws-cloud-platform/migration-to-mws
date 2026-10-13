# =======================================================================
# FILE: 7-Sysprep.ps1
# VERSION: 4.1
# =======================================================================
# Runs Sysprep to generalize the system for golden image creation.
#
# This is IRREVERSIBLE: system will enter OOBE and shut down.
# After Sysprep, export the disk as a template in MWS.
#
# Run ONLY after 6-CloudBase-Init.ps1.
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
$Global:LogPath = Join-Path $Global:LogDir ("7-Sysprep_v{0}_{1}_{2}.log" -f $SCRIPT_VERSION, $Global:Timestamp, $Global:Hostname)

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

# =======================================================================
# MAIN
# =======================================================================

Write-Log "=== 7-Sysprep.ps1 v$SCRIPT_VERSION ==="
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

$cbSvc = Get-Service -Name "cloudbase-init" -ErrorAction SilentlyContinue
if (-not $cbSvc) {
    Write-Log "ERROR: CloudBase-Init service not found" -Level Error
    Write-Log "Run 6-CloudBase-Init.ps1 first." -Level Error
    Read-Host "Press Enter to exit"
    return
}
Write-Log "CloudBase-Init: $($cbSvc.Status) / $($cbSvc.StartType)" -Level Success

$vTag = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi" -Name "Tag" -ErrorAction SilentlyContinue).Tag
if ($vTag -ne 64) {
    Write-Log "WARNING: vioscsi Tag is '$vTag', expected 64" -Level Warning
}

# --- STEP 1: WARNING ---
Write-Section "STEP 1. WARNING"

Write-Log ""
Write-Log "==========================================================" -Level Warning
Write-Log " SYSREP IS IRREVERSIBLE" -Level Warning
Write-Log "==========================================================" -Level Warning
Write-Log "" -Level Warning
Write-Log "This script will:" -Level Warning
Write-Log "  - Generalize this Windows installation" -Level Warning
Write-Log "  - Remove all user-specific settings" -Level Warning
Write-Log "  - Reset to Out-of-Box-Experience (OOBE)" -Level Warning
Write-Log "  - Shut down the VM" -Level Warning
Write-Log "" -Level Warning
Write-Log "After Sysprep, the current Administrator password will be" -Level Warning
Write-Log "cleared. On the next boot, CloudBase-Init will read the" -Level Warning
Write-Log "password from MWS metadata (if metadata is configured)." -Level Warning
Write-Log "" -Level Warning
Write-Log "Use this ONLY to create a golden image for mass deployment." -Level Warning
Write-Log "Do NOT use on a working production VM." -Level Warning
Write-Log "" -Level Warning

$confirm = Read-Host "Type YES (uppercase) to proceed with Sysprep"
if ($confirm -ne "YES") {
    Write-Log "Aborted by user. No changes made." -Level Info
    Read-Host "Press Enter to exit"
    return
}
Write-Log "User confirmed." -Level Success

# --- STEP 2: RUN SYSREP ---
Write-Section "STEP 2. RUN SYSREP"

$sysprep = "$env:SystemRoot\System32\Sysprep\Sysprep.exe"
if (-not (Test-Path -LiteralPath $sysprep)) {
    Write-Log "ERROR: sysprep.exe not found at $sysprep" -Level Error
    Read-Host "Press Enter to exit"
    return
}
Write-Log "sysprep.exe found" -Level Success

$sysprepArgs = "/oobe /generalize /shutdown /quiet"
Write-Log "Running: Sysprep.exe $sysprepArgs" -Level Action
Write-Log "VM will shut down automatically when complete." -Level Info
Write-Log ""

try {
    $p = Start-Process -FilePath $sysprep -ArgumentList $sysprepArgs -Wait -PassThru -NoNewWindow -ErrorAction Stop
    Write-Log "Sysprep exit code: $($p.ExitCode)" -Level Info
} catch {
    Write-Log "Sysprep launch failed: $($_.Exception.Message)" -Level Error
    Read-Host "Press Enter to exit"
    return
}

Write-Log "Sysprep completed. If VM did not shut down, do it manually." -Level Success
Write-Log "Log saved to: $Global:LogPath" -Level Info
Read-Host "Press Enter to close"