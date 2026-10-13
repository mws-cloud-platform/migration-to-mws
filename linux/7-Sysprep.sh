#!/bin/bash
# =======================================================================
# FILE: 7-Sysprep.sh
# VERSION: 4.1
# =======================================================================
# Generalize the system for golden image creation.
#
# This is IRREVERSIBLE:
#   - cloud-init state is reset
#   - SSH host keys are removed
#   - machine-id is cleared
#   - shell history is removed
#
# After this script, VM should be shut down and exported as a template.
#
# Run ONLY after 6-Cloud-Init.sh.
#
# Usage:
#   sudo ./7-Sysprep.sh
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
LOG_FILE="$LOGS_DIR/7-Sysprep_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source libraries ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-steps-runtime.sh"

# =======================================================================
# MAIN
# =======================================================================

Log-Info "=== 7-Sysprep.sh v4.1 ==="
Log-Info "Log file: $LOG_FILE"

# -------------------------------------------------------------------
# STEP 0: PREFLIGHT
# -------------------------------------------------------------------
Log-Section "STEP 0. PREFLIGHT"

Get-LinuxState

# cloud-init must be installed
if [ "$CLOUD_INIT_READY" != "yes" ]; then
    Log-Error "cloud-init is not installed."
    Log-Error "Run 6-Cloud-Init.sh first."
    exit 1
fi

Log-Success "cloud-init: installed"
Log-Info "Distro:      $DISTRO_PRETTY_NAME"
Log-Info "Environment: $ENVIRONMENT"

# -------------------------------------------------------------------
# STEP 1: WARNING
# -------------------------------------------------------------------
Log-Section "STEP 1. WARNING"

Log-Info ""
Log-Warn "=========================================================="
Log-Warn " SYSPREP IS IRREVERSIBLE"
Log-Warn "=========================================================="
Log-Info ""
Log-Warn "This script will:"
Log-Warn "  - Reset cloud-init state"
Log-Warn "  - Remove SSH host keys (regenerated on next boot)"
Log-Warn "  - Clear machine-id (regenerated on next boot)"
Log-Warn "  - Clear shell history"
Log-Info ""
Log-Warn "After this, the system is ready for cloning."
Log-Warn "Use this ONLY to create a golden image for mass deployment."
Log-Warn "Do NOT use on a working production VM."
Log-Info ""

printf "Type YES (uppercase) to proceed with sysprep: "
read -r confirm
if [ "$confirm" != "YES" ]; then
    Log-Info "Aborted by user. No changes made."
    exit 0
fi

Log-Success "User confirmed."

# -------------------------------------------------------------------
# STEP 2: RUN SYSPREP
# -------------------------------------------------------------------
if ! Step-RunSysprep; then
    Log-Error "Sysprep failed."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 3: SHUTDOWN
# -------------------------------------------------------------------
Log-Section "STEP 3. SHUTDOWN"

Log-Info ""
Log-Success "Sysprep completed."
Log-Info ""
Log-Info "The VM should now be shut down and exported as a template."
Log-Info ""
Log-Info "PAUSE: press Enter to SHUTDOWN the VM."
printf "Press Enter to shutdown: "
read -r _

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