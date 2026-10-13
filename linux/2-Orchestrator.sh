#!/bin/bash
# =======================================================================
# FILE: 2-Orchestrator.sh
# VERSION: 4.1
# =======================================================================
# State detection and pipeline for migration-to-mws toolkit (Linux).
#
# Detects:
#   - distribution family and version
#   - init system, bootloader, package manager
#   - environment (VMware / KVM / Hyper-V / Xen / BareMetal)
#   - disk style, root filesystem, LVM/LUKS, EFI partition
#   - free space
#   - cloud-init presence, virtio in initramfs
#   - blockers (EOL, LVM, LUKS, unsupported FS, etc.)
#
# Decides:
#   - ReadyForExport    -> tell user to export
#   - RunMigration      -> call 3-Diagnostic + 4-Migration
#   - PostMigration     -> suggest scripts 5/6/7 (inside KVM)
#   - AbortXxx          -> stop with reason
#
# Usage:
#   sudo ./2-Orchestrator.sh
#   or via 1-run.sh
# =======================================================================

set -u

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root."
    exit 1
fi

# --- Resolve script directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# --- Prepare logs directory ---
LOGS_DIR="$SCRIPT_DIR/logs"
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR" || {
        echo "ERROR: cannot create $LOGS_DIR"
        exit 1
    }
fi

# --- Set up log file ---
TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
LOG_FILE="$LOGS_DIR/2-Orchestrator_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source core library ---
if [ ! -f "$SCRIPT_DIR/lib-core.sh" ]; then
    echo "ERROR: lib-core.sh not found in $SCRIPT_DIR"
    exit 1
fi
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"

# =======================================================================
# MAIN
# =======================================================================

Log-Info ""
Log-Info "=========================================================="
Log-Info " MWS MIGRATION ORCHESTRATOR v4.1"
Log-Info "=========================================================="
Log-Info ""

Log-Info "Detecting environment and state..."
Get-LinuxState
Show-LinuxState

# --- Hypervisor warning (non-blocking) ---
if [ "$ENVIRONMENT" != "VMware" ] && [ "$ENVIRONMENT" != "KVM" ]; then
    Log-Warn "Hypervisor: $ENVIRONMENT"
    Log-Warn "Toolkit is tested on VMware ESXi and KVM (MWS)."
    Log-Warn "On other platforms some steps may not apply."
    printf "Continue anyway? (y/N): "
    read -r answer
    if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
        Log-Info "Aborted by user."
        exit 0
    fi
fi

# --- Blockers ---
if [ -n "$BLOCKER" ]; then
    Log-Info ""
    Log-Info "=========================================================="
    Log-Error " MIGRATION CANNOT PROCEED"
    Log-Info "=========================================================="
    Log-Info ""

    case "$BLOCKER" in
        AbortUnknownDistro)
            Log-Error "Distribution family not recognized."
            Log-Info  "Supported families:"
            Log-Info  "  - Debian-like:  Debian 11+, Ubuntu 20.04+, Mint 21+"
            Log-Info  "  - RHEL-like:    RHEL 8+, Rocky 8+, Alma 8+, Fedora 35+, Oracle 8+"
            Log-Info  ""
            Log-Info  "For other distributions — proceed manually."
            ;;
        AbortLegacyDistro)
            Log-Error "Distribution is EOL and not supported."
            Log-Info  "Detected: $DISTRO_PRETTY_NAME"
            Log-Info  "Recommended: upgrade or clean install."
            ;;
        AbortNoDisk)
            Log-Error "Cannot determine system disk."
            Log-Info  "Check lsblk and findmnt /."
            ;;
        AbortUnsupportedFS)
            Log-Error "Root filesystem is not supported: $ROOT_FSTYPE"
            Log-Info  "Supported: ext4, xfs, btrfs."
            ;;
        AbortLVM)
            Log-Error "Root is on LVM."
            Log-Info  "LVM migration requires manual steps. Toolkit does not handle it."
            ;;
        AbortEncrypted)
            Log-Error "Root is encrypted (LUKS)."
            Log-Info  "Decrypt the volume before migration."
            ;;
        AbortLowSpace)
            Log-Error "Free space on / is less than 2 GB."
            Log-Info  "Detected: ${FREE_SPACE_GB} GB"
            Log-Info  "Free at least 2 GB and retry."
            ;;
        AbortNoEFI)
            Log-Error "GPT disk without ESP partition."
            Log-Info  "Disk layout is damaged. Restore from backup."
            ;;
        AbortNoPartitionTool)
            Log-Error "No partition tool found (sgdisk or parted)."
            Log-Info  "Install gdisk (Debian-like) or gdisk (RHEL-like)."
            ;;
        AbortNoInitramfsTool)
            Log-Error "No initramfs tool found."
            Log-Info  "Install dracut (RHEL-like) or initramfs-tools (Debian-like)."
            ;;
        *)
            Log-Error "Unknown blocker: $BLOCKER"
            ;;
    esac

    Log-Info ""
    Log-Info "No changes were made to the system."
    exit 1
fi

# --- Decision table ---

DIAG_SCRIPT="$SCRIPT_DIR/3-Diagnostic.sh"
MIG_SCRIPT="$SCRIPT_DIR/4-Migration.sh"

# -------------------------------------------------------------------
# KVM target — already migrated
# -------------------------------------------------------------------
if [ "$ENVIRONMENT" = "KVM" ]; then
    Log-Info "=== STATE: INSIDE KVM (post-migration) ==="
    Log-Info ""
    Log-Info "VM is running in KVM (MWS). Migration is complete."
    Log-Info ""
    Log-Info "Recommended next steps:"
    Log-Info "  [1] 5-Post-Migration.sh  - clean VMware leftovers"
    Log-Info "  [2] 6-Cloud-Init.sh      - optional: metadata integration"
    Log-Info "  [3] 7-Sysprep.sh         - optional: golden image"
    Log-Info ""
    if [ "$CLOUD_INIT_READY" = "yes" ]; then
        Log-Info "[+] cloud-init: installed"
    else
        Log-Warn "[-] cloud-init: not installed"
    fi
    Log-Info ""
    Log-Info "This orchestrator does not auto-run scripts 5/6/7."
    Log-Info "Run them manually from the same folder."
    exit 0
fi

# -------------------------------------------------------------------
# Ready for export
# -------------------------------------------------------------------
if [ "$DISK_STYLE" = "gpt" ] && [ "$HAS_EFI" = "yes" ] && \
   [ "$BOOTLOADER" = "grub2-efi" ]; then

    Log-Info "=== STATE: READY FOR EXPORT ==="
    Log-Info ""
    Log-Info "All checks passed:"
    Log-Info "  [+] Disk: GPT"
    Log-Info "  [+] EFI partition: present"
    Log-Info "  [+] Bootloader: GRUB2 EFI"
    Log-Info ""
    Log-Info "Next steps:"
    Log-Info "  1. Power off this VM in vSphere"
    Log-Info "  2. Export disk and upload to S3 (see README)"
    Log-Info "  3. Import into MWS Cloud Platform"
    Log-Info "  4. Boot the VM in KVM"
    Log-Info "  5. Inside KVM: run 5-Post-Migration.sh"
    Log-Info ""
    Log-Info "Do NOT boot this VM in UEFI inside VMware."
    Log-Info "Do NOT switch firmware BIOS -> UEFI in vSphere."
    exit 0
fi

# -------------------------------------------------------------------
# Run migration
# -------------------------------------------------------------------
Log-Info "=== STATE: MIGRATION NEEDED ==="
Log-Info ""
Log-Info "Reasons:"
if [ "$DISK_STYLE" = "mbr" ]; then
    Log-Info "  - Disk is MBR (must be GPT for KVM/UEFI)"
fi
if [ "$HAS_EFI" != "yes" ]; then
    Log-Info "  - No EFI System Partition on disk"
fi
if [ "$BOOTLOADER" != "grub2-efi" ]; then
    Log-Info "  - Bootloader is not GRUB2 EFI (current: $BOOTLOADER)"
fi
Log-Info ""
Log-Info "Plan:"
Log-Info "  1. Run 3-Diagnostic.sh (baseline, read-only)"
Log-Info "  2. Run 4-Migration.sh (transform the VM)"
Log-Info "  3. VM shuts down or prompts for manual shutdown"
Log-Info ""

if [ ! -f "$DIAG_SCRIPT" ]; then
    Log-Error "3-Diagnostic.sh not found in $SCRIPT_DIR"
    exit 1
fi
if [ ! -f "$MIG_SCRIPT" ]; then
    Log-Error "4-Migration.sh not found in $SCRIPT_DIR"
    exit 1
fi

printf "Press Enter to continue (Ctrl+C to cancel): "
read -r _

Log-Info ""
Log-Info ">>> Running 3-Diagnostic.sh"
bash "$DIAG_SCRIPT"
DIAG_RC=$?

if [ "$DIAG_RC" -ne 0 ]; then
    Log-Warn "3-Diagnostic.sh exited with code $DIAG_RC"
fi

Log-Info ""
Log-Info ">>> Running 4-Migration.sh"
bash "$MIG_SCRIPT"
MIG_RC=$?

if [ "$MIG_RC" -ne 0 ]; then
    Log-Error "4-Migration.sh exited with code $MIG_RC"
    exit "$MIG_RC"
fi

Log-Success "Orchestrator finished successfully."
exit 0