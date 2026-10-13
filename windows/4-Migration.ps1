# =======================================================================
# FILE: 4-Migration.ps1
# VERSION: 4.1
# =======================================================================
# Transformation for migration-to-mws.
#
# Order of steps:
#   STEP 0    Preflight + Get-MigrationState
#   STEP 1    Free space check
#   STEP 2    Disable services + tuning
#   STEP 3    Install VirtIO drivers (idempotent)
#   STEP 3.5  vioscsi service registration (Tag=64, Dma=0)
#   STEP 3.5b Create devnode in Enum\PCI (ACL takeover)
#   STEP 3.6  storahci + legacy drivers
#   STEP 4    Remove Extended partition (MBR only)
#   STEP 5    BCD cleanup (MBR only)
#   STEP 6    mbr2gpt convert (MBR only)
#   STEP 6.5  Remove orphan SR (MBR only)
#   STEP 6.6  Rebuild UEFI BCD
#   STEP 7    KVM/UEFI patches
#   STEP 8    Network reset
#   STEP 9    Final verification
#   STEP 10   Cleanup & shutdown
#
# Universal PowerShell 5.1 (Windows Server 2019-2025).
# ASCII-only. No here-strings.
# =======================================================================

$SCRIPT_VERSION = "4.1"
$ErrorActionPreference = "Stop"

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
$Global:LogPath  = Join-Path $Global:LogDir ("4-Migration_v{0}_{1}_{2}.log" -f $SCRIPT_VERSION, $Global:Timestamp, $Global:Hostname)

$Global:SystemDisk = $null
$Global:State      = $null

$SCSI_CLS     = "{4d36e97b-e325-11ce-bfc1-08002be10318}"
$ESP_GPT_TYPE = "{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}"

# Ampersand-safe constants
$AMP = [char]38
$PCI_FAMILY   = "VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "SUBSYS_00081AF4" + $AMP + "REV_00"
$VEN_PCI_BASE = "HKLM:\SYSTEM\CurrentControlSet\Enum\PCI\" + $PCI_FAMILY
$DEVNODE_PATH = $VEN_PCI_BASE + "\4" + $AMP + "1c6c80be" + $AMP + "0" + $AMP + "0018"
$REG_DEVNODE  = "HKLM\SYSTEM\CurrentControlSet\Enum\PCI\" + $PCI_FAMILY

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

function Write-Skip {
    param([string]$Step, [string]$Reason)
    Write-Log ("{0} SKIPPED: {1}" -f $Step, $Reason) -Level Skip
}

# =======================================================================
# HELPERS
# =======================================================================

function Remove-RegKeySafe {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $deleted = $false
    if ($Path -match '^HKLM:\\') {
        $regPath = 'HKLM\' + $Path.Substring(6)
        $null = & reg.exe delete $regPath /f 2>&1
        if ($LASTEXITCODE -eq 0) { $deleted = $true }
    } elseif ($Path -match '^HKCU:\\') {
        $regPath = 'HKCU\' + $Path.Substring(6)
        $null = & reg.exe delete $regPath /f 2>&1
        if ($LASTEXITCODE -eq 0) { $deleted = $true }
    }
    if (-not $deleted) {
        try { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Get-SystemDiskNumber {
    $sysLetter = $env:SystemDrive.Replace(":", "")
    $sysPart = Get-Partition -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -eq $sysLetter } | Select-Object -First 1
    if (-not $sysPart) { return $null }
    return $sysPart.DiskNumber
}

function Assert-SystemDisk {
    if ($null -ne $Global:SystemDisk -and $null -ne $Global:SystemDisk.Number) { return $true }
    $dn = Get-SystemDiskNumber
    if ($null -eq $dn) {
        Write-Log "Cannot determine system disk" -Level Error
        return $false
    }
    $Global:SystemDisk = Get-Disk -Number $dn -ErrorAction SilentlyContinue
    if ($null -eq $Global:SystemDisk) {
        Write-Log "Get-Disk returned null" -Level Error
        return $false
    }
    return $true
}

function Test-UrlReachable {
    param([string]$Url)
    try {
        $hostName = ([Uri]$Url).Host
        return [bool](Test-NetConnection -ComputerName $hostName -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue)
    } catch { return $false }
}

# =======================================================================
# STATE DETECTION
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
# STEP 3.5b HELPER: create devnode in Enum\PCI
# =======================================================================

function Invoke-CreateDevnode {
    param([string]$InfName)

    Write-Section "STEP 3.5b. CREATE DEVNODE (Enum\PCI)"

    $instancePath = $DEVNODE_PATH

    if (-not (Test-Path -LiteralPath $instancePath)) {
        try {
            New-Item -Path $instancePath -Force -ErrorAction Stop | Out-Null
            Write-Log "Devnode key created" -Level Info
        } catch {
            Write-Log "WARNING: cannot create devnode key: $($_.Exception.Message)" -Level Warning
            Write-Log "Skipping devnode (non-critical, continuing)" -Level Warning
            return
        }
    } else {
        Write-Log "Devnode key already exists" -Level Info
    }

    try {
        $regSubPath = "SYSTEM\CurrentControlSet\Enum\PCI\" + $PCI_FAMILY
        $regKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey(
            $regSubPath,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [System.Security.AccessControl.RegistryRights]::TakeOwnership)
        if ($regKey) {
            $acl = $regKey.GetAccessControl([System.Security.AccessControl.AccessControlSections]::All)
            $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
                $currentUser, "FullControl", "ContainerInherit", "None", "Allow")
            $acl.SetAccessRule($rule)
            $regKey.SetAccessControl($acl)
            $regKey.Close()
            Write-Log "ACL takeover: granted FullControl to $currentUser" -Level Success
        } else {
            Write-Log "WARNING: cannot open devnode key for ownership" -Level Warning
        }
    } catch {
        Write-Log "WARNING: ACL takeover failed: $($_.Exception.Message)" -Level Warning
        Write-Log "Continuing with best-effort devnode population" -Level Warning
    }

    try {
        New-ItemProperty -Path $instancePath -Name "Service"      -Value "vioscsi"        -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $instancePath -Name "ClassGUID"    -Value $SCSI_CLS        -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $instancePath -Name "Driver"       -Value "$SCSI_CLS\0000" -PropertyType String -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $instancePath -Name "ConfigFlags"  -Value 0                -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $instancePath -Name "Capabilities" -Value 0                -PropertyType DWord  -Force -ErrorAction Stop | Out-Null
        New-ItemProperty -Path $instancePath -Name "ContainerID"  -Value "{00000000-0000-0000-ffff-ffffffffffff}" -PropertyType String -Force -ErrorAction Stop | Out-Null
        $devDesc = "@$InfName,%virtioscsi.devicedesc%;Red Hat VirtIO SCSI pass-through controller"
        New-ItemProperty -Path $instancePath -Name "DeviceDesc"   -Value $devDesc          -PropertyType String -Force -ErrorAction Stop | Out-Null
        Write-Log "Scalar properties written" -Level Success
    } catch {
        Write-Log "WARNING: scalar properties write failed: $($_.Exception.Message)" -Level Warning
    }

    $hwIds = @(
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "SUBSYS_00081AF4" + $AMP + "REV_00"),
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "SUBSYS_00081AF4"),
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "CC_010000"),
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "CC_0100"),
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004"),
        ("PCI\VEN_1AF4" + $AMP + "CC_010000"),
        ("PCI\VEN_1AF4" + $AMP + "CC_0100"),
        "PCI\VEN_1AF4",
        "PCI\CC_010000",
        "PCI\CC_0100"
    )
    $cmpIds = @(
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "REV_00"),
        ("PCI\VEN_1AF4" + $AMP + "DEV_1004"),
        ("PCI\VEN_1AF4" + $AMP + "CC_010000"),
        ("PCI\VEN_1AF4" + $AMP + "CC_0100"),
        "PCI\VEN_1AF4",
        "PCI\CC_010000",
        "PCI\CC_0100"
    )

    $multiOK = $false
    try {
        $key = Get-Item -LiteralPath $instancePath -ErrorAction Stop
        $key.SetValue("HardwareID",    [string[]]$hwIds,  [Microsoft.Win32.RegistryValueKind]::MultiString)
        $key.SetValue("CompatibleIDs", [string[]]$cmpIds, [Microsoft.Win32.RegistryValueKind]::MultiString)
        $multiOK = $true
        Write-Log "MultiString properties written" -Level Success
    } catch {
        Write-Log "WARNING: MultiString write via .NET failed: $($_.Exception.Message)" -Level Warning
    }

    if (-not $multiOK) {
        try {
            $hwStr  = $hwIds  -join '\0'
            $cmpStr = $cmpIds -join '\0'
            $null = & reg.exe add $REG_DEVNODE /v HardwareID    /t REG_MULTI_SZ /d "$hwStr"  /f 2>&1
            $null = & reg.exe add $REG_DEVNODE /v CompatibleIDs /t REG_MULTI_SZ /d "$cmpStr" /f 2>&1
            if ($LASTEXITCODE -eq 0) {
                $multiOK = $true
                Write-Log "MultiString written via reg.exe fallback" -Level Success
            } else {
                Write-Log "WARNING: reg.exe fallback exit code $LASTEXITCODE" -Level Warning
            }
        } catch {
            Write-Log "WARNING: reg.exe fallback failed: $($_.Exception.Message)" -Level Warning
        }
    }

    foreach ($sub in @("Device Parameters", "LogConf", "Properties")) {
        $p = "$instancePath\$sub"
        try {
            if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force -ErrorAction Stop | Out-Null }
        } catch {
            Write-Log "WARNING: cannot create subkey $sub : $($_.Exception.Message)" -Level Warning
        }
    }

    try {
        $props = Get-ItemProperty -Path $instancePath -ErrorAction SilentlyContinue
        if ($props -and $props.Service -eq "vioscsi") {
            Write-Log "VERIFIED: devnode has Service=vioscsi" -Level Success
        } else {
            Write-Log "WARNING: devnode verification failed (Service missing)" -Level Warning
        }
    } catch {
        Write-Log "WARNING: verification failed: $($_.Exception.Message)" -Level Warning
    }

    Write-Log "Devnode step completed" -Level Info
}

# =======================================================================
# STEP 4 HELPER: remove Extended partition
# =======================================================================

function Invoke-RemoveExtendedPartitions {
    param([int]$DiskNum)

    Write-Section "STEP 4. REMOVE EXTENDED PARTITIONS"
    Update-HostStorageCache -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $allParts = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue
    if (-not $allParts) { Write-Log "Cannot query partitions" -Level Error; return }

    $ext = $allParts | Where-Object { $_.Type -eq 'Extended' } | Select-Object -First 1
    if (-not $ext) { Write-Log "No Extended partition found" -Level Info; return }

    Write-Log "Extended partition #$($ext.PartitionNumber) detected" -Level Info

    $extStart = $ext.Offset
    $extEnd   = $ext.Offset + $ext.Size

    $children = $allParts | Where-Object {
        $_.PartitionNumber -ne $ext.PartitionNumber -and
        $_.Offset -ge $extStart -and
        ($_.Offset + $_.Size) -le $extEnd
    }

    foreach ($child in ($children | Sort-Object Offset -Descending)) {
        Write-Log "Deleting child #$($child.PartitionNumber)..." -Level Action
        $success = $false
        try {
            Remove-Partition -DiskNumber $DiskNum -PartitionNumber $child.PartitionNumber -Confirm:$false -ErrorAction Stop
            $success = $true
        } catch {
            Write-Log "  Remove-Partition failed: $($_.Exception.Message)" -Level Warning
        }
        if (-not $success) {
            $dp = "select disk $DiskNum`r`nselect partition $($child.PartitionNumber)`r`ndelete partition override`r`nexit"
            $dp | diskpart.exe 2>&1 | Out-Null
        }
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    Write-Log "Deleting Extended container..." -Level Action
    try {
        Remove-Partition -DiskNumber $DiskNum -PartitionNumber $ext.PartitionNumber -Confirm:$false -ErrorAction Stop
    } catch {
        "select disk $DiskNum`r`nselect partition 0`r`ndelete partition override`r`nexit" | diskpart.exe 2>&1 | Out-Null
    }
    Update-HostStorageCache -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $stillThere = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue | Where-Object { $_.Type -eq 'Extended' }
    if ($stillThere) { throw "Extended partition still present" }
    Write-Log "Extended removed" -Level Success
}

# =======================================================================
# STEP 6.5 HELPER: remove orphan SR
# =======================================================================

function Invoke-RemoveOrphanSR {
    param([int]$DiskNum)

    Write-Section "STEP 6.5. REMOVE ORPHAN SR PARTITION"
    Update-HostStorageCache -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    $parts = Get-Partition -DiskNumber $DiskNum -ErrorAction SilentlyContinue
    if (-not $parts) { return }

    $orphan = $parts | Where-Object {
        $_.Type -eq 'Basic' -and
        $_.Size -lt 1GB -and
        -not $_.DriveLetter -and
        -not $_.IsBoot -and
        -not $_.IsSystem -and
        ($_.GptType -eq "{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}" -or $_.GptType -eq $null -or $_.GptType -eq "")
    } | Sort-Object Offset | Select-Object -First 1

    if (-not $orphan) { Write-Log "No orphan SR found" -Level Info; return }

    Write-Log "Orphan SR: #$($orphan.PartitionNumber)" -Level Warning

    if ($orphan.DriveLetter) {
        Remove-PartitionAccessPath -DiskNumber $DiskNum -PartitionNumber $orphan.PartitionNumber -AccessPath "$($orphan.DriveLetter):\" -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    }

    try {
        Remove-Partition -DiskNumber $DiskNum -PartitionNumber $orphan.PartitionNumber -Confirm:$false -ErrorAction Stop
        Write-Log "Orphan SR removed" -Level Success
    } catch {
        $dp = "select disk $DiskNum`r`nselect partition $($orphan.PartitionNumber)`r`ndelete partition override`r`nexit"
        $dp | diskpart.exe 2>&1 | Out-Null
    }
    Update-HostStorageCache -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
}

# =======================================================================
# MAIN PIPELINE
# =======================================================================

Write-Log "=== 4-Migration.ps1 v$SCRIPT_VERSION ==="
Write-Log "Log file: $Global:LogPath"

try {
    # -------------------------------------------------------------------
    # STEP 0: PREFLIGHT + STATE
    # -------------------------------------------------------------------
    Write-Section "STEP 0. PREFLIGHT"

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw "Not running as Administrator!" }
    Write-Log "Admin Rights: OK" -Level Success

    $osInfo  = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $osBuild = [int]$osInfo.BuildNumber
    Write-Log "OS: $($osInfo.Caption) (Build $osBuild)" -Level Info
    if ($osBuild -lt 17763) {
        throw "UNSUPPORTED OS. Server 2019+ required (current build $osBuild)."
    }

    $mbr2gptPath = "$env:SystemRoot\System32\mbr2gpt.exe"
    if (-not (Test-Path -LiteralPath $mbr2gptPath)) {
        throw "mbr2gpt.exe NOT FOUND. Server 2019+ is required."
    }
    Write-Log "mbr2gpt.exe: found" -Level Success

    if (-not (Assert-SystemDisk)) { throw "Failed to determine system disk" }
    $Global:State = Get-MigrationState -DiskNumber $Global:SystemDisk.Number

    Write-Log "Detected state:" -Level Info
    Write-Log ("  Disk style : {0}" -f $Global:State.DiskStyle) -Level Info
    Write-Log ("  Firmware   : {0}" -f $Global:State.Firmware) -Level Info
    Write-Log ("  Environment: {0}" -f $Global:State.Environment) -Level Info
    Write-Log ("  FS         : {0}" -f $Global:State.FileSystem) -Level Info
    Write-Log ("  Free space : {0} GB" -f $Global:State.FreeSpaceGB) -Level Info

    if ($Global:State.Blocker) {
        throw "Migration blocked: $($Global:State.Blocker). See orchestrator output for details."
    }

    if ($Global:State.Issues.Count -gt 0) {
        foreach ($issue in $Global:State.Issues) {
            Write-Log "  ISSUE: $issue" -Level Warning
        }
    }

    # -------------------------------------------------------------------
    # STEP 1: FREE SPACE
    # -------------------------------------------------------------------
    Write-Section "STEP 1. FREE SPACE CHECK"
    Write-Log ("Free space: {0} GB" -f $Global:State.FreeSpaceGB) -Level Success
    if ($Global:State.FreeSpaceGB -lt 2) { throw "Not enough free space (< 2 GB)" }

    # -------------------------------------------------------------------
    # STEP 2: DISABLE SERVICES + TUNING
    # -------------------------------------------------------------------
    Write-Section "STEP 2. DISABLE SERVICES / DEFENDER / IE ESC / TUNING"

    $guids = @("{A509B1A7-37EF-4b3f-8CFC-4F3A74704073}", "{A509B1A8-37EF-4b3f-8CFC-4F3A74704073}")
    foreach ($g in $guids) {
        $p = "HKLM:\SOFTWARE\Microsoft\Active Setup\Installed Components\$g"
        if (-not (Test-Path -LiteralPath $p)) { New-Item -Path $p -Force | Out-Null }
        Set-ItemProperty -Path $p -Name "IsInstalled" -Value 0 -Type DWord -ErrorAction SilentlyContinue
    }
    Write-Log "IE ESC: disabled" -Level Success

    $wu = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    if (-not (Test-Path -LiteralPath $wu)) { New-Item -Path $wu -Force | Out-Null }
    Set-ItemProperty -Path $wu -Name "NoAutoUpdate" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Log "Windows Update: disabled" -Level Success

    try {
        Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction Stop
        Write-Log "Defender RTP: disabled" -Level Success
    } catch {
        Write-Log "Defender RTP disable skipped: $_" -Level Warning
    }

    try {
        & powercfg.exe /setactive "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" 2>&1 | Out-Null
        & powercfg.exe /change -monitor-timeout-ac 0 2>&1 | Out-Null
        & powercfg.exe /change -standby-timeout-ac 0 2>&1 | Out-Null
        & powercfg.exe /change -hibernate-timeout-ac 0 2>&1 | Out-Null
        Write-Log "Power plan: High Performance, timeouts disabled" -Level Success
    } catch { Write-Log "Power plan skipped: $_" -Level Warning }

    try {
        Get-ScheduledTask -TaskName "ScheduledDefrag" -ErrorAction SilentlyContinue |
            Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
        Write-Log "ScheduledDefrag: disabled" -Level Success
    } catch { Write-Log "ScheduledDefrag skipped: $_" -Level Warning }

    try {
        Disable-ComputerRestore -Drive "C:\" -ErrorAction SilentlyContinue
        Write-Log "System Restore: disabled on C:" -Level Success
    } catch { Write-Log "System Restore skipped: $_" -Level Warning }

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ShutdownWithoutLogon" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ShutdownWarningDialogTimeout" -Value 1 -ErrorAction SilentlyContinue

    # -------------------------------------------------------------------
    # STEP 3: INSTALL VIRTIO
    # -------------------------------------------------------------------
    Write-Section "STEP 3. INSTALL VIRTIO DRIVERS"

    $tools = "$env:TEMP\virtio-win-guest-tools.exe"
    $local = Join-Path $Global:ToolsDir "virtio-win-guest-tools.exe"
    $url   = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/latest-virtio/virtio-win-guest-tools.exe"

    if (Test-Path -LiteralPath $local) {
        Write-Log "Found local installer: $local" -Level Success
        Copy-Item -Path $local -Destination $tools -Force
    } else {
        Write-Log "Local installer not found in tools\, will download" -Level Info
        if (-not (Test-UrlReachable -Url $url)) {
            throw "Cannot reach $url. Place virtio-win-guest-tools.exe in tools\ and re-run."
        }
        Write-Log "Downloading VirtIO Guest Tools..." -Level Action
        try {
            Invoke-WebRequest -Uri $url -OutFile $tools -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
            Write-Log "Downloaded." -Level Success
        } catch {
            throw "Failed to download VirtIO: $_"
        }
    }

    Write-Log "Running MSI installer..." -Level Action
    $p = Start-Process -FilePath $tools -ArgumentList "/silent /norestart" -Wait -NoNewWindow -PassThru
    Write-Log "MSI exit code: $($p.ExitCode)" -Level Success

    $vDirs = @("$env:ProgramFiles\VirtIO-Win", "${env:ProgramFiles(x86)}\VirtIO-Win")
    foreach ($d in $vDirs) {
        if (Test-Path -LiteralPath $d) {
            & dism.exe /Online /Add-Driver /Driver:"$d" /Recurse /Quiet /NoRestart 2>&1 | Out-Null
        }
    }
    Write-Log "DISM injection complete" -Level Success

    # -------------------------------------------------------------------
    # STEP 3.5: VIOSCSI FULL REGISTRATION
    # -------------------------------------------------------------------
    Write-Section "STEP 3.5. VIOSCSI FULL REGISTRATION"

    $dsRoot = "$env:SystemRoot\System32\DriverStore\FileRepository"
    $vFolder = Get-ChildItem -Path $dsRoot -Directory -Filter "vioscsi.inf_amd64_*" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $vFolder) { throw "vioscsi driver folder not found in DriverStore" }
    $sysPath = "System32\DriverStore\FileRepository\$($vFolder.Name)\vioscsi.sys"
    Write-Log "DriverStore: $($vFolder.Name)" -Level Success

    $winInf = Join-Path $env:SystemRoot 'INF'
    $oem = Get-ChildItem $winInf -Filter 'oem*.inf' -ErrorAction SilentlyContinue |
        Where-Object { Select-String -Path $_.FullName -Pattern 'vioscsi\.sys' -Quiet } |
        Select-Object -First 1
    if (-not $oem) { throw "oem-INF for vioscsi not found in $winInf" }
    $oemName = $oem.Name
    Write-Log "InfPath: $oemName" -Level Success

    $ver = (Select-String -Path $oem.FullName -Pattern '^\s*DriverVer\s*=\s*(.+)$' -ErrorAction SilentlyContinue |
        Select-Object -First 1).Matches[0].Groups[1].Value.Trim()
    $dvDate, $dvVer = $ver -split '\s*,\s*'
    $d = [datetime]::ParseExact($dvDate, 'MM/dd/yyyy', $null)
    $driverDate = '{0}-{1}-{2}' -f $d.Month, $d.Day, $d.Year
    $driverDateData = $d.ToFileTimeUtc()
    Write-Log "DriverVer: $driverDate / $dvVer" -Level Success

    $vioscsiKey = "HKLM:\SYSTEM\CurrentControlSet\Services\vioscsi"
    if (-not (Test-Path -LiteralPath $vioscsiKey)) { New-Item -Path $vioscsiKey -Force | Out-Null }
    Remove-RegKeySafe -Path "$vioscsiKey\StartOverride"

    Set-ItemProperty -Path $vioscsiKey -Name "Start"        -Value 0             -Type DWord        -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "Type"         -Value 1             -Type DWord        -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "ErrorControl" -Value 1             -Type DWord        -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "Group"        -Value "SCSI miniport" -Type String      -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "ImagePath"    -Value $sysPath       -Type ExpandString -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "Tag"          -Value 64            -Type DWord        -ErrorAction SilentlyContinue
    Write-Log "Tag = 64" -Level Success

    $displayName = "@$oemName,%VirtioScsi.SVCDESC%;Red Hat VirtIO SCSI pass-through Service"
    Set-ItemProperty -Path $vioscsiKey -Name "DisplayName" -Value $displayName -Type String      -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $vioscsiKey -Name "Owners"      -Value @($oemName)   -Type MultiString -ErrorAction SilentlyContinue
    Write-Log "DisplayName / Owners set" -Level Success

    $paramKey = "$vioscsiKey\Parameters"
    if (-not (Test-Path -LiteralPath $paramKey)) { New-Item -Path $paramKey -Force | Out-Null }
    Set-ItemProperty -Path $paramKey -Name "BusType"                 -Value 10 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $paramKey -Name "DmaRemappingCompatible"  -Value 0  -Type DWord -ErrorAction SilentlyContinue
    Write-Log "DmaRemappingCompatible = 0" -Level Success

    $pnpKey = "$paramKey\PnpInterface"
    if (-not (Test-Path -LiteralPath $pnpKey)) { New-Item -Path $pnpKey -Force | Out-Null }
    Set-ItemProperty -Path $pnpKey -Name "5" -Value 1 -Type DWord -ErrorAction SilentlyContinue

    $verifyImg = (Get-ItemProperty -Path $vioscsiKey -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
    $verifyTag = (Get-ItemProperty -Path $vioscsiKey -Name "Tag"       -ErrorAction SilentlyContinue).Tag
    if ($verifyImg) {
        Write-Log "VERIFIED: vioscsi ImagePath = $verifyImg" -Level Success
        Write-Log "VERIFIED: vioscsi Tag = $verifyTag"       -Level Success
    } else {
        throw "vioscsi ImagePath not verified"
    }

    $classBase = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\$SCSI_CLS"
    if (-not (Test-Path -LiteralPath $classBase)) { New-Item -Path $classBase -Force | Out-Null }
    $classKey = "$classBase\0000"
    if (-not (Test-Path -LiteralPath $classKey)) { New-Item -Path $classKey -Force | Out-Null }

    $hwTop = "PCI\VEN_1AF4" + $AMP + "DEV_1004" + $AMP + "SUBSYS_00081AF4" + $AMP + "REV_00"
    Set-ItemProperty -Path $classKey -Name 'DriverDesc'        -Value 'Red Hat VirtIO SCSI pass-through controller' -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'InfPath'           -Value $oemName       -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'InfSection'        -Value 'scsi_inst'    -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'ProviderName'      -Value 'Red Hat, Inc.' -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'MatchingDeviceId'  -Value $hwTop         -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'DriverDate'        -Value $driverDate   -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'DriverDateData'    -Value ([BitConverter]::GetBytes($driverDateData)) -Type Binary -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $classKey -Name 'DriverVersion'     -Value $dvVer        -Type String -Force -ErrorAction SilentlyContinue
    Write-Log "Class entry: OK" -Level Success
    Write-Log "CDDB: NOT created (matches reference KVM)" -Level Info

    Invoke-CreateDevnode -InfName $oemName

    # -------------------------------------------------------------------
    # STEP 3.6: STORAHCI + LEGACY DRIVERS
    # -------------------------------------------------------------------
    Write-Section "STEP 3.6. STORAHCI + LEGACY DRIVERS"

    $ahciKey = "HKLM:\SYSTEM\CurrentControlSet\Services\storahci"
    if (Test-Path -LiteralPath $ahciKey) {
        Set-ItemProperty -Path $ahciKey -Name "Start" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Remove-RegKeySafe -Path "$ahciKey\StartOverride"
        Write-Log "storahci: active" -Level Success
    }

    $secList = @("viostor","stornvme","lsi_sas","lsi_sas2i","lsi_sas3i","megasr","pvscsi","vmw_pvscsi","pciide","intelide","atapi","vmbus")
    foreach ($s in $secList) {
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\$s"
        if (Test-Path -LiteralPath $k) {
            Set-ItemProperty -Path $k -Name "Start" -Value 0 -Type DWord -ErrorAction SilentlyContinue
            $ovrKey = "$k\StartOverride"
            if (-not (Test-Path -LiteralPath $ovrKey)) { New-Item -Path $ovrKey -Force | Out-Null }
            Set-ItemProperty -Path $ovrKey -Name "0" -Value 3 -Type DWord -ErrorAction SilentlyContinue
        }
    }
    Write-Log "Legacy drivers: StartOverride=3" -Level Info

    # -------------------------------------------------------------------
    # STEP 4: REMOVE EXTENDED (MBR only)
    # -------------------------------------------------------------------
    if (-not (Assert-SystemDisk)) { throw "System disk resolution failed at STEP 4" }

    if ($Global:State.HasExtended) {
        Invoke-RemoveExtendedPartitions -DiskNum $Global:SystemDisk.Number
    } else {
        Write-Skip -Step "STEP 4" -Reason "no Extended partition"
    }

    # -------------------------------------------------------------------
    # STEP 5: BCD CLEANUP (MBR only)
    # -------------------------------------------------------------------
    Write-Section "STEP 5. BCD CLEANUP"

    if ($Global:State.DiskStyle -eq 'MBR') {
        & bcdedit.exe /deletevalue "{bootmgr}"  recoverysequence 2>&1 | Out-Null
        & bcdedit.exe /deletevalue "{current}"  recoverysequence 2>&1 | Out-Null
        & bcdedit.exe /set "{current}" recoveryenabled No 2>&1 | Out-Null
        Write-Log "BCD cleanup: done" -Level Success
    } else {
        Write-Skip -Step "STEP 5" -Reason "disk already GPT, BCD cleanup not required"
    }

    # -------------------------------------------------------------------
    # STEP 6: MBR2GPT (MBR only)
    # -------------------------------------------------------------------
    Write-Section "STEP 6. MBR2GPT CONVERT"

    if (-not (Assert-SystemDisk)) { throw "System disk resolution failed at STEP 6" }
    $Global:SystemDisk = Get-Disk -Number $Global:SystemDisk.Number -ErrorAction Stop

    if ($Global:SystemDisk.PartitionStyle -eq 'MBR') {
        $mbr2gpt = "$env:SystemRoot\System32\mbr2gpt.exe"
        Start-Process -FilePath "reagentc.exe" -ArgumentList "/disable" -Wait -NoNewWindow -ErrorAction SilentlyContinue | Out-Null

        Write-Log "Running mbr2gpt /validate..." -Level Action
        & $mbr2gpt /validate /allowFullOS /disk:$($Global:SystemDisk.Number)
        if ($LASTEXITCODE -ne 0) { throw "mbr2gpt /validate failed (exit $LASTEXITCODE)" }
        Write-Log "mbr2gpt /validate PASSED" -Level Success

        Write-Log "Running mbr2gpt /convert..." -Level Action
        & $mbr2gpt /convert /allowFullOS /disk:$($Global:SystemDisk.Number)
        if ($LASTEXITCODE -ne 0) { throw "mbr2gpt /convert failed (exit $LASTEXITCODE)" }
        Write-Log "mbr2gpt /convert PASSED" -Level Success

        Update-HostStorageCache -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500
    } else {
        Write-Skip -Step "STEP 6" -Reason "disk already GPT"
    }

    # -------------------------------------------------------------------
    # STEP 6.5: REMOVE ORPHAN SR (MBR only)
    # -------------------------------------------------------------------
    if ($Global:State.DiskStyle -eq 'MBR') {
        Invoke-RemoveOrphanSR -DiskNum $Global:SystemDisk.Number
    } else {
        Write-Skip -Step "STEP 6.5" -Reason "disk already GPT, no orphan SR expected"
    }

    # -------------------------------------------------------------------
    # STEP 6.6: REBUILD UEFI BCD
    # -------------------------------------------------------------------
    Write-Section "STEP 6.6. REBUILD UEFI BCD"

    if ($Global:State.BootReady -and $Global:State.DiskStyle -eq 'GPT') {
        Write-Skip -Step "STEP 6.6" -Reason "UEFI BCD already present"
    } else {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 500

        $Global:SystemDisk = Get-Disk -Number $Global:SystemDisk.Number
        $parts = Get-Partition -DiskNumber $Global:SystemDisk.Number -ErrorAction SilentlyContinue
        $esp = $parts | Where-Object { $_.GptType -eq $ESP_GPT_TYPE } | Select-Object -First 1
        if (-not $esp) { throw "ESP partition not found" }

        Write-Log "ESP: #$($esp.PartitionNumber) Size=$([math]::Round($esp.Size/1MB,0))MB" -Level Success

        try {
            Add-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction Stop
        } catch {
            throw "Failed to assign S: to ESP: $_"
        }

        try {
            Write-Log "Rebuilding UEFI BCD via bcdboot..." -Level Action
            & bcdboot.exe "$env:SystemDrive\Windows" /s S: /f UEFI /v

            $bcdOk      = Test-Path "S:\EFI\Microsoft\Boot\BCD"
            $bootmgfwOk = Test-Path "S:\EFI\Microsoft\Boot\bootmgfw.efi"
            if ($bcdOk -and $bootmgfwOk) {
                Write-Log "bcdboot: BCD + bootmgfw.efi present" -Level Success
            } else {
                throw "bcdboot failed: BCD=$bcdOk bootmgfw.efi=$bootmgfwOk"
            }

            New-Item -Path "S:\EFI\BOOT" -ItemType Directory -Force | Out-Null
            Copy-Item "S:\EFI\Microsoft\Boot\bootmgfw.efi" "S:\EFI\BOOT\BOOTX64.EFI" -Force
            Write-Log "Fallback bootloader: \EFI\BOOT\BOOTX64.EFI created" -Level Success

            & bcdedit.exe /store S:\EFI\Microsoft\Boot\BCD /set "{default}" nointegritychecks on 2>&1 | Out-Null
            & bcdedit.exe /store S:\EFI\Microsoft\Boot\BCD /set "{default}" testsigning       on 2>&1 | Out-Null
            Write-Log "BCD hardening: applied" -Level Success
        } finally {
            Remove-PartitionAccessPath -DiskNumber $esp.DiskNumber -PartitionNumber $esp.PartitionNumber -AccessPath "S:\" -ErrorAction SilentlyContinue
        }
    }

    # -------------------------------------------------------------------
    # STEP 7: KVM/UEFI PATCHES
    # -------------------------------------------------------------------
    Write-Section "STEP 7. KVM / UEFI SYSTEM PATCHES"

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" -Name "RealTimeIsUniversal" -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Write-Log "RealTimeIsUniversal = 1" -Level Success

    try {
        Set-TimeZone -Id "UTC" -ErrorAction Stop
        Write-Log "TimeZone = UTC" -Level Success
    } catch {
        Write-Log "TimeZone set failed: $_" -Level Warning
    }

    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control" -Name "BootDriverFlags" -Value 28 -Type DWord -ErrorAction SilentlyContinue
    Write-Log "BootDriverFlags = 28" -Level Success

    # -------------------------------------------------------------------
    # STEP 8: NETWORK RESET
    # -------------------------------------------------------------------
    Write-Section "STEP 8. NETWORK RESET (DHCP + FIREWALL)"

    $adapters = Get-NetAdapter -ErrorAction SilentlyContinue
    if ($adapters) {
        foreach ($a in $adapters) {
            Write-Log "Processing: $($a.Name)" -Level Info
            try { Set-NetIPInterface        -InterfaceIndex $a.ifIndex -Dhcp Enabled            -ErrorAction Stop; Write-Log "  DHCP enabled" -Level Success } catch { Write-Log "  DHCP: $_" -Level Warning }
            try { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses    -ErrorAction Stop; Write-Log "  DNS reset"    -Level Success } catch { Write-Log "  DNS: $_"  -Level Warning }
            try { Set-NetConnectionProfile   -InterfaceIndex $a.ifIndex -NetworkCategory Private -ErrorAction Stop; Write-Log "  Category=Private" -Level Success } catch { Write-Log "  Category: $_" -Level Warning }
        }
    }

    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0 -ErrorAction SilentlyContinue
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop" -ErrorAction SilentlyContinue

    try {
        (Get-CimInstance -ClassName Win32_TSGeneralSetting -Namespace root\cimv2\terminalservices -Filter "TerminalName='RDP-tcp'" -ErrorAction SilentlyContinue) |
            Invoke-CimMethod -MethodName SetUserAuthenticationRequired -Arguments @{ UserAuthenticationRequired = 0 } -ErrorAction SilentlyContinue | Out-Null
        Write-Log "NLA off for RDP" -Level Success
    } catch {
        Write-Log "NLA skip: $_" -Level Warning
    }

    Get-NetFirewallRule -Name "*icmpv4*" -ErrorAction SilentlyContinue | Enable-NetFirewallRule -ErrorAction SilentlyContinue
    Write-Log "ICMPv4 enabled" -Level Success

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ShutdownWithoutLogon" -Value 1 -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "ShutdownWarningDialogTimeout" -Value 1 -ErrorAction SilentlyContinue

    Write-Log "Network reset: done" -Level Success

    # -------------------------------------------------------------------
    # STEP 9: FINAL VERIFICATION
    # -------------------------------------------------------------------
    Write-Section "STEP 9. FINAL VERIFICATION"

    $img = (Get-ItemProperty -Path $vioscsiKey -Name "ImagePath" -ErrorAction SilentlyContinue).ImagePath
    $tag = (Get-ItemProperty -Path $vioscsiKey -Name "Tag"       -ErrorAction SilentlyContinue).Tag
    $dma = (Get-ItemProperty -Path "$vioscsiKey\Parameters" -Name "DmaRemappingCompatible" -ErrorAction SilentlyContinue).DmaRemappingCompatible

    Write-Log "  vioscsi ImagePath: $img" -Level Info
    Write-Log "  vioscsi Tag: $tag"       -Level Info
    Write-Log "  vioscsi DmaRemappingCompatible: $dma" -Level Info

    if (Test-Path -LiteralPath "$vioscsiKey\StartOverride") {
        Write-Log "  WARNING: StartOverride PRESENT - removing" -Level Warning
        Remove-RegKeySafe -Path "$vioscsiKey\StartOverride"
    } else {
        Write-Log "  vioscsi StartOverride: CLEAN" -Level Success
    }

    if (Test-Path -LiteralPath $DEVNODE_PATH) {
        $devProps = Get-ItemProperty -Path $DEVNODE_PATH -ErrorAction SilentlyContinue
        if ($devProps -and $devProps.Service -eq "vioscsi") {
            Write-Log "  Devnode: PRESENT (Service=vioscsi)" -Level Success
        } else {
            Write-Log "  Devnode: PRESENT but Service missing" -Level Warning
        }
    } else {
        Write-Log "  Devnode: MISSING" -Level Warning
    }

    $finalParts = Get-Partition -DiskNumber $Global:SystemDisk.Number -ErrorAction SilentlyContinue
    Write-Log "  Final disk layout: $($finalParts.Count) partitions" -Level Info
    foreach ($p in ($finalParts | Sort-Object Offset)) {
        $gpt = if ($p.GptType) { $p.GptType } else { "(MBR)" }
        Write-Log "   #$($p.PartitionNumber) Type=$($p.Type) Size=$([math]::Round($p.Size/1MB,0))MB Letter='$($p.DriveLetter)' Gpt=$gpt" -Level Info
    }

    # -------------------------------------------------------------------
    # STEP 10: CLEANUP & SHUTDOWN
    # -------------------------------------------------------------------
    Write-Section "STEP 10. CLEANUP & SHUTDOWN"

    Remove-Item -Path "$env:TEMP\virtio-win-guest-tools.exe" -Force -ErrorAction SilentlyContinue

    Write-Log "==============================================" -Level Success
    Write-Log " PREPARATION COMPLETED SUCCESSFULLY (v$SCRIPT_VERSION)" -Level Success
    Write-Log "==============================================" -Level Success
    Write-Log ""
    Write-Log "NEXT STEPS:" -Level Info
    Write-Log "  1. Collect log: $Global:LogPath" -Level Info
    Write-Log "  2. Export disk and upload to S3 (see README)" -Level Info
    Write-Log "  3. In MWS console: import disk, create VM, boot" -Level Info
    Write-Log "  4. Inside KVM: run 5-Post-Migration.ps1" -Level Info
    Write-Log ""
    Write-Log "PAUSE: press Enter to SHUTDOWN the VM." -Level Warning
    Write-Log "Do NOT reboot. Do NOT boot in UEFI inside VMware." -Level Warning

    Read-Host "Press Enter to Shutdown"

    try {
        Stop-Computer -Force -ErrorAction Stop
    } catch {
        Write-Log "Stop-Computer failed: $_ - using shutdown.exe" -Level Warning
        & shutdown.exe /s /t 0 /f
    }
} catch {
    Write-Log "==============================================" -Level Error
    Write-Log " CRITICAL ERROR! TRANSFORMATION STOPPED." -Level Error
    Write-Log " Message: $_" -Level Error
    Write-Log " Log: $Global:LogPath" -Level Error
    Write-Log "==============================================" -Level Error
    Write-Log ""
    Write-Log "VM will NOT be shut down automatically." -Level Warning
    Write-Log "Collect the log and share it." -Level Warning
    Read-Host "Press Enter to close"
}