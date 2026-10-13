#!/bin/bash
# =======================================================================
# FILE: lib-core.sh
# VERSION: 4.1
# =======================================================================
# Core library for migration-to-mws toolkit (Linux).
#
# Contains:
#   - Logging     (Log-Info, Log-Warn, Log-Error, Log-Success,
#                  Log-Action, Log-Skip, Log-Section)
#   - Common      (Run-Cmd, Ensure-Dir, Assert-Root, Command-Exists,
#                  Mountpoint-Exists)
#   - Detect      (Detect-*, Get-LinuxState, Show-LinuxState)
#   - Blockers    (Check-Blockers)
#   - Handlers    (Install-Pkg, Rebuild-Initramfs, Ensure-CloudInit)
#
# This is a LIBRARY. Do not run directly.
# Source from scripts 1..7:
#     LOG_FILE="/path/to/logs/xxx.log"
#     source "$SCRIPT_DIR/lib-core.sh"
#
# LOG_FILE must be set by the caller BEFORE source.
# If LOG_FILE is empty, logs go only to stdout.
# =======================================================================

# Guard against direct execution
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "lib-core.sh is a library. Do not run it directly."
    echo "Run 1-run.sh instead."
    exit 1
fi

# =======================================================================
# CONSTANTS
# =======================================================================

ESP_GPT_TYPE="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
MSR_GPT_TYPE="e3c9e316-0b5c-4db8-817d-f92df00215ae"

# =======================================================================
# LOGGING
# =======================================================================

_log_timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

_log_to_file() {
    if [ -n "$LOG_FILE" ]; then
        echo "$1" >> "$LOG_FILE" 2>/dev/null
    fi
}

Log-Info() {
    local line="[$(  _log_timestamp)] [Info]    $*"
    echo "$line"
    _log_to_file "$line"
}

Log-Success() {
    local line="[$(  _log_timestamp)] [Success] $*"
    echo "$line"
    _log_to_file "$line"
}

Log-Warn() {
    local line="[$(  _log_timestamp)] [Warning] $*"
    echo "$line"
    _log_to_file "$line"
}

Log-Error() {
    local line="[$(  _log_timestamp)] [Error]   $*"
    echo "$line" >&2
    _log_to_file "$line"
}

Log-Action() {
    local line="[$(  _log_timestamp)] [Action]  $*"
    echo "$line"
    _log_to_file "$line"
}

Log-Skip() {
    local step="$1"
    shift
    local line="[$(  _log_timestamp)] [Skip]    ${step} SKIPPED: $*"
    echo "$line"
    _log_to_file "$line"
}

Log-Section() {
    Log-Info ""
    Log-Info "=========================================================="
    Log-Info "===== [${1}] ====="
    Log-Info "=========================================================="
}

# =======================================================================
# COMMON
# =======================================================================

Run-Cmd() {
    # Run-Cmd <description> <command...>
    local desc="$1"
    shift
    Log-Action "$desc"
    if "$@"; then
        return 0
    else
        local rc=$?
        Log-Warn "  Command failed (exit $rc): $*"
        return $rc
    fi
}

Ensure-Dir() {
    if [ ! -d "$1" ]; then
        mkdir -p "$1" || {
            echo "ERROR: cannot create directory $1" >&2
            exit 1
        }
    fi
}

Assert-Root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "ERROR: must be run as root."
        echo "Run: sudo $0"
        exit 1
    fi
}

Command-Exists() {
    command -v "$1" >/dev/null 2>&1
}

Mountpoint-Exists() {
    if command -v mountpoint >/dev/null 2>&1; then
        mountpoint -q "$1" 2>/dev/null
    else
        grep -qs " $1 " /proc/mounts
    fi
}

# =======================================================================
# DETECT: DISTRIBUTION FAMILY
# =======================================================================

Detect-DistroFamily() {
    # Sets: DISTRO_ID, DISTRO_VERSION_ID, DISTRO_PRETTY_NAME,
    #       DISTRO_FAMILY (debian | rhel | unknown),
    #       DISTRO_SUPPORTED (yes | no | eol)
    DISTRO_ID=""
    DISTRO_VERSION_ID=""
    DISTRO_PRETTY_NAME="unknown"
    DISTRO_FAMILY="unknown"
    DISTRO_SUPPORTED="no"

    [ -f /etc/os-release ] || return

    # shellcheck disable=SC1091
    . /etc/os-release

    DISTRO_ID="$ID"
    DISTRO_VERSION_ID="$VERSION_ID"
    DISTRO_PRETTY_NAME="$PRETTY_NAME"

    local combined="$ID ${ID_LIKE:-}"
    local major="${VERSION_ID%%.*}"

    case "$combined" in
        *debian*|*ubuntu*|*linuxmint*)
            DISTRO_FAMILY="debian"
            DISTRO_SUPPORTED="yes"
            case "$ID" in
                debian)    [ "$major" -lt 11 ] 2>/dev/null && DISTRO_SUPPORTED="eol" ;;
                ubuntu)    [ "$major" -lt 20 ] 2>/dev/null && DISTRO_SUPPORTED="eol" ;;
                linuxmint) [ "$major" -lt 21 ] 2>/dev/null && DISTRO_SUPPORTED="eol" ;;
            esac
            ;;
        *rhel*|*fedora*|*centos*|*rocky*|*almalinux*|*ol*)
            DISTRO_FAMILY="rhel"
            DISTRO_SUPPORTED="yes"
            case "$ID" in
                rhel|centos|rocky|almalinux|ol)
                    [ "$major" -lt 8 ] 2>/dev/null && DISTRO_SUPPORTED="eol" ;;
                fedora)
                    [ "$major" -lt 35 ] 2>/dev/null && DISTRO_SUPPORTED="eol" ;;
            esac
            ;;
        *)
            DISTRO_FAMILY="unknown"
            DISTRO_SUPPORTED="no"
            ;;
    esac
}

# =======================================================================
# DETECT: INIT SYSTEM
# =======================================================================

Detect-InitSystem() {
    if Command-Exists systemctl; then
        INIT_SYSTEM="systemd"
    elif Command-Exists rc-service; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="sysvinit"
    fi
}

# =======================================================================
# DETECT: BOOTLOADER
# =======================================================================

Detect-Bootloader() {
    if [ -d /sys/firmware/efi ]; then
        HAS_UEFI_BOOT="yes"
        if Command-Exists grub-install; then
            BOOTLOADER="grub2-efi"
        elif Command-Exists bootctl; then
            BOOTLOADER="systemd-boot"
        else
            BOOTLOADER="unknown-efi"
        fi
    else
        HAS_UEFI_BOOT="no"
        if Command-Exists grub-install; then
            BOOTLOADER="grub2-bios"
        else
            BOOTLOADER="unknown-bios"
        fi
    fi
}

# =======================================================================
# DETECT: PACKAGE MANAGER
# =======================================================================

Detect-PackageManager() {
    # apt-get is checked too: minimal Debian may lack the apt wrapper.
    for pm in apt apt-get dnf yum zypper pacman apk; do
        if Command-Exists "$pm"; then
            case "$pm" in
                apt-get) PKG_MANAGER="apt" ;;
                *)       PKG_MANAGER="$pm" ;;
            esac
            return
        fi
    done
    PKG_MANAGER="unknown"
}

# =======================================================================
# DETECT: ENVIRONMENT
# =======================================================================

Detect-Environment() {
    local mfr=""
    [ -r /sys/class/dmi/id/sys_vendor ] && mfr=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)

    case "$mfr" in
        *VMware*)    ENVIRONMENT="VMware" ;;
        *QEMU*)      ENVIRONMENT="KVM" ;;
        *Microsoft*) ENVIRONMENT="Hyper-V" ;;
        *Xen*)       ENVIRONMENT="Xen" ;;
        "")          ENVIRONMENT="Unknown" ;;
        *)           ENVIRONMENT="BareMetal" ;;
    esac
}

# =======================================================================
# DETECT: DISK STATE
# =======================================================================
# All state variables are reset at the top to avoid stale values when
# Get-LinuxState is called more than once (e.g. after Step-ConvertGpt).
# =======================================================================

Detect-DiskState() {
    SYS_DISK=""
    DISK_STYLE="unknown"
    ROOT_FSTYPE=""
    HAS_EFI="no"
    HAS_LVM="no"
    HAS_LUKS="no"
    ROOT_RW="unknown"

    local root_source
    root_source=$(findmnt -n -o SOURCE / 2>/dev/null)
    [ -z "$root_source" ] && return

    local root_opts
    root_opts=$(findmnt -n -o OPTIONS / 2>/dev/null)
    case "$root_opts" in
        *ro*) ROOT_RW="no" ;;
        *rw*) ROOT_RW="yes" ;;
    esac

    local parent
    case "$root_source" in
        /dev/mapper/*)
            Command-Exists pvs && pvs 2>/dev/null | grep -q . && HAS_LVM="yes"
            Command-Exists cryptsetup && \
                cryptsetup status "$(basename "$root_source")" >/dev/null 2>&1 && \
                HAS_LUKS="yes"
            parent=$(lsblk -no pkname "$root_source" 2>/dev/null | head -n1)
            [ -n "$parent" ] && SYS_DISK="/dev/$parent"
            ;;
        /dev/*)
            parent=$(lsblk -no pkname "$root_source" 2>/dev/null | head -n1)
            if [ -n "$parent" ]; then
                SYS_DISK="/dev/$parent"
            else
                SYS_DISK="$root_source"
            fi
            ;;
    esac

    # Disk style
    if [ -n "$SYS_DISK" ] && [ -b "$SYS_DISK" ]; then
        if Command-Exists blkid; then
            local ptype
            ptype=$(blkid -o value -s PTTYPE "$SYS_DISK" 2>/dev/null)
            case "$ptype" in
                gpt) DISK_STYLE="gpt" ;;
                dos) DISK_STYLE="mbr" ;;
            esac
        fi
        if [ "$DISK_STYLE" = "unknown" ] && Command-Exists parted; then
            local ptype
            ptype=$(parted -s "$SYS_DISK" print 2>/dev/null | awk '/Partition Table/ {print $3}')
            case "$ptype" in
                gpt)   DISK_STYLE="gpt" ;;
                msdos) DISK_STYLE="mbr" ;;
            esac
        fi
    fi

    ROOT_FSTYPE=$(findmnt -n -o FSTYPE / 2>/dev/null)

    if [ -n "$SYS_DISK" ] && Command-Exists lsblk; then
        lsblk -no PARTTYPE "$SYS_DISK" 2>/dev/null | grep -qi "$ESP_GPT_TYPE" && HAS_EFI="yes"
    fi
}

# =======================================================================
# DETECT: FREE SPACE ON ROOT
# =======================================================================

Detect-FreeSpace() {
    FREE_SPACE_GB=0
    if Command-Exists df; then
        local kb
        kb=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}')
        [ -n "$kb" ] && FREE_SPACE_GB=$(( kb / 1024 / 1024 ))
    fi
}

# =======================================================================
# DETECT: TOOLKIT READINESS
# =======================================================================

Detect-CloudInitReady() {
    if Command-Exists cloud-init; then
        CLOUD_INIT_READY="yes"
    else
        CLOUD_INIT_READY="no"
    fi
}

Detect-VirtioModules() {
    # yes   -> virtio_scsi loaded
    # maybe -> module file exists but not loaded
    # no    -> not found
    if lsmod 2>/dev/null | grep -q '^virtio_scsi'; then
        VIRTIO_IN_INITRAMFS="yes"
    elif [ -d /lib/modules ] && \
         find /lib/modules/"$(uname -r)" -name 'virtio_scsi.ko*' 2>/dev/null | grep -q .; then
        VIRTIO_IN_INITRAMFS="maybe"
    else
        VIRTIO_IN_INITRAMFS="no"
    fi
}

Detect-PartitionTool() {
    if Command-Exists sgdisk || Command-Exists parted; then
        HAS_PARTITION_TOOL="yes"
    else
        HAS_PARTITION_TOOL="no"
    fi
}

Detect-InitramfsTool() {
    if Command-Exists dracut || Command-Exists update-initramfs || Command-Exists mkinitcpio; then
        HAS_INITRAMFS_TOOL="yes"
    else
        HAS_INITRAMFS_TOOL="no"
    fi
}

# =======================================================================
# BLOCKERS
# =======================================================================
# Order: fatal (cannot determine what to migrate) first, then disk/FS,
# then tools, then free space. First failed check wins.
# =======================================================================

Check-Blockers() {
    BLOCKER=""

    [ "$DISTRO_FAMILY" = "unknown" ]        && { BLOCKER="AbortUnknownDistro";    return; }
    [ "$DISTRO_SUPPORTED" = "eol" ]         && { BLOCKER="AbortLegacyDistro";     return; }
    [ -z "$SYS_DISK" ]                      && { BLOCKER="AbortNoDisk";           return; }

    case "$ROOT_FSTYPE" in
        ext4|xfs|btrfs) ;;
        *) BLOCKER="AbortUnsupportedFS"; return ;;
    esac

    [ "$HAS_LVM" = "yes" ]                  && { BLOCKER="AbortLVM";              return; }
    [ "$HAS_LUKS" = "yes" ]                 && { BLOCKER="AbortEncrypted";        return; }
    [ "$FREE_SPACE_GB" -lt 2 ] 2>/dev/null  && { BLOCKER="AbortLowSpace";         return; }
    [ "$DISK_STYLE" = "gpt" ] && [ "$HAS_EFI" != "yes" ] \
                                            && { BLOCKER="AbortNoEFI";            return; }
    [ "$HAS_PARTITION_TOOL" != "yes" ]      && { BLOCKER="AbortNoPartitionTool";  return; }
    [ "$HAS_INITRAMFS_TOOL" != "yes" ]      && { BLOCKER="AbortNoInitramfsTool";  return; }
}

# =======================================================================
# TOP-LEVEL STATE
# =======================================================================

Get-LinuxState() {
    Detect-DistroFamily
    Detect-InitSystem
    Detect-Bootloader
    Detect-PackageManager
    Detect-Environment
    Detect-DiskState
    Detect-FreeSpace
    Detect-CloudInitReady
    Detect-VirtioModules
    Detect-PartitionTool
    Detect-InitramfsTool
    Check-Blockers
}

Show-LinuxState() {
    Log-Info ""
    Log-Info "=== Detected State ==="
    Log-Info "  Distro          : $DISTRO_PRETTY_NAME"
    Log-Info "  Family          : $DISTRO_FAMILY"
    Log-Info "  Supported       : $DISTRO_SUPPORTED"
    Log-Info "  Init system     : $INIT_SYSTEM"
    Log-Info "  Bootloader      : $BOOTLOADER"
    Log-Info "  UEFI boot       : $HAS_UEFI_BOOT"
    Log-Info "  Package mgr     : $PKG_MANAGER"
    Log-Info "  Environment     : $ENVIRONMENT"
    Log-Info "  System disk     : $SYS_DISK"
    Log-Info "  Disk style      : $DISK_STYLE"
    Log-Info "  Root FS         : $ROOT_FSTYPE"
    Log-Info "  Root RW         : $ROOT_RW"
    Log-Info "  EFI partition   : $HAS_EFI"
    Log-Info "  LVM on root     : $HAS_LVM"
    Log-Info "  LUKS on root    : $HAS_LUKS"
    Log-Info "  Free space      : ${FREE_SPACE_GB} GB"
    Log-Info "  cloud-init      : $CLOUD_INIT_READY"
    Log-Info "  virtio initramfs: $VIRTIO_IN_INITRAMFS"
    Log-Info "  Partition tool  : $HAS_PARTITION_TOOL"
    Log-Info "  Initramfs tool  : $HAS_INITRAMFS_TOOL"
    if [ -n "$BLOCKER" ]; then
        Log-Warn "  Blocker: $BLOCKER"
    fi
    Log-Info ""
}

# =======================================================================
# HANDLERS
# =======================================================================

Install-Pkg() {
    case "$PKG_MANAGER" in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"
            ;;
        dnf)
            dnf install -y "$@"
            ;;
        yum)
            yum install -y "$@"
            ;;
        *)
            Log-Error "No supported package manager (apt/dnf/yum)."
            return 1
            ;;
    esac
}

Rebuild-Initramfs() {
    if [ "$HAS_INITRAMFS_TOOL" != "yes" ]; then
        Log-Error "No initramfs tool available."
        return 1
    fi

    if Command-Exists dracut; then
        dracut -f --regenerate-all
    elif Command-Exists update-initramfs; then
        update-initramfs -u -k all
    elif Command-Exists mkinitcpio; then
        mkinitcpio -P
    else
        Log-Error "No initramfs tool found."
        return 1
    fi
}

Ensure-CloudInit() {
    if Command-Exists cloud-init; then
        Log-Info "cloud-init already installed"
        return 0
    fi

    Log-Action "Installing cloud-init"
    case "$DISTRO_FAMILY" in
        debian|rhel) Install-Pkg cloud-init ;;
        *)
            Log-Error "Cannot install cloud-init on $DISTRO_FAMILY"
            return 1
            ;;
    esac

    if Command-Exists cloud-init; then
        Log-Success "cloud-init installed"
        return 0
    fi

    Log-Error "cloud-init not found after install attempt."
    return 1
}

# =======================================================================
# END OF FILE
# =======================================================================