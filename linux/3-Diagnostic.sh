#!/bin/bash
# =======================================================================
# FILE: 3-Diagnostic.sh
# VERSION: 4.1
# =======================================================================
# Read-only diagnostic for migration-to-mws toolkit (Linux).
#
# Sections:
#   §0   STATE SUMMARY (Get-LinuxState)
#   §1   Distribution / Kernel
#   §2   Environment / Hypervisor
#   §3   Disk / Partitions / Filesystem
#   §4   Bootloader / EFI
#   §5   initramfs / virtio modules
#   §6   Network
#   §7   cloud-init
#   §8   VMware leftovers
#   §9   Time / Timezone / NTP
#   §10  Kernel modules
#   §11  Bootloader files
#   §12  COMPARISON vs reference KVM
#   §13  VERDICT
#
# Usage:
#   sudo ./3-Diagnostic.sh
#
# Requires:
#   - lib-core.sh
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
LOG_FILE="$LOGS_DIR/3-Diagnostic_v4.1_${TIMESTAMP}_${HOSTNAME_SHORT}.log"
export LOG_FILE

# --- Source core library ---
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-core.sh"

# =======================================================================
# HELPERS
# =======================================================================

Out-Cmd() {
    # Out-Cmd <title> <command...>
    local title="$1"
    shift
    Log-Info ""
    Log-Info "--- $title ---"
    if "$@" 2>&1 | while IFS= read -r line; do Log-Info "  $line"; done; then
        :
    fi
}

Out-Cmd-Sh() {
    # Out-Cmd-Sh <title> <shell snippet>
    local title="$1"
    local snippet="$2"
    Log-Info ""
    Log-Info "--- $title ---"
    bash -c "$snippet" 2>&1 | while IFS= read -r line; do
        Log-Info "  $line"
    done
}

# =======================================================================
# HEADER
# =======================================================================

Log-Info "==============================================================="
Log-Info "=== 3-Diagnostic.sh v4.1 ==="
Log-Info "==============================================================="
Log-Info "Generated: $(date '+%Y-%m-%d %H:%M:%S')"
Log-Info "Computer:  $(hostname)"
Log-Info "Report:    $LOG_FILE"
Log-Info ""

# =======================================================================
# §0 STATE SUMMARY
# =======================================================================

Log-Section "0. STATE SUMMARY (Get-LinuxState)"

Get-LinuxState

Log-Info ""
Log-Info "  Distro        : $DISTRO_PRETTY_NAME"
Log-Info "  Family        : $DISTRO_FAMILY"
Log-Info "  Supported     : $DISTRO_SUPPORTED"
Log-Info "  Init system   : $INIT_SYSTEM"
Log-Info "  Bootloader    : $BOOTLOADER"
Log-Info "  UEFI boot     : $HAS_UEFI_BOOT"
Log-Info "  Package mgr   : $PKG_MANAGER"
Log-Info "  Environment   : $ENVIRONMENT"
Log-Info "  System disk   : $SYS_DISK"
Log-Info "  Disk style    : $DISK_STYLE"
Log-Info "  Root FS       : $ROOT_FSTYPE"
Log-Info "  Root RW       : $ROOT_RW"
Log-Info "  EFI partition : $HAS_EFI"
Log-Info "  LVM on root   : $HAS_LVM"
Log-Info "  LUKS on root  : $HAS_LUKS"
Log-Info "  Free space    : ${FREE_SPACE_GB} GB"
Log-Info "  cloud-init    : $CLOUD_INIT_READY"
Log-Info "  virtio in initramfs : $VIRTIO_IN_INITRAMFS"
Log-Info "  Partition tool: $HAS_PARTITION_TOOL"
Log-Info "  Initramfs tool: $HAS_INITRAMFS_TOOL"
Log-Info ""
if [ -n "$BLOCKER" ]; then
    Log-Warn "  Blocker: $BLOCKER"
else
    Log-Info "  Blocker: none"
fi

# =======================================================================
# §1 DISTRIBUTION / KERNEL
# =======================================================================

Log-Section "1. DISTRIBUTION / KERNEL"

Out-Cmd "uname -a" uname -a

Out-Cmd-Sh "/etc/os-release" 'cat /etc/os-release 2>/dev/null'

Out-Cmd-Sh "Kernel version" 'uname -r'

Out-Cmd-Sh "Init system (systemctl)" 'systemctl --version 2>/dev/null | head -n1 || echo "not systemd"'

Out-Cmd-Sh "Package manager version" '
case "'"$PKG_MANAGER"'" in
    apt)  apt --version 2>/dev/null | head -n1 ;;
    dnf)  dnf --version 2>/dev/null | head -n1 ;;
    yum)  yum --version 2>/dev/null | head -n1 ;;
    *)    echo "unknown" ;;
esac
'

# =======================================================================
# §2 ENVIRONMENT / HYPERVISOR
# =======================================================================

Log-Section "2. ENVIRONMENT / HYPERVISOR"

Out-Cmd-Sh "DMI sys_vendor" 'cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "n/a"'

Out-Cmd-Sh "DMI product_name" 'cat /sys/class/dmi/id/product_name 2>/dev/null || echo "n/a"'

Out-Cmd-Sh "DMI bios_vendor" 'cat /sys/class/dmi/id/bios_vendor 2>/dev/null || echo "n/a"'

Out-Cmd-Sh "systemd-detect-virt" 'systemd-detect-virt 2>/dev/null || echo "n/a"'

Out-Cmd-Sh "PCI devices (virtio, vmware)" '
lspci 2>/dev/null | grep -iE "virtio|vmware" || echo "none"
'

# =======================================================================
# §3 DISK / PARTITIONS / FILESYSTEM
# =======================================================================

Log-Section "3. DISK / PARTITIONS / FILESYSTEM"

Out-Cmd-Sh "lsblk (tree)" 'lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,PARTTYPE 2>/dev/null'

Out-Cmd-Sh "findmnt (full)" 'findmnt 2>/dev/null | head -n30'

Out-Cmd-Sh "blkid" 'blkid 2>/dev/null'

Out-Cmd-Sh "df -hT" 'df -hT 2>/dev/null'

Out-Cmd-Sh "parted print" '
if [ -n "$SYS_DISK" ] && command -v parted >/dev/null 2>&1; then
    parted -s "$SYS_DISK" print 2>/dev/null
else
    echo "skipped: no sys_disk or parted"
fi
'

Out-Cmd-Sh "fstab" 'cat /etc/fstab 2>/dev/null'

# =======================================================================
# §4 BOOTLOADER / EFI
# =======================================================================

Log-Section "4. BOOTLOADER / EFI"

Out-Cmd-Sh "EFI boot mode" '
if [ -d /sys/firmware/efi ]; then
    echo "UEFI"
else
    echo "BIOS"
fi
'

Out-Cmd-Sh "EFI variables (efibootmgr)" '
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr -v 2>/dev/null || echo "efibootmgr failed"
else
    echo "efibootmgr not installed"
fi
'

Out-Cmd-Sh "GRUB version" '
if command -v grub-install >/dev/null 2>&1; then
    grub-install --version 2>/dev/null
elif command -v grub2-install >/dev/null 2>&1; then
    grub2-install --version 2>/dev/null
else
    echo "grub not installed"
fi
'

Out-Cmd-Sh "GRUB config location" '
for f in /boot/grub/grub.cfg /boot/grub2/grub.cfg; do
    if [ -f "$f" ]; then
        echo "found: $f"
        ls -la "$f"
    fi
done
'

# =======================================================================
# §5 INITRAMFS / VIRTIO
# =======================================================================

Log-Section "5. INITRAMFS / VIRTIO"

Out-Cmd-Sh "initramfs files in /boot" '
ls -la /boot/initramfs-*.img /boot/initrd.img-* /boot/initramfs-linux*.img 2>/dev/null || echo "none found"
'

Out-Cmd-Sh "initramfs tool" '
for t in dracut update-initramfs mkinitcpio; do
    if command -v "$t" >/dev/null 2>&1; then
        echo "$t: $(command -v "$t")"
    fi
done
'

Out-Cmd-Sh "dracut config (RHEL-family)" '
if [ -d /etc/dracut.conf.d ]; then
    ls -la /etc/dracut.conf.d/ 2>/dev/null
    for f in /etc/dracut.conf.d/*.conf; do
        [ -f "$f" ] && echo "--- $f ---" && cat "$f"
    done
else
    echo "no /etc/dracut.conf.d"
fi
'

Out-Cmd-Sh "initramfs-tools modules (Debian-family)" '
if [ -f /etc/initramfs-tools/modules ]; then
    cat /etc/initramfs-tools/modules
else
    echo "no /etc/initramfs-tools/modules"
fi
'

Out-Cmd-Sh "virtio modules loaded" '
lsmod 2>/dev/null | grep -E "^virtio" || echo "none loaded"
'

# =======================================================================
# §6 NETWORK
# =======================================================================

Log-Section "6. NETWORK"

Out-Cmd-Sh "ip addr" 'ip -br addr 2>/dev/null || ifconfig 2>/dev/null'

Out-Cmd-Sh "ip route" 'ip route 2>/dev/null'

Out-Cmd-Sh "DNS servers" '
cat /etc/resolv.conf 2>/dev/null | grep -v "^#" | grep -v "^$"
'

Out-Cmd-Sh "NetworkManager / systemd-networkd" '
systemctl is-active NetworkManager 2>/dev/null && echo "NM: active"
systemctl is-active systemd-networkd 2>/dev/null && echo "systemd-networkd: active"
'

# =======================================================================
# §7 CLOUD-INIT
# =======================================================================

Log-Section "7. CLOUD-INIT"

Out-Cmd-Sh "cloud-init presence" '
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init --version 2>/dev/null || echo "cloud-init present"
else
    echo "not installed"
fi
'

Out-Cmd-Sh "cloud-init configs (99-mws-*)" '
for f in /etc/cloud/cloud.cfg.d/99-mws-*.cfg; do
    if [ -f "$f" ]; then
        echo "--- $f ---"
        cat "$f"
    fi
done
'

Out-Cmd-Sh "cloud-init status" '
if command -v cloud-init >/dev/null 2>&1; then
    cloud-init status 2>/dev/null || true
else
    echo "skipped"
fi
'

# =======================================================================
# §8 VMWARE LEFTOVERS
# =======================================================================

Log-Section "8. VMWARE LEFTOVERS"

Out-Cmd-Sh "open-vm-tools packages" '
case "'"$PKG_MANAGER"'" in
    apt)
        dpkg -l 2>/dev/null | grep -iE "vmware|open-vm" || echo "none"
        ;;
    dnf|yum)
        rpm -qa 2>/dev/null | grep -iE "vmware|open-vm" || echo "none"
        ;;
    *)
        echo "unknown package manager"
        ;;
esac
'

Out-Cmd-Sh "VMware kernel modules" '
lsmod 2>/dev/null | grep -E "^vmw_|^vmxnet|^vmhgfs|^vsock" || echo "none loaded"
'

Out-Cmd-Sh "udev persistent net rules" '
if [ -f /etc/udev/rules.d/70-persistent-net.rules ]; then
    echo "present:"
    cat /etc/udev/rules.d/70-persistent-net.rules
else
    echo "not present (correct)"
fi
'

Out-Cmd-Sh "MACAddress in .link files" '
grep -r "^MACAddress=" /etc/systemd/network/ 2>/dev/null || echo "none"
'

Out-Cmd-Sh "VMware directories" '
for d in /usr/lib/vmware-tools /usr/lib/open-vm-tools /etc/vmware-tools; do
    if [ -d "$d" ]; then
        echo "present: $d"
    fi
done
'

# =======================================================================
# §9 TIME / TIMEZONE / NTP
# =======================================================================

Log-Section "9. TIME / TIMEZONE / NTP"

Out-Cmd-Sh "date" 'date'

Out-Cmd-Sh "timedatectl" 'timedatectl 2>/dev/null || echo "not systemd"'

Out-Cmd-Sh "hwclock" '
if command -v hwclock >/dev/null 2>&1; then
    hwclock --show 2>/dev/null || echo "hwclock failed"
else
    echo "hwclock not installed"
fi
'

Out-Cmd-Sh "NTP sync" '
if command -v timedatectl >/dev/null 2>&1; then
    timedatectl show 2>/dev/null | grep -E "NTP|TimeUSec"
fi
'

# =======================================================================
# §10 KERNEL MODULES
# =======================================================================

Log-Section "10. KERNEL MODULES"

Out-Cmd-Sh "Storage drivers loaded" '
lsmod 2>/dev/null | grep -E "^virtio|^megaraid|^mpt|^ahci|^nvme|^sd_mod" || echo "none"
'

Out-Cmd-Sh "Filesystem drivers loaded" '
lsmod 2>/dev/null | grep -E "^ext4|^xfs|^btrfs" || echo "none"
'

Out-Cmd-Sh "Network drivers loaded" '
lsmod 2>/dev/null | grep -E "^e1000|^virtio_net|^vmxnet|^igb|^ixgbe" || echo "none"
'

# =======================================================================
# §11 BOOTLOADER FILES
# =======================================================================

Log-Section "11. BOOTLOADER FILES"

Out-Cmd-Sh "Critical boot files" '
files=(
    "/boot/vmlinuz"
    "/boot/vmlinuz-$(uname -r)"
    "/boot/initramfs-$(uname -r).img"
    "/boot/initrd.img-$(uname -r)"
    "/boot/grub/grub.cfg"
    "/boot/grub2/grub.cfg"
    "/boot/efi/EFI/BOOT/BOOTX64.EFI"
)
for f in "${files[@]}"; do
    if [ -f "$f" ]; then
        sz=$(stat -c %s "$f" 2>/dev/null)
        echo "  [+] $f ($sz bytes)"
    else
        echo "  [-] $f MISSING"
    fi
done
'

# =======================================================================
# §12 COMPARISON vs REFERENCE KVM
# =======================================================================

Log-Section "12. COMPARISON vs REFERENCE KVM"

Log-Info ""
Log-Info "  Parameter                | Reference    | Ours         | Match"
Log-Info "  -------------------------|--------------|--------------|------"

# Disk style: GPT
ref="gpt"
ours="$DISK_STYLE"
s="DIFF"
[ "$ours" = "$ref" ] && s="OK"
Log-Info "  Disk style               | $ref          | $ours          | $s"

# EFI partition
ref="yes"
ours="$HAS_EFI"
s="DIFF"
[ "$ours" = "$ref" ] && s="OK"
Log-Info "  EFI partition            | $ref          | $ours          | $s"

# Bootloader
ref="grub2-efi"
ours="$BOOTLOADER"
s="DIFF"
[ "$ours" = "$ref" ] && s="OK"
Log-Info "  Bootloader               | $ref          | $ours          | $s"

# cloud-init
ref="yes"
ours="$CLOUD_INIT_READY"
s="DIFF"
[ "$ours" = "$ref" ] && s="OK"
Log-Info "  cloud-init               | $ref          | $ours          | $s"

# open-vm-tools absent
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
s="DIFF"
[ "$vm_tools_state" = "absent" ] && s="OK"
Log-Info "  open-vm-tools            | absent       | $vm_tools_state      | $s"

# udev persistent net rules absent
udev_state="present"
if [ ! -f /etc/udev/rules.d/70-persistent-net.rules ]; then
    udev_state="absent"
fi
s="DIFF"
[ "$udev_state" = "absent" ] && s="OK"
Log-Info "  udev persistent net      | absent       | $udev_state      | $s"

# virtio modules
ref="yes"
ours="$VIRTIO_IN_INITRAMFS"
s="DIFF"
[ "$ours" = "$ref" ] && s="OK"
Log-Info "  virtio in initramfs      | $ref          | $ours          | $s"

Log-Info ""
Log-Info "  Note: N/A in ours = pre-migration state."

# =======================================================================
# §13 VERDICT
# =======================================================================

Log-Section "13. VERDICT"

issues=()
ok=()

[ -n "$DISTRO_FAMILY" ] && [ "$DISTRO_FAMILY" != "unknown" ] && \
    ok+=("Distro family: $DISTRO_FAMILY")

[ "$DISTRO_SUPPORTED" = "yes" ] && ok+=("Distro version: supported") || \
    issues+=("Distro: $DISTRO_PRETTY_NAME ($DISTRO_SUPPORTED)")

[ "$DISK_STYLE" = "gpt" ] && ok+=("Disk: GPT") || \
    issues+=("Disk style: $DISK_STYLE (expected GPT)")

[ "$HAS_EFI" = "yes" ] && ok+=("EFI partition present") || \
    issues+=("EFI partition missing")

[ "$HAS_LVM" = "no" ] && ok+=("No LVM on root") || \
    issues+=("LVM on root")

[ "$HAS_LUKS" = "no" ] && ok+=("No LUKS on root") || \
    issues+=("LUKS on root")

[ "$FREE_SPACE_GB" -ge 2 ] 2>/dev/null && ok+=("Free space: ${FREE_SPACE_GB} GB") || \
    issues+=("Free space < 2 GB: ${FREE_SPACE_GB} GB")

[ "$HAS_PARTITION_TOOL" = "yes" ] && ok+=("Partition tool available") || \
    issues+=("No sgdisk/parted")

[ "$HAS_INITRAMFS_TOOL" = "yes" ] && ok+=("Initramfs tool available") || \
    issues+=("No initramfs tool")

[ "$CLOUD_INIT_READY" = "yes" ] && ok+=("cloud-init installed") || \
    issues+=("cloud-init not installed (run 6-Cloud-Init.sh)")

[ -z "$BLOCKER" ] && ok+=("No blockers") || \
    issues+=("Blocker: $BLOCKER")

Log-Info ""
Log-Info "---- PROBLEMS ----"
if [ "${#issues[@]}" -eq 0 ]; then
    Log-Info "  None."
else
    for i in "${issues[@]}"; do
        Log-Warn "  [!] $i"
    done
fi

Log-Info ""
Log-Info "---- OK ----"
for o in "${ok[@]}"; do
    Log-Success "  [+] $o"
done

# =======================================================================
# COMPLETE
# =======================================================================

Log-Section "COMPLETE"
Log-Info "Report: $LOG_FILE"
Log-Info ""
Log-Info "3-Diagnostic.sh v4.1 complete."