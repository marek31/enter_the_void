#!/usr/bin/env bash
# Live ISO: re-enter an installed (or half-installed) Void and run setup.sh steps inside it.
# Use it when install.sh stopped during setup.sh, or to repair a system that does not boot.
# Usage: ./resume.sh [step...]     (default: all; e.g. ./resume.sh apps devtools finish)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
die() { printf '\e[1;31m!! %s\e[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root"

if ! mountpoint -q /mnt; then
    luks=$(lsblk -lnpo NAME,FSTYPE | awk '$2 == "crypto_LUKS" {print $1; exit}')
    if [[ -n $luks ]]; then
        [[ -e /dev/mapper/cryptroot ]] || cryptsetup open --allow-discards "$luks" cryptroot
        dev=/dev/mapper/cryptroot
    else
        dev=$(blkid -L void) || die "no LUKS partition and no btrfs labelled 'void' found"
    fi
    mount -o subvol=@ "$dev" /mnt
    # the other subvolumes and the EFI partition, exactly as the installed fstab lists them
    while read -r src mp type opts _; do
        [[ $src == \#* || $mp == / || ! $type =~ ^(btrfs|vfat|ext4)$ ]] && continue
        mkdir -p "/mnt$mp"
        mount -t "$type" -o "$opts" "$src" "/mnt$mp"
    done < /mnt/etc/fstab
fi
for d in sys dev proc; do
    mountpoint -q "/mnt/$d" || { mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"; }
done
# swap on, or compiling Noctalia/the kernel runs out of the live system's RAM
if [[ -f /mnt/swap/swapfile ]] && ! grep -q /swap/swapfile /proc/swaps; then swapon /mnt/swap/swapfile; fi
cp -L /etc/resolv.conf /mnt/etc/
rm -rf /mnt/root/enter_void
cp -r "$HERE" /mnt/root/enter_void
chroot /mnt /root/enter_void/setup.sh "${@:-all}"
echo "Done. When finished: swapoff -a; umount -R /mnt; cryptsetup close cryptroot; reboot"
