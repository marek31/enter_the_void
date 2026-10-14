#!/usr/bin/env bash
# Stage 1 - run as root from the Void live ISO (x86_64 glibc, booted in UEFI mode).
# Wipes $DISK, creates the LUKS + btrfs layout, bootstraps Void, then runs setup.sh in a chroot.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
source "$HERE/config.sh"

LOG=/tmp/$(date +%F_%H-%M-%S)-void-install.log
exec > >(tee -a "$LOG") 2>&1
TEE_PID=$!
trap 'exec >&- 2>&-; wait "$TEE_PID"' EXIT   # flush the log before the shell prompt returns
log() { printf '\e[1;34m==> %s\e[0m\n' "$*"; }
die() { printf '\e[1;31m!! %s\e[0m\n' "$*" >&2; exit 1; }
part() { [[ $DISK =~ [0-9]$ ]] && echo "${DISK}p$1" || echo "${DISK}$1"; }

echo "enter_void installer - $HOSTNAME - log: $LOG"
[[ $EUID -eq 0 ]] || die "run as root"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode - enable EFI in the VM/BIOS settings and boot the live ISO again"
ping -c1 -W5 repo-default.voidlinux.org >/dev/null || die "no network (wifi: wpa_supplicant/nmtui, then retry)"

# Candidates: writable whole disks with nothing mounted, so neither the running system nor the live USB/CD.
mapfile -t DISKS < <(lsblk -dnpo NAME,TYPE,RO | awk '$2 == "disk" && $3 == 0 {print $1}' |
    while read -r d; do lsblk -nrpo MOUNTPOINT "$d" | grep -q . || echo "$d"; done)
[[ ${#DISKS[@]} -gt 0 ]] || die "no usable disk (disks with mounted partitions are skipped - run this from the live ISO)"
lsblk -dpno NAME,SIZE,MODEL "${DISKS[@]}"
until printf '%s\n' "${DISKS[@]}" | grep -qxF -- "$DISK"; do
    [[ -n $DISK ]] && printf '\e[1;33m!! %s is not one of the disks listed above\e[0m\n' "$DISK"
    read -rp "Target disk [${DISKS[0]}]: " DISK
    DISK=${DISK:-${DISKS[0]}}
done
read -rp "EVERYTHING on $DISK will be destroyed. Type the disk path again to confirm: " confirm
[[ $confirm == "$DISK" ]] || die "aborted, nothing changed"

if [[ $ENCRYPT == yes ]]; then
    read -rsp "Disk encryption passphrase: " PASS; echo
    read -rsp "Repeat passphrase: " PASS2; echo
    [[ -n $PASS && $PASS == "$PASS2" ]] || die "passphrases empty or different"
fi

log "updating xbps on the live system"
xbps-install -Syu -R "$REPO" xbps
xbps-install -Sy -R "$REPO" btrfs-progs cryptsetup dosfstools util-linux

log "partitioning $DISK"
ESP=$(part 1); ROOT=$(part 2)
wipefs -af "$DISK"
sfdisk -q "$DISK" <<EOF
label: gpt
size=${ESP_MIB}MiB, type=uefi, name=EFI
type=linux, name=void
EOF
udevadm settle
mkfs.vfat -F32 -n EFI "$ESP"

if [[ $ENCRYPT == yes ]]; then
    log "encrypting $ROOT (LUKS1 so grub can unlock /boot)"
    printf '%s' "$PASS" | cryptsetup luksFormat --type luks1 -q --key-file=- "$ROOT"
    printf '%s' "$PASS" | cryptsetup open --allow-discards --key-file=- "$ROOT" cryptroot
    DEV=/dev/mapper/cryptroot
else
    DEV=$ROOT
fi

log "creating btrfs subvolumes"
mkfs.btrfs -q -f -L void "$DEV"
mount "$DEV" /mnt
# Everything that must not be snapshotted with / gets its own subvolume.
SUBVOLS=("@:/" "@home:/home" "@snapshots:/.snapshots" "@var_log:/var/log"
         "@var_cache:/var/cache" "@var_tmp:/var/tmp" "@swap:/swap")
for sv in "${SUBVOLS[@]}"; do btrfs subvolume create "/mnt/${sv%%:*}" >/dev/null; done
umount /mnt

mount -o "$BTRFS_OPTS,subvol=@" "$DEV" /mnt
for sv in "${SUBVOLS[@]:1}"; do
    mkdir -p "/mnt${sv#*:}"
    mount -o "$BTRFS_OPTS,subvol=${sv%%:*}" "$DEV" "/mnt${sv#*:}"
done
# /btrfsroot stays an empty mount point: snapper-rollback mounts the top level there only while rolling back.
mkdir -p /mnt/btrfsroot /mnt/boot/efi
mount "$ESP" /mnt/boot/efi
chmod 1777 /mnt/var/tmp

log "bootstrapping Void"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64 xbps-install -Sy -r /mnt -R "$REPO" base-system btrfs-progs cryptsetup grub-x86_64-efi efibootmgr

log "writing fstab"
FS_UUID=$(blkid -s UUID -o value "$DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP")
{
    for sv in "${SUBVOLS[@]}"; do
        echo "UUID=$FS_UUID ${sv#*:} btrfs $BTRFS_OPTS,subvol=${sv%%:*} 0 0"
    done
    echo "UUID=$ESP_UUID /boot/efi vfat defaults,umask=0077 0 2"
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,mode=1777 0 0"
    echo "/swap/swapfile none swap defaults 0 0"
} > /mnt/etc/fstab

CMDLINE="loglevel=4 apparmor=1 security=apparmor zswap.enabled=0"   # swap = plain swapfile, no RAM compression
mkdir -p /mnt/etc/dracut.conf.d
if [[ $ENCRYPT == yes ]]; then
    log "keyfile so the passphrase is asked only once (by grub)"
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
    dd bs=512 count=4 if=/dev/urandom of=/mnt/boot/cryptroot.key iflag=fullblock status=none
    chmod 000 /mnt/boot/cryptroot.key
    cryptsetup luksAddKey --key-file=<(printf '%s' "$PASS") "$ROOT" /mnt/boot/cryptroot.key
    echo "cryptroot UUID=$LUKS_UUID /boot/cryptroot.key luks,discard" > /mnt/etc/crypttab
    echo 'install_items+=" /boot/cryptroot.key /etc/crypttab "' > /mnt/etc/dracut.conf.d/10-crypt.conf
    echo 'GRUB_ENABLE_CRYPTODISK=y' >> /mnt/etc/default/grub
    CMDLINE+=" rd.luks.uuid=$LUKS_UUID rd.luks.allow-discards"
fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"|" /mnt/etc/default/grub
echo 'hostonly="yes"' > /mnt/etc/dracut.conf.d/00-hostonly.conf

log "entering chroot"
for d in sys dev proc; do mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"; done
cp -L /etc/resolv.conf /mnt/etc/
rm -rf /mnt/root/enter_void
cp -r "$HERE" /mnt/root/enter_void
chroot /mnt /bin/bash -c "
    set -e
    btrfs filesystem mkswapfile --size ${SWAP_GIB}g /swap/swapfile
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
    /root/enter_void/setup.sh all
"

cp "$LOG" /mnt/var/log/
umount -R /mnt || die "installed, but /mnt is busy: run 'umount -lR /mnt' and reboot"
if [[ $ENCRYPT == yes ]]; then cryptsetup close cryptroot; fi
log "done - remove the USB stick and reboot"
