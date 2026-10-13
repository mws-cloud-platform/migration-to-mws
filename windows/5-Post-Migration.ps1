# =======================================================================
# FILE: 5-Post-Migration.ps1
# VERSION: 4.1
# =======================================================================
# Post-migration cleanup INSIDE KVM.
#
# Removes:
#   - VMware Tools
#   - phantom VEN_15AD devices
#   - dead VMware services
#
# Does NOT touch:
#   - vioscsi, netkvm, or any VirtIO component
#   - disk layout, BCD, network configuration
#
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
$Global:LogPath = Join-Path $Global:LogDir ("5-Post-Migration_v{0}_{1}_{2}.log" -f $SCRIPT_VERSION, $Global:Timestamp, $Global:Hostname)

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

Write-Log "=== 5-Post-Migration.ps1 v$SCRIPT_VERSION ==="
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

$cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
$manufacturer = if ($cs) { "$($cs.Manufacturer)" } else { "Unknown" }
$model        = if ($cs) { "$($cs.Model)" }        else { "Unknown" }
Write-Log "Environment: $manufacturer / $model" -Level Info

if ($manufacturer -match "VMware") {
    Write-Log "WARNING: running on VMware, not KVM. This script is for KVM target." -Level Warning
    Write-Log "Continuing anyway, but VMware cleanup may not apply." -Level Warning
} elseif ($manufacturer -match "QEMU") {
    Write-Log "Environment check: KVM detected" -Level Success
} else {
    Write-Log "Environment check: unknown hypervisor, proceeding" -Level Info
}

$vioscsiKey = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
if (-not (Test-Path -LiteralPath $vioscsiKey)) {
    Write-Log "ERROR: vioscsi service NOT FOUND. This VM did not come from migration-to-mws." -Level Error
    Read-Host "Press Enter to exit"
    return
}
$vioscsiImg = (Get-ItemProperty -Path $vioscsiKey -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
Write-Log "vioscsi ImagePath: $vioscsiImg" -Level Success

# --- STEP 1: DETECT VMWARE COMPONENTS ---
Write-Section "STEP 1. DETECT VMWARE COMPONENTS"

$vmTools = $null
try {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    $vmTools = Get-ItemProperty -Path $uninstallKeys -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "VMware Tools" } |
        Select-Object -First 1
} catch {}

if ($vmTools) {
    Write-Log "VMware Tools found: $($vmTools.DisplayName) v$($vmTools.DisplayVersion)" -Level Info
    Write-Log "  UninstallString: $($vmTools.UninstallString)" -Level Info
} else {
    Write-Log "VMware Tools: not found in registry" -Level Success
}

$vmServices = @("VMTools", "vmci", "VMUSBArbService", "VGAuthService", "vmvss", "vmware-USBArbitrator")
$vmServicesFound = @()
foreach ($svc in $vmServices) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        $vmServicesFound += $svc
        Write-Log "  Service $svc : Status=$($s.Status) StartType=$($s.StartType)" -Level Info
    }
}
if ($vmServicesFound.Count -eq 0) {
    Write-Log "No VMware services found" -Level Success
} else {
    Write-Log "Found $($vmServicesFound.Count) VMware services" -Level Info
}

$vmDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match "VEN_15AD" -or $_.InstanceId -match "VMWARE" })
if ($vmDevices.Count -gt 0) {
    Write-Log "Found $($vmDevices.Count) VMware devices (all statuses)" -Level Info
} else {
    Write-Log "No VMware devices found" -Level Success
}

# --- STEP 2: STOP AND DISABLE VMWARE SERVICES ---
Write-Section "STEP 2. STOP AND DISABLE VMWARE SERVICES"

foreach ($svc in $vmServicesFound) {
    Write-Log "Processing service: $svc" -Level Action
    try {
        $s = Get-Service -Name $svc -ErrorAction Stop
        if ($s.Status -ne "Stopped") {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Log "  Stopped" -Level Success
        } else {
            Write-Log "  Already stopped" -Level Info
        }
    } catch {
        Write-Log "  Stop failed: $($_.Exception.Message)" -Level Warning
    }
    try {
        Set-Service -Name $svc -StartupType Disabled -ErrorAction Stop
        Write-Log "  Set to Disabled" -Level Success
    } catch {
        Write-Log "  Disable failed: $($_.Exception.Message)" -Level Warning
    }
}
if ($vmServicesFound.Count -eq 0) {
    Write-Log "Nothing to disable" -Level Success
}

# --- STEP 3: UNINSTALL VMWARE TOOLS ---
Write-Section "STEP 3. UNINSTALL VMWARE TOOLS"

if ($vmTools) {
    $uninst = $vmTools.UninstallString
    if ($uninst) {
        Write-Log "Running uninstaller..." -Level Action
        if ($uninst -match "msiexec") {
            if ($uninst -match '\{[0-9A-Fa-f\-]+\}') {
                $msiGuid = $Matches[0]
                Write-Log "  MSI ProductCode: $msiGuid" -Level Info
                try {
                    $p = Start-Process -FilePath "msiexec.exe" `
                        -ArgumentList "/x $msiGuid /qn /norestart" `
                        -Wait -PassThru -NoNewWindow -ErrorAction Stop
                    Write-Log "  MSI uninstall exit code: $($p.ExitCode)" -Level Success
                } catch {
                    Write-Log "  MSI uninstall failed: $($_.Exception.Message)" -Level Warning
                }
            }
        } else {
            try {
                $p = Start-Process -FilePath "cmd.exe" `
                    -ArgumentList "/c `"$uninst`" /S /v`"/qn`"" `
                    -Wait -PassThru -NoNewWindow -ErrorAction Stop
                Write-Log "  EXE uninstall exit code: $($p.ExitCode)" -Level Success
            } catch {
                Write-Log "  EXE uninstall failed: $($_.Exception.Message)" -Level Warning
            }
        }
    }
    Start-Sleep -Seconds 5

    $verify = Get-ItemProperty -Path @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    ) -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match "VMware Tools" }

    if ($verify) {
        Write-Log "VMware Tools still present in registry after uninstall" -Level Warning
        Write-Log "  It may need a reboot to fully remove." -Level Warning
    } else {
        Write-Log "VMware Tools: REMOVED" -Level Success
    }
} else {
    Write-Log "VMware Tools not installed, skipping" -Level Success
}

# --- STEP 4: REMOVE PHANTOM VMWARE DEVICES ---
Write-Section "STEP 4. REMOVE PHANTOM VMWARE DEVICES"

$phantomDevices = @(Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object {
        $_.InstanceId -match "VEN_15AD" -and
        ($_.Status -eq "Unknown" -or $_.Status -eq "Error")
    })

if ($phantomDevices.Count -eq 0) {
    Write-Log "No phantom VMware devices to remove" -Level Success
} else {
    Write-Log "Found $($phantomDevices.Count) phantom devices" -Level Info
    $removed = 0
    $failed  = 0
    foreach ($d in $phantomDevices) {
        $instanceId = $d.InstanceId
        Write-Log "Removing: $instanceId" -Level Action
        try {
            $out = & pnputil.exe /remove-device "$instanceId" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  OK" -Level Success
                $removed++
            } else {
                Write-Log "  pnputil exit code $LASTEXITCODE" -Level Warning
                $failed++
            }
        } catch {
            Write-Log "  Failed: $($_.Exception.Message)" -Level Warning
            $failed++
        }
    }
    Write-Log "Removed: $removed, Failed: $failed" -Level Info
}

# --- STEP 5: VERIFY VIRTIO COMPONENTS ---
Write-Section "STEP 5. VERIFY VIRTIO COMPONENTS"

$vImg = (Get-ItemProperty -Path $vioscsiKey -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
$vTag = (Get-ItemProperty -Path $vioscsiKey -Name "Tag"       -ErrorAction SilentlyContinue).Tag
if ($vImg -and $vTag -eq 64) {
    Write-Log "vioscsi: ImagePath OK, Tag=$vTag" -Level Success
} else {
    Write-Log "vioscsi: PROBLEM - ImagePath='$vImg', Tag='$vTag'" -Level Error
}

$netkvmKey = "HKLM:\SYSTEM\CurrentControlSet\Services\netkvm"
if (Test-Path -LiteralPath $netkvmKey) {
    $nkStatus = (Get-Service -Name "netkvm" -ErrorAction SilentlyContinue).Status
    Write-Log "netkvm: present, service status=$nkStatus" -Level Success
} else {
    Write-Log "netkvm: service key not found (ok if VirtIO NIC not in use)" -Level Info
}

$qga = Get-Service -Name "QEMU-GA" -ErrorAction SilentlyContinue
if ($qga) {
    Write-Log "QEMU-GA: $($qga.Status)" -Level Success
} else {
    Write-Log "QEMU-GA: not found" -Level Warning
}

$storCtl = Get-PnpDevice -Class "SCSIAdapter" -PresentOnly -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -match "VEN_1AF4" }
if ($storCtl) {
    Write-Log "VirtIO SCSI controllers: $($storCtl.Count) present" -Level Success
} else {
    Write-Log "VirtIO SCSI controllers: NONE FOUND (unexpected in KVM)" -Level Error
}

# --- STEP 6: SUMMARY ---
Write-Section "STEP 6. SUMMARY"

$issues = @()
$ok     = @()

if ($vmTools) { $issues += "VMware Tools still in registry (may need reboot)" }
else          { $ok     += "VMware Tools: not present" }

if ($vmServicesFound.Count -gt 0) {
    $stillEnabled = @()
    foreach ($svc in $vmServicesFound) {
        $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
        if ($s -and $s.StartType -ne "Disabled") { $stillEnabled += $svc }
    }
    if ($stillEnabled.Count -gt 0) {
        $issues += "VMware services still enabled: $($stillEnabled -join ', ')"
    } else {
        $ok += "All VMware services disabled"
    }
} else {
    $ok += "No VMware services found"
}

if ($phantomDevices.Count -gt 0) {
    $stillPresent = @(Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match "VEN_15AD" -and ($_.Status -eq "Unknown" -or $_.Status -eq "Error") })
    if ($stillPresent.Count -gt 0) {
        $issues += "$($stillPresent.Count) phantom VEN_15AD devices remain"
    } else {
        $ok += "All phantom VEN_15AD devices removed"
    }
} else {
    $ok += "No phantom VEN_15AD devices"
}

if ($vImg -and $vTag -eq 64) { $ok     += "vioscsi intact (Tag=64)" }
else                          { $issues += "vioscsi integrity problem" }

Write-Log ""
Write-Log "---- OK ----"
foreach ($o in $ok) { Write-Log "  [+] $o" -Level Success }

if ($issues.Count -gt 0) {
    Write-Log ""
    Write-Log "---- REMAINING ISSUES ----"
    foreach ($i in $issues) { Write-Log "  [!] $i" -Level Warning }
} else {
    Write-Log ""
    Write-Log "Cleanup complete. No remaining issues." -Level Success
}

# --- STEP 7: NEXT STEPS ---
Write-Section "STEP 7. NEXT STEPS"

Write-Log "Post-migration cleanup is complete." -Level Success
Write-Log ""
Write-Log "OPTIONAL next steps:" -Level Info
Write-Log "  - Run 6-CloudBase-Init.ps1 to enable metadata password injection"
Write-Log "  - Run 7-Sysprep.ps1 (only for golden image creation, irreversible)"
Write-Log ""

if ($issues.Count -gt 0) {
    Write-Log "RECOMMENDED: reboot the VM to finish VMware Tools cleanup." -Level Warning
    Write-Log ""
}

Write-Log "Log saved to: $Global:LogPath" -Level Info
Write-Log ""
Read-Host "Press Enter to close"