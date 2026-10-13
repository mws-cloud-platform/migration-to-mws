#!/bin/bash
# =======================================================================
# FILE: 4-Migration.sh
# VERSION: 4.1
# =======================================================================
# Transformation for migration-to-mws toolkit (Linux).
#
# Order of steps:
#   STEP 0   Preflight + Get-LinuxState
#   STEP 1   Free space check
#   STEP 2   Disable services + tuning
#   STEP 3   Convert MBR -> GPT
#   STEP 4   Ensure ESP
#   STEP 5   Rebuild initramfs with virtio
#   STEP 6   Install GRUB2 EFI
#   STEP 7   Verify boot
#   STEP 8   Cleanup & shutdown
#
# Usage:
#   sudo ./4-Migration.sh
#
# Requires:
#   - lib-core.sh
#   - lib-steps-boot.sh
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

# --- Prepare logs ---
LOGS_DIR="$SCRIPT_DIR/logs"
if [ ! -d "$LOGS_DIR" ]; then
    mkdir -p "$LOGS_DIR"
fi

TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
HOSTNAME_SHORT="$(hostname -s 2>/dev/null || hostname)"
LOG_FILE="$LOGS_DIR/4-Migration_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source libraries ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-steps-boot.sh"

# =======================================================================
# MAIN PIPELINE
# =======================================================================

Log-Info "=== 4-Migration.sh v4.1 ==="
Log-Info "Log file: $LOG_FILE"

# -------------------------------------------------------------------
# STEP 0: PREFLIGHT + STATE
# -------------------------------------------------------------------
Log-Section "STEP 0. PREFLIGHT"

Get-LinuxState

Log-Info ""
Log-Info "Detected state:"
Log-Info "  Distro      : $DISTRO_PRETTY_NAME"
Log-Info "  Family      : $DISTRO_FAMILY"
Log-Info "  Disk style  : $DISK_STYLE"
Log-Info "  EFI         : $HAS_EFI"
Log-Info "  Bootloader  : $BOOTLOADER"
Log-Info "  Root FS     : $ROOT_FSTYPE"
Log-Info "  Free space  : ${FREE_SPACE_GB} GB"

if [ -n "$BLOCKER" ]; then
    Log-Error "Migration blocked: $BLOCKER"
    Log-Error "See orchestrator output for details."
    exit 1
fi

if [ "$DISTRO_SUPPORTED" != "yes" ]; then
    Log-Warn "Distribution: $DISTRO_PRETTY_NAME ($DISTRO_SUPPORTED)"
    Log-Warn "Continuing at your own risk."
fi

# -------------------------------------------------------------------
# STEP 1: FREE SPACE
# -------------------------------------------------------------------
Log-Section "STEP 1. FREE SPACE CHECK"

Log-Info "Free space: ${FREE_SPACE_GB} GB"
if [ "$FREE_SPACE_GB" -lt 2 ]; then
    Log-Error "Not enough free space (< 2 GB)."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 2: DISABLE SERVICES + TUNING
# -------------------------------------------------------------------
Log-Section "STEP 2. DISABLE SERVICES / TUNING"

# Stop and disable VMware-specific services if present
for svc in vmtoolsd vmware-tools open-vm-tools; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}"; then
        Log-Action "Stopping and disabling $svc"
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
    fi
done

# Disable swap (temporarily)
if command -v swapoff >/dev/null 2>&1; then
    swapoff -a 2>/dev/null || true
    Log-Info "Swap: disabled"
fi

# Disable SELinux enforcing temporarily (to avoid issues during migration)
if command -v getenforce >/dev/null 2>&1; then
    current_selinux="$(getenforce 2>/dev/null)"
    if [ "$current_selinux" = "Enforcing" ]; then
        Log-Action "Setting SELinux to Permissive (temporary)"
        setenforce 0 2>/dev/null || true
    fi
    Log-Info "SELinux: $current_selinux -> $(getenforce 2>/dev/null)"
fi

# Disable firewall (temporarily) — we need network access for cloud-init
if systemctl is-active firewalld >/dev/null 2>&1; then
    Log-Action "Stopping firewalld (temporary)"
    systemctl stop firewalld 2>/dev/null || true
elif systemctl is-active ufw >/dev/null 2>&1; then
    Log-Action "Stopping ufw (temporary)"
    ufw disable 2>/dev/null || true
fi

# Flush DNS cache
if Command-Exists systemd-resolve; then
    systemd-resolve --flush-caches 2>/dev/null || true
elif Command-Exists resolvectl; then
    resolvectl flush-caches 2>/dev/null || true
fi

# -------------------------------------------------------------------
# STEP 3: CONVERT MBR -> GPT
# -------------------------------------------------------------------
if ! Step-ConvertGpt; then
    Log-Error "MBR -> GPT conversion failed."
    exit 1
fi

# Re-read state after conversion
Get-LinuxState
if [ "$DISK_STYLE" != "gpt" ]; then
    Log-Error "Disk is not GPT after conversion: $DISK_STYLE"
    exit 1
fi

# -------------------------------------------------------------------
# STEP 4: ENSURE ESP
# -------------------------------------------------------------------
if ! Step-CreateESP; then
    Log-Error "ESP creation failed."
    exit 1
fi

Get-LinuxState
if [ "$HAS_EFI" != "yes" ]; then
    Log-Error "ESP is not present after creation step."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 5: REBUILD INITRAMFS
# -------------------------------------------------------------------
if ! Step-Initramfs; then
    Log-Error "initramfs rebuild failed."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 6: INSTALL GRUB2 EFI
# -------------------------------------------------------------------
if ! Step-GrubEfi; then
    Log-Error "GRUB2 EFI installation failed."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 7: VERIFY BOOT
# -------------------------------------------------------------------
if ! Step-VerifyBoot; then
    Log-Warn "Boot verification found issues. Check log."
fi

# -------------------------------------------------------------------
# STEP 8: CLEANUP & SHUTDOWN
# -------------------------------------------------------------------
Log-Section "STEP 8. CLEANUP & SHUTDOWN"

# Sync filesystems
if Command-Exists sync; then
    sync
fi

Log-Info ""
Log-Info "=============================================="
Log-Success " PREPARATION COMPLETED SUCCESSFULLY (v4.1)"
Log-Info "=============================================="
Log-Info ""
Log-Info "NEXT STEPS:"
Log-Info "  1. Collect log: $LOG_FILE"
Log-Info "  2. Export disk and upload to S3 (see README)"
Log-Info "  3. In MWS console: import disk, create VM, boot"
Log-Info "  4. Inside KVM: run 5-Post-Migration.sh"
Log-Info ""
Log-Info "PAUSE: press Enter to SHUTDOWN the VM."
Log-Warn "Do NOT reboot. Do NOT boot in UEFI inside VMware."
printf "Press Enter to shutdown: "
read -r _

# Shutdown
if Command-Exists systemctl; then
    Log-Info "Shutting down via systemctl"
    systemctl poweroff
elif Command-Exists shutdown; then
    Log-Info "Shutting down via shutdown"
    shutdown -h now
else
    Log-Warn "Cannot find shutdown command. Do it manually."
    exit 0
fi