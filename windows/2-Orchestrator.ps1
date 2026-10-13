# =======================================================================
# FILE: 2-Orchestrator.ps1
# VERSION: 4.1
# =======================================================================
# State machine for migration-to-mws toolkit.
#
# Detects:
#   - disk style (MBR / GPT)
#   - firmware (BIOS / UEFI)
#   - environment (VMware / KVM / Hyper-V / Xen / Unknown)
#   - vioscsi readiness (service + ImagePath + Tag=64)
#   - devnode readiness (Enum\PCI\...\4&1c6c80be&0&0018)
#   - boot readiness (ESP + BCD + bootmgfw.efi)
#   - anomalies (Dynamic disk, BitLocker, OOBE, pending reboot, low space)
#
# Decides:
#   - ReadyForExport  -> tell user to export
#   - RunMigration    -> call 3-Diagnostic + 4-Migration
#   - PostMigration   -> suggest scripts 5/6/7 (inside KVM)
#   - AbortXxx        -> stop with reason
#
# Universal PowerShell 5.1 (Windows Server 2019-2025).
# ASCII-only. No here-strings.
# =======================================================================

$SCRIPT_VERSION = "4.1"
$ErrorActionPreference = "Continue"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

# Ampersand-safe constants
$AMP = [char]38
$DEVNODE_SUBPATH = "SYSTEM\CurrentControlSet\Enum\PCI\VEN_1AF4" + $AMP + `
                   "DEV_1004" + $AMP + "SUBSYS_00081AF4" + $AMP + "REV_00" + `
                   "\4" + $AMP + "1c6c80be" + $AMP + "0" + $AMP + "0018"
$DEVNODE_PSPATH  = "HKLM:\" + $DEVNODE_SUBPATH
$VIOSCSI_KEY     = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
$ESP_GPT_TYPE    = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"

# =======================================================================
# HELPERS
# =======================================================================

function Write-Both {
    param([string]$Msg = "", [string]$Color = "White")
    Write-Host $Msg -ForegroundColor $Color
}

function Get-HypervisorType {
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if (-not $cs) { return "Unknown" }
    $mfr = "$($cs.Manufacturer)"
    $mdl = "$($cs.Model)"

    if ($mfr -match "VMware")                                       { return "VMware" }
    if ($mfr -match "QEMU" -or $mdl -match "QEMU")                  { return "KVM" }
    if ($mfr -match "Microsoft" -and $mdl -match "Virtual")         { return "Hyper-V" }
    if ($mfr -match "Xen")                                          { return "Xen" }
    if (-not $cs.HypervisorPresent)                                 { return "BareMetal" }
    return "Unknown"
}

# =======================================================================
# STATE DETECTION
# =======================================================================

function Get-MigrationState {
    param([int]$DiskNumber = 0)

    $state = [PSCustomObject]@{
        DiskStyle      = $null    # 'MBR' | 'GPT' | $null
        Firmware       = $null    # 'BIOS' | 'UEFI' | 'Unknown'
        Environment    = $null    # 'VMware' | 'KVM' | 'Hyper-V' | 'Xen' | 'BareMetal' | 'Unknown'
        VioscsiReady   = $false   # service + ImagePath + Tag=64
        DevnodeReady   = $false   # Enum\PCI\...\4&1c6c80be&0&0018 with Service=vioscsi
        BootReady      = $false   # ESP + BCD + bootmgfw.efi
        HasESP         = $false
        HasExtended    = $false
        HasBitLocker   = $false
        IsDynamic      = $false
        OOBE           = $false
        PendingReboot  = $false
        FreeSpaceGB    = 0
        FileSystem     = $null    # 'NTFS' | 'ReFS' | 'FAT32' | ...
        Issues         = @()
        Blocker        = $null    # если не $null — миграция не запускается
    }

    # --- Disk style ---
    $disk = Get-Disk -Number $DiskNumber -ErrorAction SilentlyContinue
    if (-not $disk) {
        $state.Issues += "Cannot query Disk 0"
        $state.Blocker = "AbortNoDisk"
        return $state
    }
    $state.DiskStyle = $disk.PartitionStyle
    if ($disk.IsDynamic) {
        $state.IsDynamic = $true
        $state.Issues += "Dynamic disk"
        $state.Blocker = "AbortDynamicDisk"
    }
    if ($disk.Size -gt 16TB) {
        $state.Issues += "Disk > 16 TB"
        $state.Blocker = "AbortDiskTooLarge"
    }

    # --- Firmware ---
    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
    $state.Firmware = switch ($fw) { 1 { 'BIOS' } 2 { 'UEFI' } default { 'Unknown' } }

    # --- Environment ---
    $state.Environment = Get-HypervisorType

    # --- BitLocker ---
    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl.ProtectionStatus -eq 'On') {
            $state.HasBitLocker = $true
            $state.Issues += "BitLocker active on $env:SystemDrive"
            if (-not $state.Blocker) { $state.Blocker = "AbortBitLocker" }
        }
    } catch { }

    # --- OOBE ---
    try {
        $setup = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name SystemSetupInProgress -ErrorAction SilentlyContinue).SystemSetupInProgress
        if ($setup -eq 1) {
            $state.OOBE = $true
            $state.Issues += "System in OOBE (SystemSetupInProgress=1)"
            if (-not $state.Blocker) { $state.Blocker = "AbortOOBE" }
        }
    } catch { }

    # --- Pending reboot ---
    $reboot = $false
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $reboot = $true }
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations") { $reboot = $true }
    if ($reboot) {
        $state.PendingReboot = $true
        $state.Issues += "Pending reboot"
        if (-not $state.Blocker) { $state.Blocker = "AbortPendingReboot" }
    }

    # --- Free space ---
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($vol) {
        $state.FreeSpaceGB = [math]::Round($vol.FreeSpace / 1GB, 2)
        if ($state.FreeSpaceGB -lt 2) {
            $state.Issues += "Free space < 2 GB"
            if (-not $state.Blocker) { $state.Blocker = "AbortLowSpace" }
        }
    }

    # --- File system ---
    try {
        $fs = (Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).FileSystem
        $state.FileSystem = $fs
        if ($fs -ne 'NTFS') {
            $state.Issues += "File system is $fs (expected NTFS)"
        }
    } catch { }

    # --- vioscsi ---
    if (Test-Path $VIOSCSI_KEY) {
        $img = (Get-ItemProperty $VIOSCSI_KEY -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        $tag = (Get-ItemProperty $VIOSCSI_KEY -Name Tag -ErrorAction SilentlyContinue).Tag
        if ($img -and $tag -eq 64) { $state.VioscsiReady = $true }
    }

    # --- Devnode ---
    if (Test-Path -LiteralPath $DEVNODE_PSPATH) {
        $svc = (Get-ItemProperty -LiteralPath $DEVNODE_PSPATH -Name Service -ErrorAction SilentlyContinue).Service
        if ($svc -eq 'vioscsi') { $state.DevnodeReady = $true }
    }

    # --- ESP + BCD + bootloader ---
    $esp = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
           Where-Object { $_.GptType -eq $ESP_GPT_TYPE } | Select-Object -First 1
    if ($esp) {
        $state.HasESP = $true
        $letter = $esp.DriveLetter
        $tempAssigned = $false
        if (-not $letter) {
            try {
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction Stop
                $letter = "S"
                $tempAssigned = $true
            } catch { }
        }
        if ($letter) {
            $bcd   = "${letter}:\EFI\Microsoft\Boot\BCD"
            $mgfw  = "${letter}:\EFI\Microsoft\Boot\bootmgfw.efi"
            if ((Test-Path $bcd) -and (Test-Path $mgfw)) { $state.BootReady = $true }
            if ($tempAssigned) {
                Remove-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction SilentlyContinue
            }
        }
    } else {
        if ($state.DiskStyle -eq 'GPT') {
            $state.Issues += "GPT disk without ESP"
            if (-not $state.Blocker) { $state.Blocker = "AbortNoESP" }
        }
    }

    # --- Extended (MBR only) ---
    if ($state.DiskStyle -eq 'MBR') {
        $ext = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
               Where-Object { $_.Type -eq 'Extended' }
        if ($ext) { $state.HasExtended = $true }
    }

    return $state
}

function Show-State {
    param($State)
    Write-Both ""
    Write-Both "=== Detected State ===" "Cyan"
    Write-Both ("  Environment : {0}" -f $State.Environment)
    Write-Both ("  Disk 0      : {0}" -f $State.DiskStyle)
    Write-Both ("  Firmware    : {0}" -f $State.Firmware)
    Write-Both ("  File system : {0}" -f $State.FileSystem)
    Write-Both ("  Free space  : {0} GB" -f $State.FreeSpaceGB)
    Write-Both ("  vioscsi     : {0}" -f $(if ($State.VioscsiReady) { "ready" } else { "not ready" }))
    Write-Both ("  devnode     : {0}" -f $(if ($State.DevnodeReady) { "ready" } else { "not ready" }))
    Write-Both ("  Boot (BCD)  : {0}" -f $(if ($State.BootReady)    { "ready" } else { "not ready" }))
    if ($State.HasExtended)    { Write-Both "  Extended    : present" "Yellow" }
    if ($State.HasBitLocker)   { Write-Both "  BitLocker   : active"  "Yellow" }
    if ($State.IsDynamic)      { Write-Both "  Dynamic disk: yes"     "Yellow" }
    if ($State.OOBE)           { Write-Both "  OOBE        : in progress" "Yellow" }
    if ($State.PendingReboot)  { Write-Both "  Reboot      : pending" "Yellow" }
    if ($State.Issues.Count -gt 0) {
        Write-Both ""
        Write-Both "  Issues:" "Yellow"
        foreach ($i in $State.Issues) { Write-Both ("    - {0}" -f $i) "Yellow" }
    }
    Write-Both ""
}

# =======================================================================
# PREFLIGHT
# =======================================================================

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Both "ERROR: Not running as Administrator." "Red"
    Write-Both "Right-click 1-run.bat -> Run as administrator." "Red"
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Both ""
Write-Both "==========================================================" "Cyan"
Write-Both (" MWS MIGRATION ORCHESTRATOR v{0}" -f $SCRIPT_VERSION) "Cyan"
Write-Both "==========================================================" "Cyan"

# =======================================================================
# DETECT
# =======================================================================

Write-Both ""
Write-Both "Detecting environment and state..." "Yellow"
$state = Get-MigrationState -DiskNumber 0

Show-State $state

# =======================================================================
# HYPERVISOR WARNING (non-blocking)
# =======================================================================

if ($state.Environment -notin @('VMware', 'KVM')) {
    Write-Both "[!] Hypervisor: $($state.Environment)." "Yellow"
    Write-Both "    Toolkit is tested on VMware ESXi and KVM (MWS)." "Yellow"
    Write-Both "    On other platforms some steps may not apply." "Yellow"
    $confirm = Read-Host "Continue anyway? (y/N)"
    if ($confirm -ne 'y' -and $confirm -ne 'Y') {
        Write-Both "Aborted by user." "Info"
        Read-Host "Press Enter to exit"
        exit 0
    }
}

# =======================================================================
# BLOCKERS
# =======================================================================

if ($state.Blocker) {
    Write-Both ""
    Write-Both "==========================================================" "Red"
    Write-Both " MIGRATION CANNOT PROCEED" "Red"
    Write-Both "==========================================================" "Red"
    Write-Both ""

    $sysDrive = $env:SystemDrive
    $blockerMsg = switch ($state.Blocker) {
        'AbortNoDisk'         { "Cannot query Disk 0. Check access and retry." }
        'AbortDynamicDisk'    { "Disk 0 is a Dynamic disk. Convert to Basic before migration." }
        'AbortDiskTooLarge'   { "Disk 0 is larger than 16 TB (MWS limit)." }
        'AbortBitLocker'      { "BitLocker is active on $sysDrive. Decrypt the volume before migration." }
        'AbortOOBE'           { "Windows is in OOBE state. Finish initial setup before migration." }
        'AbortPendingReboot'  { "Pending reboot detected. Reboot the VM and start again." }
        'AbortLowSpace'       { "Free space on C: is less than 2 GB. Free at least 2 GB and retry." }
        'AbortNoESP'          { "GPT disk without ESP partition. Disk layout is damaged. Restore from backup." }
        default               { "Unknown blocker: $($state.Blocker)" }
    }
    Write-Both $blockerMsg "Red"

    Write-Both ""
    Write-Both "No changes were made to the VM." "Info"
    Read-Host "Press Enter to exit"
    exit 1
}

# =======================================================================
# DECISION TABLE
# =======================================================================

$scriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($scriptDir)) { $scriptDir = (Get-Location).Path }

$diagScript  = Join-Path $scriptDir "3-Diagnostic.ps1"
$migScript   = Join-Path $scriptDir "4-Migration.ps1"
$postScript  = Join-Path $scriptDir "5-Post-Migration.ps1"
$cbScript    = Join-Path $scriptDir "6-CloudBase-Init.ps1"
$sysScript   = Join-Path $scriptDir "7-Sysprep.ps1"

# -------------------------------------------------------------------
# KVM target — already migrated
# -------------------------------------------------------------------
if ($state.Environment -eq 'KVM') {
    Write-Both "=== STATE: INSIDE KVM (post-migration) ===" "Green"
    Write-Both ""
    Write-Both "VM is running in KVM (MWS). Migration is complete." "Green"
    Write-Both ""
    Write-Both "Recommended next steps:" "Cyan"
    Write-Both "  [1] 5-Post-Migration.ps1  - clean VMware leftovers"
    Write-Both "  [2] 6-CloudBase-Init.ps1  - optional: metadata integration"
    Write-Both "  [3] 7-Sysprep.ps1         - optional: golden image"
    Write-Both ""
    if (-not $state.VioscsiReady) {
        Write-Both "[!] vioscsi is NOT ready inside KVM." "Red"
        Write-Both "    This should not happen after successful migration." "Yellow"
    } else {
        Write-Both "[+] vioscsi: ready" "Green"
    }
    Write-Both ""
    Write-Both "This orchestrator does not auto-run scripts 5/6/7." "White"
    Write-Both "Run them manually from the same folder." "White"
    Write-Both ""
    Read-Host "Press Enter to exit"
    exit 0
}

# -------------------------------------------------------------------
# Ready for export — VMware, all checks pass
# -------------------------------------------------------------------
if ($state.Environment -eq 'VMware' -and
    $state.DiskStyle -eq 'GPT' -and
    $state.VioscsiReady -and
    $state.DevnodeReady -and
    $state.BootReady) {

    Write-Both "=== STATE: READY FOR EXPORT ===" "Green"
    Write-Both ""
    Write-Both "All checks passed:" "Green"
    Write-Both "  [+] Disk: GPT"
    Write-Both "  [+] vioscsi: registered (Tag=64)"
    Write-Both "  [+] devnode: present in Enum\PCI"
    Write-Both "  [+] Boot: BCD + bootmgfw.efi on ESP"
    Write-Both ""
    Write-Both "Next steps:" "Cyan"
    Write-Both "  1. Power off this VM in vSphere"
    Write-Both "  2. Export disk and upload to S3 (see README)"
    Write-Both "  3. Import into MWS Cloud Platform"
    Write-Both "  4. Boot the VM in KVM"
    Write-Both "  5. Inside KVM: run 5-Post-Migration.ps1"
    Write-Both ""
    Write-Both "Do NOT boot this VM in UEFI inside VMware." "Yellow"
    Write-Both "Do NOT switch firmware BIOS -> UEFI in vSphere." "Yellow"
    Write-Both ""
    Read-Host "Press Enter to exit"
    exit 0
}

# -------------------------------------------------------------------
# Ready for export — non-VMware, all checks pass
# -------------------------------------------------------------------
if ($state.DiskStyle -eq 'GPT' -and
    $state.VioscsiReady -and
    $state.DevnodeReady -and
    $state.BootReady) {

    Write-Both "=== STATE: READY FOR EXPORT ===" "Green"
    Write-Both ""
    Write-Both "Environment: $($state.Environment)" "Info"
    Write-Both "All required checks passed." "Green"
    Write-Both ""
    Write-Both "Export the disk and import into MWS Cloud Platform." "Cyan"
    Write-Both ""
    Read-Host "Press Enter to exit"
    exit 0
}

# -------------------------------------------------------------------
# Run migration
# -------------------------------------------------------------------
Write-Both "=== STATE: MIGRATION NEEDED ===" "Yellow"
Write-Both ""
Write-Both "Reasons:" "Cyan"
if ($state.DiskStyle -eq 'MBR')        { Write-Both "  - Disk is MBR (must be GPT for KVM/UEFI)" }
if (-not $state.VioscsiReady)          { Write-Both "  - vioscsi is not fully registered" }
if (-not $state.DevnodeReady)          { Write-Both "  - devnode in Enum\PCI is missing" }
if (-not $state.BootReady)             { Write-Both "  - UEFI BCD is missing or incomplete" }
if ($state.HasExtended)                { Write-Both "  - Extended partition present" }
Write-Both ""
Write-Both "Plan:" "Cyan"
Write-Both "  1. Run 3-Diagnostic.ps1 (baseline, read-only)"
Write-Both "  2. Run 4-Migration.ps1 (transform the VM)"
Write-Both "  3. VM shuts down automatically"
Write-Both ""
Write-Both "Note: if disk is already GPT, mbr2gpt step will be skipped." "Info"
Write-Both ""

if (-not (Test-Path -LiteralPath $diagScript)) {
    Write-Both "ERROR: $diagScript not found" "Red"
    Read-Host "Press Enter to exit"
    exit 1
}
if (-not (Test-Path -LiteralPath $migScript)) {
    Write-Both "ERROR: $migScript not found" "Red"
    Read-Host "Press Enter to exit"
    exit 1
}

Read-Host "Press Enter to continue (Ctrl+C to cancel)"

Write-Both ""
Write-Both ">>> Running 3-Diagnostic.ps1" "Green"
Write-Both "    (press Enter after it completes to continue to migration)" "DarkGray"
& $diagScript

Write-Both ""
Write-Both ">>> Running 4-Migration.ps1" "Green"
& $migScript

# 4-Migration performs Stop-Computer at the end.
exit 0