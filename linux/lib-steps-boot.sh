#!/bin/bash
# =======================================================================
# FILE: lib-steps-boot.sh
# VERSION: 4.1
# =======================================================================
# Boot-critical transformation steps for Linux migration.
#
# Contains:
#   - Step-ConvertGpt   MBR -> GPT conversion (sgdisk backup/restore)
#   - Step-CreateESP    Create EFI System Partition if missing
#   - Step-Initramfs    Rebuild initramfs with virtio modules
#   - Step-GrubEfi      Install GRUB2 EFI bootloader
#   - Step-VerifyBoot   Verify boot partition and files
#
# Requires:
#   - lib-core.sh (for logging, detect, handlers)
#
# This is a LIBRARY. Do not run directly.
# Source from 4-Migration.sh via:
#     source "$SCRIPT_DIR/lib-core.sh"
#     source "$SCRIPT_DIR/lib-steps-boot.sh"
# =======================================================================

# Guard against direct execution
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "lib-steps-boot.sh is a library. Do not run it directly."
    exit 1
fi

# =======================================================================
# STEP: CONVERT MBR TO GPT
# =======================================================================
# Safe conversion via backup / convert / restore:
#   1. sgdisk -b  → save MBR partition table to file
#   2. sgdisk -g  → create empty GPT
#   3. sgdisk -l  → restore partition entries from backup
#
# Partition data is not touched; only the partition table is rewritten.
# On failure the backup file is preserved for manual recovery.
# =======================================================================

Step-ConvertGpt() {
    Log-Section "STEP: Convert MBR to GPT"

    if [ "$DISK_STYLE" = "gpt" ]; then
        Log-Skip "STEP-ConvertGpt" "disk already GPT"
        return 0
    fi

    if [ "$DISK_STYLE" != "mbr" ]; then
        Log-Error "Cannot determine disk style. Aborting conversion."
        return 1
    fi

    if ! Command-Exists sgdisk; then
        Log-Error "sgdisk not available. Cannot convert safely."
        Log-Error "Install gdisk: apt install gdisk / dnf install gdisk"
        return 1
    fi

    Log-Info "System disk: $SYS_DISK"
    Log-Info "Current style: MBR"

    local backup="/tmp/mws-mbr-backup.bin"

    # --- 1. Backup MBR partition table ---
    Log-Action "Backing up MBR partition table to $backup"
    if ! sgdisk -b "$backup" "$SYS_DISK"; then
        Log-Error "Backup failed. Cannot proceed safely."
        return 1
    fi

    if [ ! -s "$backup" ]; then
        Log-Error "Backup file is empty: $backup"
        return 1
    fi

    # --- 2. Create empty GPT ---
    Log-Action "Converting to GPT (creating empty GPT table)"
    if ! sgdisk -g "$SYS_DISK"; then
        Log-Error "sgdisk -g failed. GPT not created."
        # Attempt to restore anyway, in case of partial state
        sgdisk -l "$backup" "$SYS_DISK" 2>/dev/null || true
        return 1
    fi

    # --- 3. Restore partitions from backup ---
    Log-Action "Restoring partition entries from backup"
    if ! sgdisk -l "$backup" "$SYS_DISK"; then
        Log-Error "sgdisk -l failed. Partitions not restored."
        Log-Warn "Backup file preserved at: $backup"
        Log-Warn "Manual recovery: sgdisk -l $backup $SYS_DISK"
        return 1
    fi

    Log-Success "Disk converted to GPT"

    # --- 4. Re-read partition table ---
    if Command-Exists partprobe; then
        partprobe "$SYS_DISK" 2>/dev/null || true
    fi
    if Command-Exists blockdev; then
        blockdev --rereadpt "$SYS_DISK" 2>/dev/null || true
    fi
    sleep 2

    # --- 5. Re-detect state ---
    Detect-DiskState
    Log-Info "After conversion: style=$DISK_STYLE, EFI partition=$HAS_EFI"

    # --- 6. Sanity check ---
    if [ "$DISK_STYLE" != "gpt" ]; then
        Log-Error "Disk is not GPT after conversion (detected: $DISK_STYLE)"
        Log-Warn "Backup file preserved at: $backup"
        return 1
    fi

    # --- 7. Cleanup backup on success ---
    Log-Action "Removing backup file (conversion successful)"
    rm -f "$backup" 2>/dev/null || true

    Log-Success "MBR -> GPT conversion complete"
    return 0
}

# =======================================================================
# STEP: CREATE ESP IF MISSING
# =======================================================================

Step-CreateESP() {
    Log-Section "STEP: Ensure EFI System Partition"

    if [ "$HAS_EFI" = "yes" ]; then
        Log-Skip "STEP-CreateESP" "ESP already exists"
        return 0
    fi

    if [ "$DISK_STYLE" != "gpt" ]; then
        Log-Error "Cannot create ESP on non-GPT disk."
        return 1
    fi

    if ! Command-Exists sgdisk; then
        Log-Error "sgdisk not available. Cannot create ESP."
        return 1
    fi

    Log-Action "Creating ESP (100 MB) at the earliest available space"

    local esp_size="100M"

    if ! sgdisk -n 0:0:+"$esp_size" -t 0:ef00 -c 0:"EFI System Partition" "$SYS_DISK"; then
        Log-Error "sgdisk failed to create ESP."
        return 1
    fi

    if Command-Exists partprobe; then
        partprobe "$SYS_DISK" 2>/dev/null || true
    fi
    sleep 2

    Detect-DiskState
    Log-Info "After creation: HAS_EFI=$HAS_EFI"

    if [ "$HAS_EFI" != "yes" ]; then
        Log-Error "ESP was created but not detected. Manual check needed."
        return 1
    fi

    Log-Success "ESP created"
    return 0
}

# =======================================================================
# STEP: REBUILD INITRAMFS
# =======================================================================

Step-Initramfs() {
    Log-Section "STEP: Rebuild initramfs with virtio modules"

    if [ "$HAS_INITRAMFS_TOOL" != "yes" ]; then
        Log-Error "No initramfs tool available."
        return 1
    fi

    local virtio_modules="virtio_pci virtio_scsi virtio_blk virtio_net"

    case "$DISTRO_FAMILY" in
        rhel)
            local conf_dir="/etc/dracut.conf.d"
            Ensure-Dir "$conf_dir"
            local conf_file="$conf_dir/99-mws-virtio.conf"
            Log-Action "Writing $conf_file"
            cat > "$conf_file" <<EOF
# Added by migration-to-mws toolkit.
# Force virtio modules into initramfs for KVM boot.
add_drivers+=" virtio_pci virtio_scsi virtio_blk virtio_net "
EOF
            ;;
        debian)
            local conf_file="/etc/initramfs-tools/modules"
            if [ -f "$conf_file" ]; then
                for mod in $virtio_modules; do
                    if ! grep -qE "^${mod}\$" "$conf_file" 2>/dev/null; then
                        Log-Action "Adding $mod to $conf_file"
                        echo "$mod" >> "$conf_file"
                    fi
                done
            else
                Log-Warn "$conf_file not found. Trying /etc/initramfs-tools/modules.d/"
                Ensure-Dir "/etc/initramfs-tools/modules.d"
                cat > "/etc/initramfs-tools/modules.d/99-mws-virtio" <<EOF
# Added by migration-to-mws toolkit.
virtio_pci
virtio_scsi
virtio_blk
virtio_net
EOF
            fi
            ;;
        *)
            Log-Warn "Unknown family for initramfs config. Skipping config step."
            ;;
    esac

    Log-Action "Rebuilding initramfs"
    if ! Rebuild-Initramfs; then
        Log-Error "initramfs rebuild failed."
        return 1
    fi

    Log-Success "initramfs rebuilt with virtio modules"
    return 0
}

# =======================================================================
# STEP: INSTALL GRUB2 EFI
# =======================================================================

Step-GrubEfi() {
    Log-Section "STEP: Install GRUB2 EFI"

    if ! Command-Exists grub-install; then
        Log-Warn "grub-install not found. Trying to install."
        case "$DISTRO_FAMILY" in
            debian) Install-Pkg grub-efi-amd64 ;;
            rhel)   Install-Pkg grub2-efi-x64 ;;
            *)
                Log-Error "Cannot install GRUB2 on $DISTRO_FAMILY"
                return 1
                ;;
        esac
        if ! Command-Exists grub-install; then
            Log-Error "grub-install still not available after install attempt."
            return 1
        fi
    fi

    if [ "$HAS_EFI" != "yes" ]; then
        Log-Error "No ESP partition. Run Step-CreateESP first."
        return 1
    fi

    local esp_part=""
    if Command-Exists lsblk; then
        esp_part=$(lsblk -no NAME,PARTTYPE "$SYS_DISK" 2>/dev/null | \
                   awk -v t="$ESP_GPT_TYPE" 'tolower($2)==tolower(t) {print "/dev/"$1; exit}')
    fi

    if [ -z "$esp_part" ]; then
        Log-Error "Cannot locate ESP partition."
        return 1
    fi

    Log-Info "ESP partition: $esp_part"

    local mnt="/mnt/mws-esp"
    Ensure-Dir "$mnt"

    if Mountpoint-Exists "$mnt"; then
        Log-Warn "$mnt is already mounted. Unmounting first."
        umount "$mnt" 2>/dev/null || true
    fi

    if ! mount "$esp_part" "$mnt"; then
        Log-Error "Failed to mount ESP at $mnt"
        return 1
    fi

    Log-Action "Running grub-install --target=x86_64-efi"
    local grub_rc=0
    grub-install --target=x86_64-efi \
                 --efi-directory="$mnt" \
                 --bootloader-id=mws \
                 --recheck \
                 --no-nvram 2>&1 || grub_rc=$?

    if [ "$grub_rc" -ne 0 ]; then
        Log-Warn "grub-install returned $grub_rc. Trying without --no-nvram."
        grub_rc=0
        grub-install --target=x86_64-efi \
                     --efi-directory="$mnt" \
                     --bootloader-id=mws \
                     --recheck 2>&1 || grub_rc=$?
    fi

    if [ "$grub_rc" -ne 0 ]; then
        Log-Error "grub-install failed (exit $grub_rc)."
        umount "$mnt" 2>/dev/null || true
        return 1
    fi

    # Create fallback bootloader \EFI\BOOT\BOOTX64.EFI
    Log-Action "Creating fallback bootloader /EFI/BOOT/BOOTX64.EFI"
    Ensure-Dir "$mnt/EFI/BOOT"

    local grub_src=""
    for candidate in \
        "$mnt/EFI/mws/grubx64.efi" \
        "$mnt/EFI/centos/grubx64.efi" \
        "$mnt/EFI/redhat/grubx64.efi" \
        "$mnt/EFI/debian/grubx64.efi" \
        "$mnt/EFI/ubuntu/grubx64.efi" \
        "$mnt/EFI/fedora/grubx64.efi" \
        "$mnt/EFI/rocky/grubx64.efi" \
        "$mnt/EFI/almalinux/grubx64.efi" \
        "$mnt/EFI/ol/grubx64.efi"
    do
        if [ -f "$candidate" ]; then
            grub_src="$candidate"
            break
        fi
    done

    if [ -n "$grub_src" ]; then
        cp "$grub_src" "$mnt/EFI/BOOT/BOOTX64.EFI"
        Log-Success "Fallback created from: $grub_src"
    else
        Log-Warn "Cannot find grubx64.efi in ESP. Fallback not created."
        Log-Warn "Files in $mnt/EFI:"
        ls -la "$mnt/EFI/" 2>/dev/null || true
    fi

    # Unmount ESP
    sync
    if ! umount "$mnt"; then
        Log-Warn "Failed to unmount $mnt. Check manually."
    fi

    # Regenerate GRUB config
    if Command-Exists grub-mkconfig; then
        Log-Action "Regenerating GRUB config (grub-mkconfig)"
        grub-mkconfig -o /boot/grub/grub.cfg 2>&1 || \
            Log-Warn "grub-mkconfig returned non-zero."
    elif Command-Exists grub2-mkconfig; then
        Log-Action "Regenerating GRUB config (grub2-mkconfig)"
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>&1 || \
            Log-Warn "grub2-mkconfig returned non-zero."
    else
        Log-Warn "No grub-mkconfig/grub2-mkconfig found. GRUB config not regenerated."
    fi

    Log-Success "GRUB2 EFI installed"
    return 0
}

# =======================================================================
# STEP: VERIFY BOOT
# =======================================================================

Step-VerifyBoot() {
    Log-Section "STEP: Verify boot configuration"

    local issues=0
    local ok=0

    # 1. Disk style
    if [ "$DISK_STYLE" = "gpt" ]; then
        Log-Success "  [+] Disk style: GPT"
        ok=$((ok+1))
    else
        Log-Warn "  [!] Disk style: $DISK_STYLE (expected GPT)"
        issues=$((issues+1))
    fi

    # 2. ESP present
    if [ "$HAS_EFI" = "yes" ]; then
        Log-Success "  [+] ESP partition present"
        ok=$((ok+1))
    else
        Log-Warn "  [!] ESP partition missing"
        issues=$((issues+1))
    fi

    # 3. GRUB EFI files in ESP
    local esp_part=""
    if Command-Exists lsblk; then
        esp_part=$(lsblk -no NAME,PARTTYPE "$SYS_DISK" 2>/dev/null | \
                   awk -v t="$ESP_GPT_TYPE" 'tolower($2)==tolower(t) {print "/dev/"$1; exit}')
    fi

    if [ -n "$esp_part" ]; then
        local mnt="/mnt/mws-esp-verify"
        Ensure-Dir "$mnt"

        if Mountpoint-Exists "$mnt"; then
            umount "$mnt" 2>/dev/null || true
        fi

        if mount "$esp_part" "$mnt" 2>/dev/null; then
            if [ -f "$mnt/EFI/BOOT/BOOTX64.EFI" ]; then
                Log-Success "  [+] Fallback /EFI/BOOT/BOOTX64.EFI present"
                ok=$((ok+1))
            else
                Log-Warn "  [!] Fallback /EFI/BOOT/BOOTX64.EFI missing"
                issues=$((issues+1))
            fi

            local found_grub_dir="no"
            for d in "$mnt/EFI/mws" "$mnt/EFI/debian" "$mnt/EFI/redhat" \
                     "$mnt/EFI/centos" "$mnt/EFI/ubuntu" "$mnt/EFI/fedora" \
                     "$mnt/EFI/rocky" "$mnt/EFI/almalinux" "$mnt/EFI/ol"; do
                if [ -d "$d" ]; then
                    found_grub_dir="yes"
                    break
                fi
            done

            if [ "$found_grub_dir" = "yes" ]; then
                Log-Success "  [+] GRUB EFI directory present"
                ok=$((ok+1))
            else
                Log-Warn "  [!] No GRUB EFI directory in ESP"
                issues=$((issues+1))
            fi

            umount "$mnt" 2>/dev/null || true
        else
            Log-Warn "  [!] Cannot mount ESP for verification"
            issues=$((issues+1))
        fi
    else
        Log-Warn "  [!] Cannot locate ESP for verification"
        issues=$((issues+1))
    fi

    # 4. initramfs present
    local found_initramfs="no"
    for f in /boot/initramfs-*.img /boot/initrd.img-* /boot/initramfs-linux*.img; do
        if [ -f "$f" ]; then
            found_initramfs="yes"
            break
        fi
    done

    if [ "$found_initramfs" = "yes" ]; then
        Log-Success "  [+] initramfs present"
        ok=$((ok+1))
    else
        Log-Warn "  [!] No initramfs found in /boot"
        issues=$((issues+1))
    fi

    # 5. virtio in initramfs
    if [ "$VIRTIO_IN_INITRAMFS" = "yes" ]; then
        Log-Success "  [+] virtio_scsi present in initramfs"
        ok=$((ok+1))
    elif [ "$VIRTIO_IN_INITRAMFS" = "maybe" ]; then
        Log-Warn "  [!] virtio_scsi module found but not loaded"
        issues=$((issues+1))
    else
        Log-Warn "  [!] virtio_scsi not found in initramfs"
        issues=$((issues+1))
    fi

    Log-Info ""
    Log-Info "  Boot verification: $ok OK, $issues issue(s)"
    if [ "$issues" -gt 0 ]; then
        return 1
    fi
    return 0
}

# =======================================================================
# END OF FILE
# =======================================================================