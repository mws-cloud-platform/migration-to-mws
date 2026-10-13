#!/bin/bash
# =======================================================================
# FILE: 1-run.sh
# VERSION: 4.1
# =======================================================================
# Entry point for migration-to-mws toolkit (Linux).
#
# Usage:
#   sudo ./1-run.sh
#
# What it does:
#   - Checks root
#   - Resolves script directory
#   - Hands off to 2-Orchestrator.sh
# =======================================================================

set -u

# --- Root check ---
if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: must be run as root."
    echo "Run: sudo $0"
    exit 1
fi

# --- Resolve script directory ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SCRIPT_DIR

# --- Hand off to orchestrator ---
exec "$SCRIPT_DIR/2-Orchestrator.sh"