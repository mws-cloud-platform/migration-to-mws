#!/bin/bash
# =======================================================================
# FILE: 6-Cloud-Init.sh
# VERSION: 4.1
# =======================================================================
# Install and configure cloud-init for MWS Cloud Platform.
#
# Optional: needed if you want MWS to inject hostname, network settings
# and user data via metadata on first boot.
#
# Does NOT run sysprep - use 7-Sysprep.sh for that.
# Idempotent: safe to run multiple times.
#
# Usage:
#   sudo ./6-Cloud-Init.sh
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
LOG_FILE="$LOGS_DIR/6-Cloud-Init_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source libraries ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-steps-runtime.sh"

# =======================================================================
# MAIN
# =======================================================================

Log-Info "=== 6-Cloud-Init.sh v4.1 ==="
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
Log-Info "Package mgr: $PKG_MANAGER"
Log-Info "cloud-init:  $CLOUD_INIT_READY"

if [ "$DISTRO_FAMILY" = "unknown" ]; then
    Log-Error "Unsupported distribution family. Cannot install cloud-init."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 1: INSTALL AND CONFIGURE CLOUD-INIT
# -------------------------------------------------------------------
if ! Step-CloudInit; then
    Log-Error "cloud-init installation or configuration failed."
    exit 1
fi

# -------------------------------------------------------------------
# STEP 2: SUMMARY
# -------------------------------------------------------------------
Log-Section "STEP 2. SUMMARY"

# Re-check state
Detect-CloudInitReady

Log-Info ""
Log-Info "---- STATUS ----"
if [ "$CLOUD_INIT_READY" = "yes" ]; then
    Log-Success "  cloud-init: installed"
    if Command-Exists cloud-init; then
        Log-Info "  version: $(cloud-init --version 2>/dev/null | head -n1 || echo 'unknown')"
    fi
else
    Log-Error "  cloud-init: NOT installed"
fi

cfg_dir="/etc/cloud/cloud.cfg.d"
for cfg in 99-mws-datasource.cfg 99-mws-network.cfg 99-mws-users.cfg; do
    if [ -f "$cfg_dir/$cfg" ]; then
        Log-Success "  $cfg: present"
    else
        Log-Warn "  $cfg: MISSING"
    fi
done

Log-Info ""
Log-Success "cloud-init installation complete."
Log-Info ""
Log-Info "NEXT STEP:"
Log-Info "  Run 7-Sysprep.sh to generalize the system before export"
Log-Info "  as a golden image. Without generalization, cloud-init may not"
Log-Info "  inject metadata on first boot in MWS."
Log-Info ""
Log-Info "Log saved to: $LOG_FILE"
Log-Info ""
Log-Info "6-Cloud-Init.sh v4.1 complete."