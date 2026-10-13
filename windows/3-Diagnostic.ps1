# =======================================================================
# FILE: 3-Diagnostic.ps1
# VERSION: 4.1
# =======================================================================
# Read-only diagnostic for migration-to-mws.
#
# Sections:
#   §0   STATE SUMMARY (Get-MigrationState)
#   §1   System / Firmware / Hypervisor
#   §2   Disk / Partitions / Volumes
#   §3   BCD (all variants)
#   §4   ESP probe (files, BCD, fallback)
#   §5   Boot-critical services (Start=0)
#   §6   CDDB
#   §7   vioscsi full dump
#   §8   All SCSIAdapter Class entries
#   §9   All VEN_1AF4 devnodes
#   §10  PnP live VEN_1AF4
#   §11  Legacy drivers + StartOverride
#   §12  Time / RTC / BootDriverFlags
#   §13  Bootloader files
#   §14  COMPARISON vs reference KVM
#   §15  VERDICT
#
# Universal PowerShell 5.1 (Windows Server 2019-2025).
# ASCII-only. No here-strings.
# =======================================================================

$SCRIPT_VERSION = "4.1"
$ErrorActionPreference = "Continue"

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- Script directory ---
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    try { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path } catch {}
}
if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = (Get-Location).Path }

# --- Logs directory ---
$LogDir = Join-Path $ScriptDir "logs"
if (-not (Test-Path -LiteralPath $LogDir)) {
    try { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }
    catch { $LogDir = $env:USERPROFILE }
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ReportFile = Join-Path $LogDir ("3-Diagnostic_v{0}_{1}_{2}.log" -f $SCRIPT_VERSION, $stamp, $env:COMPUTERNAME)

# --- Constants ---
$ESP_GPT_TYPE = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"
$SCSI_CLS     = "{4d36e97b-e325-11ce-bfc1-08002be10318}"

# Ampersand-safe constants
$AMP = [char]38
$DEVNODE_PATH = "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\VEN_1AF4" + $AMP + `
                "DEV_1004" + $AMP + "SUBSYS_00081AF4" + $AMP + "REV_00" + `
                "\4" + $AMP + "1c6c80be" + $AMP + "0" + $AMP + "0018"

# =======================================================================
# LOGGING
# =======================================================================

function Out-Line {
    param([string]$Msg = "", [string]$Level = "INFO")
    $line = "[$Level] $Msg"
    $line | Out-File -FilePath $ReportFile -Append -Encoding UTF8 -ErrorAction SilentlyContinue
    Write-Host $line
}

function Out-Section {
    param([string]$Title)
    Out-Line ""
    Out-Line "=================================================================="
    Out-Line "=== $Title"
    Out-Line "=================================================================="
}

function Out-Cmd {
    param([string]$Title, [scriptblock]$Block)
    Out-Line ""
    Out-Line "--- $Title ---"
    try {
        $out = & $Block 2>&1
        $str = $out | Out-String -Width 4096
        $lines = $str -split "`r?`n"
        foreach ($l in $lines) { Out-Line "  $l" }
    } catch {
        Out-Line "  ERROR: $($_.Exception.Message)" "ERR"
    }
}

function Get-MatchStatus {
    param($Ref, $Ours, [string]$CheckType = "eq")
    if ($null -eq $Ours -or $Ours -eq "") { return "N/A" }
    switch ($CheckType) {
        "eq" { if ($Ref -eq $Ours) { return "OK" } else { return "DIFF" } }
        "ge" { if ($Ours -ge $Ref) { return "OK" } else { return "DIFF" } }
    }
    return "?"
}

# =======================================================================
# STATE DETECTION (mirrors 2-Orchestrator.ps1)
# =======================================================================

function Get-MigrationState {
    param([int]$DiskNumber = 0)

    $state = [PSCustomObject]@{
        DiskStyle      = $null
        Firmware       = $null
        Environment    = $null
        VioscsiReady   = $false
        DevnodeReady   = $false
        BootReady      = $false
        HasESP         = $false
        HasExtended    = $false
        HasBitLocker   = $false
        IsDynamic      = $false
        OOBE           = $false
        PendingReboot  = $false
        FreeSpaceGB    = 0
        FileSystem     = $null
        Issues         = @()
        Blocker        = $null
    }

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

    $fw = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control" -Name PEFirmwareType -ErrorAction SilentlyContinue).PEFirmwareType
    $state.Firmware = switch ($fw) { 1 { 'BIOS' } 2 { 'UEFI' } default { 'Unknown' } }

    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) {
        $mfr = "$($cs.Manufacturer)"; $mdl = "$($cs.Model)"
        if     ($mfr -match "VMware")                                { $state.Environment = "VMware" }
        elseif ($mfr -match "QEMU" -or $mdl -match "QEMU")           { $state.Environment = "KVM" }
        elseif ($mfr -match "Microsoft" -and $mdl -match "Virtual")  { $state.Environment = "Hyper-V" }
        elseif ($mfr -match "Xen")                                   { $state.Environment = "Xen" }
        elseif (-not $cs.HypervisorPresent)                          { $state.Environment = "BareMetal" }
        else                                                         { $state.Environment = "Unknown" }
    }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl.ProtectionStatus -eq 'On') {
            $state.HasBitLocker = $true
            $state.Issues += "BitLocker active"
            if (-not $state.Blocker) { $state.Blocker = "AbortBitLocker" }
        }
    } catch {}

    try {
        $setup = (Get-ItemProperty "HKLM:\SYSTEM\Setup" -Name SystemSetupInProgress -ErrorAction SilentlyContinue).SystemSetupInProgress
        if ($setup -eq 1) {
            $state.OOBE = $true
            $state.Issues += "System in OOBE"
            if (-not $state.Blocker) { $state.Blocker = "AbortOOBE" }
        }
    } catch {}

    $reboot = $false
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $reboot = $true }
    if (Test-Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations") { $reboot = $true }
    if ($reboot) {
        $state.PendingReboot = $true
        $state.Issues += "Pending reboot"
        if (-not $state.Blocker) { $state.Blocker = "AbortPendingReboot" }
    }

    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'" -ErrorAction SilentlyContinue
    if ($vol) {
        $state.FreeSpaceGB = [math]::Round($vol.FreeSpace / 1GB, 2)
        if ($state.FreeSpaceGB -lt 2) {
            $state.Issues += "Free space < 2 GB"
            if (-not $state.Blocker) { $state.Blocker = "AbortLowSpace" }
        }
    }

    try {
        $fs = (Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop).FileSystem
        $state.FileSystem = $fs
        if ($fs -ne 'NTFS') { $state.Issues += "File system is $fs (expected NTFS)" }
    } catch {}

    $vk = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
    if (Test-Path $vk) {
        $img = (Get-ItemProperty $vk -Name ImagePath -ErrorAction SilentlyContinue).ImagePath
        $tag = (Get-ItemProperty $vk -Name Tag -ErrorAction SilentlyContinue).Tag
        if ($img -and $tag -eq 64) { $state.VioscsiReady = $true }
    }

    if (Test-Path -LiteralPath $DEVNODE_PATH) {
        $svc = (Get-ItemProperty -LiteralPath $DEVNODE_PATH -Name Service -ErrorAction SilentlyContinue).Service
        if ($svc -eq 'vioscsi') { $state.DevnodeReady = $true }
    }

    $esp = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
           Where-Object { $_.GptType -eq $ESP_GPT_TYPE } | Select-Object -First 1
    if ($esp) {
        $state.HasESP = $true
        $letter = $esp.DriveLetter
        $tempAssigned = $false
        if (-not $letter) {
            try {
                Add-PartitionAccessPath -DiskNumber $DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction Stop
                $letter = "S"; $tempAssigned = $true
            } catch {}
        }
        if ($letter) {
            $bcd  = "${letter}:\EFI\Microsoft\Boot\BCD"
            $mgfw = "${letter}:\EFI\Microsoft\Boot\bootmgfw.efi"
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

    if ($state.DiskStyle -eq 'MBR') {
        $ext = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'Extended' }
        if ($ext) { $state.HasExtended = $true }
    }

    return $state
}

# =======================================================================
# HEADER
# =======================================================================

"===============================================================" | Out-File -FilePath $ReportFile -Encoding UTF8
"=== 3-Diagnostic.ps1 v$SCRIPT_VERSION ===" | Out-File -FilePath $ReportFile -Append
"===============================================================" | Out-File -FilePath $ReportFile -Append

Out-Line "Script version: $SCRIPT_VERSION"
Out-Line "Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))"
Out-Line "Computer: $env:COMPUTERNAME"
Out-Line "OS: $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption)"
Out-Line "Build: $((Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).BuildNumber)"
Out-Line "PS Version: $($PSVersionTable.PSVersion.ToString())"
Out-Line "Report: $ReportFile"

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) { Out-Line "Admin: YES" "OK" } else { Out-Line "Admin: NO - some reads may fail" "WARN" }

# =======================================================================
# §0 STATE SUMMARY
# =======================================================================

Out-Section "0. STATE SUMMARY (Get-MigrationState)"

$state = Get-MigrationState -DiskNumber 0

Out-Line ""
Out-Line "  Disk style   : $($state.DiskStyle)"
Out-Line "  Firmware     : $($state.Firmware)"
Out-Line "  Environment  : $($state.Environment)"
Out-Line "  File system  : $($state.FileSystem)"
Out-Line "  Free space   : $($state.FreeSpaceGB) GB"
Out-Line ""
Out-Line "  vioscsi ready: $($state.VioscsiReady)"
Out-Line "  devnode ready: $($state.DevnodeReady)"
Out-Line "  Boot ready   : $($state.BootReady)"
Out-Line "  Has ESP      : $($state.HasESP)"
Out-Line "  Has Extended : $($state.HasExtended)"
Out-Line "  BitLocker    : $($state.HasBitLocker)"
Out-Line "  Dynamic disk : $($state.IsDynamic)"
Out-Line "  OOBE         : $($state.OOBE)"
Out-Line "  Pending reboot: $($state.PendingReboot)"
Out-Line ""

if ($state.Issues.Count -gt 0) {
    Out-Line "  Issues:" "WARN"
    foreach ($i in $state.Issues) { Out-Line "    - $i" "WARN" }
} else {
    Out-Line "  Issues: none" "OK"
}

if ($state.Blocker) {
    Out-Line ""
    Out-Line "  Blocker: $($state.Blocker)" "ERR"
}

# =======================================================================
# §1 SYSTEM / FIRMWARE / HYPERVISOR
# =======================================================================

Out-Section "1. SYSTEM / FIRMWARE / HYPERVISOR"

Out-Cmd "Win32_ComputerSystem" {
    Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue |
        Format-List Manufacturer, Model, SystemType, TotalPhysicalMemory, HypervisorPresent
}
Out-Cmd "Win32_BIOS" {
    Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue |
        Format-List Manufacturer, SMBIOSBIOSVersion, Version, ReleaseDate
}
Out-Cmd "Win32_ComputerSystemProduct" {
    Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue |
        Format-List Name, Vendor, Version, UUID
}
Out-Cmd "PEFirmwareType" {
    $fw = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "PEFirmwareType" -ErrorAction SilentlyContinue).PEFirmwareType
    if ($fw -eq 1) { "BIOS (Legacy)" }
    elseif ($fw -eq 2) { "UEFI" }
    else { "Unknown ($fw)" }
}
Out-Cmd "SystemStartOptions" {
    (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "SystemStartOptions" -ErrorAction SilentlyContinue).SystemStartOptions
}
Out-Cmd "mbr2gpt.exe presence" {
    $p = "$env:SystemRoot\System32\mbr2gpt.exe"
    if (Test-Path -LiteralPath $p) { "PRESENT: $p" } else { "MISSING: $p" }
}

# =======================================================================
# §2 DISK / PARTITIONS / VOLUMES
# =======================================================================

Out-Section "2. DISK / PARTITIONS / VOLUMES"

Out-Cmd "Get-Disk" {
    Get-Disk -ErrorAction SilentlyContinue | Format-List Number, PartitionStyle, BusType, Guid, LogicalSectorSize, PhysicalSectorSize, IsBoot, IsSystem, IsDynamic, Size
}
Out-Cmd "Get-Partition" {
    Get-Partition -ErrorAction SilentlyContinue | Format-List PartitionNumber, DiskNumber, DriveLetter, Type, GptType, Guid, Offset, Size, IsBoot, IsSystem, IsActive, IsHidden
}
Out-Cmd "Partition summary" {
    $disks = Get-Disk -ErrorAction SilentlyContinue
    foreach ($d in $disks) {
        $szGB = [math]::Round($d.Size / 1GB, 2)
        "Disk $($d.Number): Style=$($d.PartitionStyle) Bus=$($d.BusType) Size=${szGB}GB Boot=$($d.IsBoot) System=$($d.IsSystem) Dynamic=$($d.IsDynamic)"
        "  Disk GUID: $($d.Guid)"
        "  LogicalSectorSize: $($d.LogicalSectorSize) PhysicalSectorSize: $($d.PhysicalSectorSize)"
        $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | Sort-Object Offset
        foreach ($p in $parts) {
            $szMB = [math]::Round($p.Size / 1MB, 1)
            "  #$($p.PartitionNumber) Type=$($p.Type) Offset=$($p.Offset) Size=${szMB}MB Letter='$($p.DriveLetter)' Boot=$($p.IsBoot) System=$($p.IsSystem)"
            "    GptType: $($p.GptType)"
            "    Guid: $($p.Guid)"
        }
    }
}
Out-Cmd "Volume mapping (mountvol)" { & mountvol.exe 2>&1 }
Out-Cmd "Win32_DiskDrive" {
    Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
        Format-List Index, Model, InterfaceType, Size, Partitions, PNPDeviceID
}

# =======================================================================
# §3 BCD
# =======================================================================

Out-Section "3. BCD"

Out-Cmd "bcdedit /enum all /v"          { & bcdedit.exe /enum all /v 2>&1 }
Out-Cmd "bcdedit /enum {default} /v"    { & bcdedit.exe /enum "{default}" /v 2>&1 }
Out-Cmd "bcdedit /enum {fwbootmgr} /v"  { & bcdedit.exe /enum "{fwbootmgr}" /v 2>&1 }

# =======================================================================
# §4 ESP PROBE
# =======================================================================

Out-Section "4. ESP / UEFI BCD PROBE"

$esp = $null
$espLetter = $null
$assignedTemp = $false

try {
    $disks = Get-Disk -ErrorAction SilentlyContinue
    foreach ($d in $disks) {
        $parts = Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue
        $f = $parts | Where-Object { $_.GptType -eq $ESP_GPT_TYPE } | Select-Object -First 1
        if ($f) { $esp = $f; break }
    }
} catch {}

if ($null -eq $esp) {
    Out-Line "ESP NOT FOUND (normal for MBR)" "WARN"
} else {
    $espSzMB = [math]::Round($esp.Size / 1MB, 1)
    Out-Line "ESP: disk $($esp.DiskNumber) part $($esp.PartitionNumber) size=${espSzMB}MB offset=$($esp.Offset)"
    Out-Line "ESP Guid: $($esp.Guid)" "OK"

    $espLetter = $esp.DriveLetter
    if (-not $espLetter) {
        try {
            Add-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction Stop
            $espLetter = "S"
            $assignedTemp = $true
            Out-Line "Assigned temp S: to ESP" "OK"
        } catch {
            Out-Line "Failed to assign S:: $($_.Exception.Message)" "ERR"
        }
    }

    if ($espLetter) {
        $espRoot = "${espLetter}:\"
        Out-Cmd "ESP file tree EFI\BOOT" {
            $b = Join-Path $espRoot "EFI\BOOT"
            if (Test-Path -LiteralPath $b) {
                Get-ChildItem -Path $b -Force -ErrorAction SilentlyContinue |
                    Select-Object Mode, Length, Name | Format-Table -AutoSize
            } else { "NOT FOUND: $b" }
        }
        $bcdPath = Join-Path $espRoot "EFI\Microsoft\Boot\BCD"
        if (Test-Path -LiteralPath $bcdPath) {
            $bcdSize = (Get-Item -Path $bcdPath).Length
            Out-Line "UEFI BCD: $bcdPath ($bcdSize bytes)" "OK"
        } else {
            Out-Line "UEFI BCD NOT FOUND at $bcdPath" "ERR"
        }
        $efiBoot = Join-Path $espRoot "EFI\Microsoft\Boot\bootmgfw.efi"
        if (Test-Path -LiteralPath $efiBoot) {
            $efiSz = (Get-Item -Path $efiBoot).Length
            Out-Line "bootmgfw.efi: $efiSz bytes" "OK"
        } else {
            Out-Line "bootmgfw.efi NOT FOUND" "ERR"
        }
        $fboot = Join-Path $espRoot "EFI\BOOT\BOOTX64.EFI"
        if (Test-Path -LiteralPath $fboot) {
            $fbSz = (Get-Item -Path $fboot).Length
            Out-Line "Fallback BOOTX64.EFI: $fbSz bytes" "OK"
        } else {
            Out-Line "Fallback BOOTX64.EFI: NOT FOUND" "WARN"
        }
        if ($assignedTemp) {
            try {
                Remove-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction Stop
                Out-Line "Removed temp S:" "OK"
            } catch {
                Out-Line "Failed to remove S:: $($_.Exception.Message)" "WARN"
            }
        }
    }
}

# =======================================================================
# §5 BOOT-CRITICAL SERVICES (Start=0)
# =======================================================================

Out-Section "5. BOOT-CRITICAL SERVICES (Start=0)"

Out-Cmd "All services with Start=0" {
    $root = "HKLM:\SYSTEM\CurrentControlSet\Services"
    $list = @()
    Get-ChildItem -Path $root -ErrorAction SilentlyContinue | ForEach-Object {
        $k = $_.PSPath
        $s = (Get-ItemProperty -Path $k -Name "Start" -ErrorAction SilentlyContinue).Start
        if ($s -eq 0) {
            $img = (Get-ItemProperty -Path $k -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
            $grp = (Get-ItemProperty -Path $k -Name "Group"     -ErrorAction SilentlyContinue).Group
            $tag = (Get-ItemProperty -Path $k -Name "Tag"       -ErrorAction SilentlyContinue).Tag
            $list += [PSCustomObject]@{ Name = $_.PSChildName; Group = $grp; Tag = $tag; Image = $img }
        }
    }
    $list = $list | Sort-Object Group, Name
    $list | Format-Table -AutoSize
    ""
    "Total Start=0 services: $($list.Count)"
}

# =======================================================================
# §6 CDDB
# =======================================================================

Out-Section "6. CRITICAL DEVICE DATABASE"

$cddb = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase"
if (Test-Path -LiteralPath $cddb) {
    $entries = Get-ChildItem -Path $cddb -ErrorAction SilentlyContinue
    Out-Line "Total entries: $($entries.Count)"
    foreach ($e in ($entries | Sort-Object PSChildName)) {
        $svc = (Get-ItemProperty -Path $e.PSPath -Name "Service"   -ErrorAction SilentlyContinue).Service
        $cls = (Get-ItemProperty -Path $e.PSPath -Name "ClassGUID" -ErrorAction SilentlyContinue).ClassGUID
        Out-Line "  $($e.PSChildName) => Service=$svc ClassGUID=$cls"
    }
} else {
    Out-Line "CDDB NOT FOUND (correct for KVM target)" "WARN"
}

# =======================================================================
# §7 VIOSCSI FULL DUMP
# =======================================================================

Out-Section "7. VIOSCSI SERVICE - FULL DUMP"

$vk = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
if (Test-Path -LiteralPath $vk) {
    Out-Cmd "Services\vioscsi (all properties)" {
        Get-ItemProperty -Path $vk -ErrorAction SilentlyContinue | Format-List *
    }
    Out-Cmd "Services\vioscsi\StartOverride" {
        $p = "$vk\StartOverride"
        if (Test-Path -LiteralPath $p) {
            "PRESENT:"
            $props = (Get-ItemProperty -Path $p -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
            foreach ($prop in $props) { "  $($prop.Name) = $($prop.Value)" }
        } else { "NOT PRESENT (correct)" }
    }
    Out-Cmd "Services\vioscsi\Parameters" {
        $p = "$vk\Parameters"
        if (Test-Path -LiteralPath $p) { Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Format-List * } else { "NOT FOUND" }
    }
    Out-Cmd "Services\vioscsi\Parameters\PnpInterface" {
        $p = "$vk\Parameters\PnpInterface"
        if (Test-Path -LiteralPath $p) { Get-ItemProperty -Path $p -ErrorAction SilentlyContinue | Format-List * } else { "NOT FOUND" }
    }
} else {
    Out-Line "vioscsi service NOT INSTALLED" "WARN"
}

# =======================================================================
# §8 ALL SCSIAdapter CLASS ENTRIES
# =======================================================================

Out-Section "8. SCSIAdapter CLASS ENTRIES"

Out-Cmd "All Class entries under SCSIAdapter" {
    $base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$SCSI_CLS"
    if (Test-Path -LiteralPath $base) {
        $entries = Get-ChildItem -Path $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }
        "Total entries: $($entries.Count)"
        foreach ($e in ($entries | Sort-Object PSChildName)) {
            $props = Get-ItemProperty -Path $e.PSPath -ErrorAction SilentlyContinue
            "=== Class index: $($e.PSChildName) ==="
            "  DriverDesc:       $($props.DriverDesc)"
            "  InfPath:          $($props.InfPath)"
            "  MatchingDeviceId: $($props.MatchingDeviceId)"
            "  DriverVersion:    $($props.DriverVersion)"
        }
    } else {
        "SCSIAdapter class key NOT FOUND"
    }
}

# =======================================================================
# §9 ALL VEN_1AF4 DEVNODES
# =======================================================================

Out-Section "9. ENUM\PCI - VEN_1AF4 DEVNODES"

Out-Cmd "All VEN_1AF4 devnodes" {
    $enum = "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI"
    if (Test-Path -LiteralPath $enum) {
        $found = Get-ChildItem -Path $enum -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match 'VEN_1AF4' }
        "Total device families: $($found.Count)"
        foreach ($fam in $found) {
            "=== $($fam.PSChildName) ==="
            $instances = Get-ChildItem -Path $fam.PSPath -ErrorAction SilentlyContinue
            foreach ($inst in $instances) {
                $dev = Get-ItemProperty -Path $inst.PSPath -ErrorAction SilentlyContinue
                "  Instance: $($inst.PSChildName)"
                "    Service:    $($dev.Service)"
                "    ClassGUID:  $($dev.ClassGUID)"
                "    Driver:     $($dev.Driver)"
                "    ConfigFlags:$($dev.ConfigFlags)"
            }
        }
    } else {
        "Enum\PCI NOT FOUND"
    }
}

# =======================================================================
# §10 PNP LIVE VIEW VEN_1AF4
# =======================================================================

Out-Section "10. PNP LIVE VIEW - VEN_1AF4"

Out-Cmd "Get-PnpDevice -PresentOnly" {
    $devs = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -match 'VEN_1AF4' }
    if ($devs) {
        foreach ($d in $devs) {
            "$($d.Status) | $($d.Class) | $($d.InstanceId)"
        }
    } else { "No VEN_1AF4 devices present" }
}

# =======================================================================
# §11 LEGACY DRIVERS + StartOverride
# =======================================================================

Out-Section "11. LEGACY DRIVERS + StartOverride"

$legacyList = @("viostor","stornvme","lsi_sas","lsi_sas2i","lsi_sas3i","megasr","pvscsi","vmw_pvscsi","pciide","intelide","atapi","vmbus","storahci")
Out-Cmd "Legacy drivers state" {
    foreach ($s in $legacyList) {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
        if (Test-Path -LiteralPath $k) {
            $start = (Get-ItemProperty -Path $k -Name "Start" -ErrorAction SilentlyContinue).Start
            $ovrKey = "$k\StartOverride"
            $ovrStr = "(none)"
            if (Test-Path -LiteralPath $ovrKey) {
                $props = (Get-ItemProperty -Path $ovrKey -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { $_.Name -notmatch '^PS' }
                $vals = @()
                foreach ($p in $props) { $vals += "$($p.Name)=$($p.Value)" }
                if ($vals.Count -gt 0) { $ovrStr = $vals -join "," }
            }
            "  {0,-14} Start={1,-3} StartOverride: {2}" -f $s, $start, $ovrStr
        } else {
            "  {0,-14} not present" -f $s
        }
    }
}

# =======================================================================
# §12 TIME / RTC / BOOT FLAGS
# =======================================================================

Out-Section "12. TIME / RTC / BOOT FLAGS"

Out-Cmd "RealTimeIsUniversal" {
    $v = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" -Name "RealTimeIsUniversal" -ErrorAction SilentlyContinue).RealTimeIsUniversal
    if ($null -eq $v) { "(not set)" } else { "RealTimeIsUniversal = $v" }
}
Out-Cmd "TimeZone" { (Get-TimeZone -ErrorAction SilentlyContinue).Id }
Out-Cmd "Local vs UTC" {
    $now = Get-Date
    "Local: $($now.ToString('yyyy-MM-dd HH:mm:ss'))"
    "UTC:   $($now.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss'))"
}
Out-Cmd "BootDriverFlags" {
    $v = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "BootDriverFlags" -ErrorAction SilentlyContinue).BootDriverFlags
    if ($null -eq $v) { "(not set, default 0)" } else { "BootDriverFlags = $v" }
}

# =======================================================================
# §13 BOOTLOADER FILES
# =======================================================================

Out-Section "13. BOOTLOADER FILES"

Out-Cmd "Critical boot files" {
    $files = @(
        "C:\Windows\System32\winload.efi",
        "C:\Windows\System32\ntoskrnl.exe",
        "C:\Windows\System32\drivers\vioscsi.sys",
        "C:\Windows\System32\drivers\storahci.sys",
        "C:\Windows\System32\drivers\disk.sys",
        "C:\Windows\System32\drivers\partmgr.sys",
        "C:\Windows\System32\drivers\volmgr.sys",
        "C:\Windows\System32\drivers\storport.sys"
    )
    foreach ($f in $files) {
        if (Test-Path -LiteralPath $f) {
            $sz = (Get-Item -LiteralPath $f).Length
            "  [+] $f ($sz bytes)"
        } else {
            "  [-] $f MISSING"
        }
    }
}

# =======================================================================
# §14 COMPARISON vs REFERENCE KVM
# =======================================================================

Out-Section "14. COMPARISON vs REFERENCE KVM"

$refTag       = 64
$refDma       = 0
$refBusType   = 10
$refPnp5      = 1
$refRealTime  = 1
$refBDF       = 28

$vioscsiKey = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
$paramKey   = "$vioscsiKey\Parameters"
$pnpKey     = "$paramKey\PnpInterface"

$ourTag       = $null
$ourDma       = $null
$ourBusType   = $null
$ourPnp5      = $null
$ourRealTime  = $null
$ourBDF       = $null
$ourImgPath   = $null

if (Test-Path -LiteralPath $vioscsiKey) {
    $ourTag     = (Get-ItemProperty -Path $vioscsiKey -Name "Tag"       -ErrorAction SilentlyContinue).Tag
    $ourImgPath = (Get-ItemProperty -Path $vioscsiKey -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
}
if (Test-Path -LiteralPath $paramKey) {
    $ourDma     = (Get-ItemProperty -Path $paramKey -Name "DmaRemappingCompatible" -ErrorAction SilentlyContinue).DmaRemappingCompatible
    $ourBusType = (Get-ItemProperty -Path $paramKey -Name "BusType"                 -ErrorAction SilentlyContinue).BusType
}
if (Test-Path -LiteralPath $pnpKey) {
    $ourPnp5    = (Get-ItemProperty -Path $pnpKey -Name "5" -ErrorAction SilentlyContinue)."5"
}

$ourRealTime = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" -Name "RealTimeIsUniversal" -ErrorAction SilentlyContinue).RealTimeIsUniversal
$ourBDF      = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "BootDriverFlags" -ErrorAction SilentlyContinue).BootDriverFlags

$enumCount  = (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match "VEN_1AF4" }).Count
$classCount = (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$SCSI_CLS" -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' }).Count

$cddbPath   = "HKLM:\SYSTEM\CurrentControlSet\Control\CriticalDeviceDatabase\pci#ven_1af4" + $AMP + "dev_1004"
$cddbExists = Test-Path -LiteralPath $cddbPath
$cddbState  = "absent"
if ($cddbExists) { $cddbState = "present" }

$s1 = Get-MatchStatus -Ref $refTag      -Ours $ourTag
$s2 = Get-MatchStatus -Ref $refDma      -Ours $ourDma
$s3 = Get-MatchStatus -Ref $refBusType  -Ours $ourBusType
$s4 = Get-MatchStatus -Ref $refPnp5     -Ours $ourPnp5
$s5 = Get-MatchStatus -Ref 1            -Ours $enumCount  -CheckType "ge"
$s6 = Get-MatchStatus -Ref 1            -Ours $classCount -CheckType "ge"
$s7 = Get-MatchStatus -Ref $refRealTime -Ours $ourRealTime
$s8 = Get-MatchStatus -Ref $refBDF      -Ours $ourBDF
if ($cddbExists) { $s9 = "DIFF" } else { $s9 = "OK" }

Out-Line ""
Out-Line "  Parameter                          | Reference    | Ours         | Match"
Out-Line "  -----------------------------------|--------------|--------------|------"
Out-Line ("  vioscsi Tag                        | {0,-12} | {1,-12} | {2}" -f $refTag,       "$ourTag",       $s1)
Out-Line ("  DmaRemappingCompatible             | {0,-12} | {1,-12} | {2}" -f $refDma,       "$ourDma",       $s2)
Out-Line ("  BusType                            | {0,-12} | {1,-12} | {2}" -f $refBusType,   "$ourBusType",   $s3)
Out-Line ("  PnpInterface\5                     | {0,-12} | {1,-12} | {2}" -f $refPnp5,      "$ourPnp5",      $s4)
Out-Line ("  Enum\PCI VEN_1AF4 count            | >={0,-10} | {1,-12} | {2}" -f 1,            "$enumCount",    $s5)
Out-Line ("  SCSIAdapter Class count            | >={0,-10} | {1,-12} | {2}" -f 1,            "$classCount",   $s6)
Out-Line ("  RealTimeIsUniversal                | {0,-12} | {1,-12} | {2}" -f $refRealTime, "$ourRealTime",  $s7)
Out-Line ("  BootDriverFlags                    | {0,-12} | {1,-12} | {2}" -f $refBDF,       "$ourBDF",       $s8)
Out-Line ("  CDDB pci#ven_1af4&dev_1004         | {0,-12} | {1,-12} | {2}" -f "absent",      $cddbState,      $s9)
Out-Line ""
Out-Line "  ImagePath: $ourImgPath"
Out-Line "  Note: N/A = pre-migration state (vioscsi not installed yet)"

# =======================================================================
# §15 VERDICT
# =======================================================================

Out-Section "15. VERDICT"

$issues = @()
$ok     = @()

if ($state.DiskStyle)              { $ok     += "Disk 0: $($state.DiskStyle)" }
if ($state.DiskStyle -eq 'GPT' -and -not $state.HasESP) { $issues += "GPT disk without ESP" }
if ($state.HasESP)                 { $ok     += "ESP present" }
if ($state.Blocker)                { $issues += "Blocker: $($state.Blocker)" }

if ($state.VioscsiReady)           { $ok     += "vioscsi ready (Tag=64)" }
elseif ($ourTag)                   { $issues += "vioscsi Tag=$ourTag (expected 64)" }

if ($state.DevnodeReady)           { $ok     += "devnode present (Service=vioscsi)" }
elseif ($ourTag)                   { $issues += "devnode missing (VirtIO SCSI)" }

if ($state.BootReady)              { $ok     += "UEFI BCD + bootmgfw.efi present" }
elseif ($state.DiskStyle -eq 'GPT'){ $issues += "UEFI BCD incomplete" }

if ($state.HasBitLocker)           { $issues += "BitLocker active" }
if ($state.IsDynamic)              { $issues += "Dynamic disk" }
if ($state.OOBE)                   { $issues += "System in OOBE" }
if ($state.PendingReboot)          { $issues += "Pending reboot" }
if ($state.FreeSpaceGB -lt 2)      { $issues += "Free space < 2 GB" }
if ($state.FileSystem -and $state.FileSystem -ne 'NTFS') { $issues += "File system is $($state.FileSystem)" }

if ($ourRealTime -eq 1)            { $ok     += "RealTimeIsUniversal=1" }
if ($ourBDF -eq 28)                { $ok     += "BootDriverFlags=28" }
if (-not $cddbExists)              { $ok     += "CDDB absent (matches reference)" }

Out-Line ""
Out-Line "---- PROBLEMS ----"
if ($issues.Count -eq 0) {
    Out-Line "  None." "OK"
} else {
    foreach ($i in $issues) { Out-Line "  [!] $i" "WARN" }
}

Out-Line ""
Out-Line "---- OK ----"
foreach ($o in $ok) { Out-Line "  [+] $o" "OK" }

# =======================================================================
# COMPLETE
# =======================================================================

Out-Section "COMPLETE"
Out-Line "Report: $ReportFile"

Write-Host ""
Write-Host "3-Diagnostic.ps1 v$SCRIPT_VERSION complete." -ForegroundColor Green
Write-Host "Report: $ReportFile" -ForegroundColor Green
Write-Host ""
Write-Host "Press Enter to close..." -NoNewline
Read-Host | Out-Null