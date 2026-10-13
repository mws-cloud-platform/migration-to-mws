#!/bin/bash
# =======================================================================
# FILE: 5-Post-Migration.sh
# VERSION: 4.1
# =======================================================================
# Post-migration cleanup INSIDE KVM.
#
# Removes:
#   - open-vm-tools and other VMware tools
#   - VMware kernel modules
#   - udev persistent net rules
#   - MACAddress lines from systemd network .link files
#   - leftover VMware directories
#
# Does NOT touch:
#   - disk layout, bootloader, GRUB config
#   - cloud-init (see 6-Cloud-Init.sh)
#
# Idempotent: safe to run multiple times.
#
# Usage:
#   sudo ./5-Post-Migration.sh
#
# Requires:
#   - lib-core.sh
#   - lib-steps-runtime.sh
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
LOG_FILE="$LOGS_DIR/5-Post-Migration_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source libraries ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-steps-runtime.sh"

# =======================================================================
# MAIN
# =======================================================================

Log-Info "=== 5-Post-Migration.sh v4.1 ==="
Log-Info "Log file: $LOG_FILE"

# -------------------------------------------------------------------
# STEP 0: PREFLIGHT
# -------------------------------------------------------------------
Log-Section "STEP 0. PREFLIGHT"

Get-LinuxState

Log-Info ""
Log-Info "Environment: $ENVIRONMENT"
Log-Info "Distro:      $DISTRO_PRETTY_NAME"
Log-Info "Family:      $DISTRO_FAMILY"

if [ "$ENVIRONMENT" = "VMware" ]; then
    Log-Warn "Environment is VMware, not KVM."
    Log-Warn "This script is for the KVM target."
    Log-Warn "Continuing, but VMware cleanup may not apply."
elif [ "$ENVIRONMENT" = "KVM" ]; then
    Log-Success "Environment check: KVM detected"
else
    Log-Warn "Environment check: unknown hypervisor ($ENVIRONMENT). Proceeding."
fi

# -------------------------------------------------------------------
# STEP 1: POST-MIGRATION CLEANUP
# -------------------------------------------------------------------
if ! Step-PostCleanup; then
    Log-Error "Post-migration cleanup failed."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 2: VERIFY RUNTIME
# -------------------------------------------------------------------
if ! Step-VerifyRuntime; then
    Log-Warn "Runtime verification found issues. Check log."
fi

# -------------------------------------------------------------------
# STEP 3: NEXT STEPS
# -------------------------------------------------------------------
Log-Section "STEP 3. NEXT STEPS"

Log-Success "Post-migration cleanup is complete."
Log-Info ""
Log-Info "OPTIONAL next steps:"
Log-Info "  - Run 6-Cloud-Init.sh to enable metadata integration"
Log-Info "  - Run 7-Sysprep.sh (only for golden image creation, irreversible)"
Log-Info ""

# Check if reboot is recommended
vm_tools_state="absent"
case "$PKG_MANAGER" in
    apt)
        if dpkg -l 2>/dev/null | grep -qE '^ii\s+open-vm-tools'; then
            vm_tools_state="present"
        fi
        ;;
    dnf|yum)
        if rpm -q open-vm-tools >/dev/null 2>&1; then
            vm_tools_state="present"
        fi
        ;;
esac

if [ "$vm_tools_state" = "present" ]; then
    Log-Warn "RECOMMENDED: reboot the VM to finish open-vm-tools cleanup."
    Log-Info ""
fi

Log-Info "Log saved to: $LOG_FILE"
Log-Info ""
Log-Info "5-Post-Migration.sh v4.1 complete."