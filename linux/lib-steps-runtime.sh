#!/bin/bash
# =======================================================================
# FILE: lib-steps-runtime.sh
# VERSION: 4.1
# =======================================================================
# Runtime steps for Linux migration.
#
# Contains:
#   - Step-CloudInit       Install and configure cloud-init for MWS
#   - Step-PostCleanup     Remove VMware leftovers
#   - Step-RunSysprep      virt-sysprep / cloud-init clean
#   - Step-VerifyRuntime   Final runtime verification
#
# Requires:
#   - lib-core.sh  (logging, detect, handlers)
#
# This is a LIBRARY. Do not run directly.
# Source from 5-Post-Migration.sh, 6-Cloud-Init.sh, 7-Sysprep.sh.
# =======================================================================

# Guard against direct execution
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "lib-steps-runtime.sh is a library. Do not run it directly."
    exit 1
fi

# =======================================================================
# STEP: INSTALL AND CONFIGURE CLOUD-INIT
# =======================================================================

Step-CloudInit() {
    Log-Section "STEP: Install and configure cloud-init"

    # 1. Ensure cloud-init is installed
    if ! Ensure-CloudInit; then
        Log-Error "cloud-init installation failed."
        return 1
    fi

    # 2. Deploy MWS-specific configs
    local cfg_src_dir="$SCRIPT_DIR/configs-cloud-init"
    local cfg_dst_dir="/etc/cloud/cloud.cfg.d"

    Ensure-Dir "$cfg_dst_dir"

    for cfg in 99-mws-datasource.cfg 99-mws-network.cfg 99-mws-users.cfg; do
        if [ -f "$cfg_src_dir/$cfg" ]; then
            Log-Action "Deploying $cfg"
            cp "$cfg_src_dir/$cfg" "$cfg_dst_dir/$cfg"
        else
            Log-Warn "Config source not found: $cfg_src_dir/$cfg"
        fi
    done

    # 3. Enable cloud-init services (systemd)
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        Log-Action "Enabling cloud-init services"
        systemctl enable cloud-init 2>/dev/null || true
        systemctl enable cloud-init-local 2>/dev/null || true
        systemctl enable cloud-config 2>/dev/null || true
        systemctl enable cloud-final 2>/dev/null || true
    fi

    # 4. Sanity check
    if Command-Exists cloud-init; then
        Log-Success "cloud-init installed and configured"
        return 0
    else
        Log-Error "cloud-init not found after installation."
        return 1
    fi
}

# =======================================================================
# STEP: POST-MIGRATION CLEANUP
# =======================================================================

Step-PostCleanup() {
    Log-Section "STEP: Post-migration cleanup"

    # --- 1. open-vm-tools ---
    Log-Info "Checking for open-vm-tools"
    local vm_tools_found="no"
    case "$PKG_MANAGER" in
        apt)
            if dpkg -l 2>/dev/null | grep -qE '^ii\s+open-vm-tools'; then
                vm_tools_found="yes"
            fi
            ;;
        dnf|yum)
            if rpm -q open-vm-tools >/dev/null 2>&1; then
                vm_tools_found="yes"
            fi
            ;;
    esac

    if [ "$vm_tools_found" = "yes" ]; then
        Log-Action "Removing open-vm-tools"
        case "$PKG_MANAGER" in
            apt)
                DEBIAN_FRONTEND=noninteractive apt-get remove -y open-vm-tools 2>&1 || \
                    Log-Warn "open-vm-tools removal returned non-zero."
                ;;
            dnf|yum)
                "$PKG_MANAGER" remove -y open-vm-tools 2>&1 || \
                    Log-Warn "open-vm-tools removal returned non-zero."
                ;;
        esac
    else
        Log-Info "open-vm-tools not installed"
    fi

    # --- 2. VMware kernel modules ---
    Log-Info "Checking for VMware kernel modules"
    local vm_modules
    vm_modules=$(lsmod 2>/dev/null | awk '/^vmw_|^vmxnet|^vmhgfs|^vsock/ {print $1}')
    if [ -n "$vm_modules" ]; then
        Log-Action "Unloading VMware kernel modules"
        for mod in $vm_modules; do
            rmmod "$mod" 2>/dev/null || true
        done
    else
        Log-Info "No VMware kernel modules loaded"
    fi

    # --- 3. udev persistent net rules ---
    Log-Info "Checking udev persistent net rules"
    local udev_rules="/etc/udev/rules.d/70-persistent-net.rules"
    if [ -f "$udev_rules" ]; then
        Log-Action "Removing $udev_rules"
        rm -f "$udev_rules"
    fi

    # Modern systemd systems use /etc/systemd/network/*.link with MACAddress
    if [ -d /etc/systemd/network ]; then
        local link_files
        link_files=$(grep -l '^MACAddress=' /etc/systemd/network/*.link 2>/dev/null)
        if [ -n "$link_files" ]; then
            Log-Action "Removing MACAddress lines from systemd network .link files"
            for f in $link_files; do
                sed -i '/^MACAddress=/d' "$f"
            done
        fi
    fi

    # --- 4. Old network interface names in ifcfg (RHEL-family) ---
    if [ -d /etc/sysconfig/network-scripts ]; then
        Log-Info "Checking /etc/sysconfig/network-scripts"
        local ifcfg_count
        ifcfg_count=$(ls /etc/sysconfig/network-scripts/ifcfg-* 2>/dev/null | wc -l)
        Log-Info "  ifcfg files found: $ifcfg_count"
    fi

    # --- 5. VMware tools leftover directories ---
    for d in /usr/lib/vmware-tools /usr/lib/open-vm-tools /etc/vmware-tools; do
        if [ -d "$d" ]; then
            Log-Action "Removing leftover $d"
            rm -rf "$d"
        fi
    done

    Log-Success "Post-migration cleanup complete"
    return 0
}

# =======================================================================
# STEP: RUN SYSPREP (virt-sysprep / cloud-init clean)
# =======================================================================

Step-RunSysprep() {
    Log-Section "STEP: Generalize system for cloning"

    # virt-sysprep works on OFFLINE disks only.
    # If the system is running (we are inside it), use cloud-init clean.
    local method=""

    if Command-Exists virt-sysprep; then
        Log-Info "virt-sysprep available. However, current system is RUNNING."
        Log-Info "virt-sysprep requires the disk to be offline (not the root disk)."
        Log-Info "Falling back to cloud-init clean."
        method="cloud-init-clean"
    fi

    if [ -z "$method" ]; then
        if Command-Exists cloud-init; then
            method="cloud-init-clean"
        else
            Log-Error "Neither virt-sysprep nor cloud-init available."
            return 1
        fi
    fi

    case "$method" in
        cloud-init-clean)
            Log-Action "Running: cloud-init clean --logs --seed"
            if cloud-init clean --logs --seed 2>&1; then
                Log-Success "cloud-init state reset"
            else
                Log-Warn "cloud-init clean returned non-zero."
            fi

            # Remove SSH host keys (regenerated on next boot)
            Log-Action "Removing SSH host keys (will be regenerated)"
            rm -f /etc/ssh/ssh_host_* 2>/dev/null || true

            # Clear machine-id (regenerated on boot)
            if [ -f /etc/machine-id ]; then
                Log-Action "Clearing /etc/machine-id"
                : > /etc/machine-id
            fi
            if [ -f /var/lib/dbus/machine-id ]; then
                rm -f /var/lib/dbus/machine-id
            fi

            # Clear bash history
            Log-Action "Clearing shell history"
            rm -f /root/.bash_history 2>/dev/null || true
            for h in /home/*/.bash_history; do
                [ -f "$h" ] && rm -f "$h"
            done

            Log-Success "System generalized (cloud-init clean)"
            ;;
        *)
            Log-Error "Unknown sysprep method: $method"
            return 1
            ;;
    esac

    return 0
}

# =======================================================================
# STEP: FINAL VERIFICATION
# =======================================================================

Step-VerifyRuntime() {
    Log-Section "STEP: Final runtime verification"

    local issues=0
    local ok=0

    # 1. cloud-init status
    if Command-Exists cloud-init; then
        Log-Success "  [+] cloud-init: installed"
        ok=$((ok+1))
    else
        Log-Warn "  [!] cloud-init: not installed"
        issues=$((issues+1))
    fi

    # 2. cloud-init configs
    local cfg_dir="/etc/cloud/cloud.cfg.d"
    local cfg_count=0
    for cfg in 99-mws-datasource.cfg 99-mws-network.cfg 99-mws-users.cfg; do
        if [ -f "$cfg_dir/$cfg" ]; then
            cfg_count=$((cfg_count+1))
        fi
    done
    if [ "$cfg_count" -gt 0 ]; then
        Log-Success "  [+] MWS cloud-init configs: $cfg_count present"
        ok=$((ok+1))
    else
        Log-Warn "  [!] MWS cloud-init configs: not deployed"
        issues=$((issues+1))
    fi

    # 3. open-vm-tools removed
    local vm_tools_still="no"
    case "$PKG_MANAGER" in
        apt)
            if dpkg -l 2>/dev/null | grep -qE '^ii\s+open-vm-tools'; then
                vm_tools_still="yes"
            fi
            ;;
        dnf|yum)
            if rpm -q open-vm-tools >/dev/null 2>&1; then
                vm_tools_still="yes"
            fi
            ;;
    esac
    if [ "$vm_tools_still" = "yes" ]; then
        Log-Warn "  [!] open-vm-tools still installed"
        issues=$((issues+1))
    else
        Log-Success "  [+] open-vm-tools: not present"
        ok=$((ok+1))
    fi

    # 4. udev persistent net rules removed
    if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
        Log-Warn "  [!] udev persistent net rules still present"
        issues=$((issues+1))
    else
        Log-Success "  [+] udev persistent net rules: clean"
        ok=$((ok+1))
    fi

    # 5. virtio in initramfs
    if [ "$VIRTIO_IN_INITRAMFS" = "yes" ]; then
        Log-Success "  [+] virtio_scsi loaded in kernel"
        ok=$((ok+1))
    else
        Log-Warn "  [!] virtio_scsi not loaded (may be OK if not needed yet)"
        issues=$((issues+1))
    fi

    # 6. Network accessible (basic gateway check)
    if Command-Exists ip; then
        local gw
        gw=$(ip route 2>/dev/null | awk '/^default/ {print $3; exit}')
        if [ -n "$gw" ]; then
            Log-Success "  [+] Default gateway: $gw"
            ok=$((ok+1))
        else
            Log-Warn "  [!] No default gateway configured"
            issues=$((issues+1))
        fi
    fi

    Log-Info ""
    Log-Info "  Runtime verification: $ok OK, $issues issue(s)"
    if [ "$issues" -gt 0 ]; then
        return 1
    fi
    return 0
}

# =======================================================================
# END OF FILE
# =======================================================================