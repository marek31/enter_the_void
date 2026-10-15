#!/usr/bin/env bash
# Stage 1 - run as root from the Void live ISO (x86_64 glibc, booted in UEFI mode).
# Mode "free": new partition in the largest unallocated area + the existing EFI partition (dual boot,
# Windows untouched). Mode "wipe": whole disk. Then LUKS + btrfs, bootstrap, setup.sh in a chroot.
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
ESP_TYPE=c12a7328-f81f-11d2-ba4b-00a0c93ec93b
# free_areas: "bytes disk start end" for each unallocated area >= MIN_FREE_GIB, largest first
free_areas() {
    local d ss
    for d in "${DISKS[@]}"; do
        ss=$(blockdev --getss "$d")
        sfdisk -F "$d" 2>/dev/null | awk -v d="$d" -v ss="$ss" -v min="$MIN_FREE_GIB" \
            '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && $3 * ss >= min * 2^30 {printf "%.0f %s %s %s\n", $3 * ss, d, $1, $2}'
    done | sort -rn
}

echo "enter_void installer - $HOSTNAME - log: $LOG"
[[ $EUID -eq 0 ]] || die "run as root"
[[ -d /sys/firmware/efi ]] || die "not booted in UEFI mode - enable EFI in the VM/BIOS settings and boot the live ISO again"
ping -c1 -W5 repo-default.voidlinux.org >/dev/null || die "no network (wifi: wpa_supplicant/nmtui, then retry)"

# Candidates: writable whole disks with nothing mounted, so neither the running system nor the live USB/CD.
mapfile -t DISKS < <(lsblk -dnpo NAME,TYPE,RO | awk '$2 == "disk" && $3 == 0 {print $1}' |
    while read -r d; do lsblk -nrpo MOUNTPOINT "$d" | grep -q . || echo "$d"; done)
[[ ${#DISKS[@]} -gt 0 ]] || die "no usable disk (disks with mounted partitions are skipped - run this from the live ISO)"
lsblk -po NAME,SIZE,FSTYPE,LABEL,PARTLABEL "${DISKS[@]}"
FREE=$(free_areas | head -n1)
if [[ -z $INSTALL_MODE ]]; then
    echo
    default=wipe
    if [[ -n $FREE ]]; then
        default=free
        read -r fbytes fdisk _ _ <<< "$FREE"
        echo "  free  new partition in the $((fbytes >> 30)) GiB of unallocated space on $fdisk - other partitions untouched (dual boot)"
    fi
    echo "  wipe  erase one whole disk"
    read -rp "Install mode [$default]: " INSTALL_MODE
    INSTALL_MODE=${INSTALL_MODE:-$default}
fi

case $INSTALL_MODE in
free)
    [[ -n $FREE ]] || die "no unallocated area of at least $MIN_FREE_GIB GiB - shrink a partition in Windows Disk Management first"
    read -r fbytes DISK START END <<< "$FREE"
    ESP=$(lsblk -lnpo NAME,PARTTYPE "$DISK" | awk -v t="$ESP_TYPE" 'tolower($2) == t {print $1; exit}')
    [[ -n $ESP ]] || die "no EFI system partition on $DISK to share - use wipe mode or create one"
    echo "Void gets two new partitions in the $((fbytes >> 30)) GiB of free space on $DISK: /boot ($BOOT_MIB MiB) and the rest, encrypted."
    echo "The EFI partition $ESP is shared (grub is added next to Windows Boot Manager, nothing is formatted)."
    read -rp "Type yes to continue: " confirm
    [[ $confirm == yes ]] || die "aborted, nothing changed"
    ;;
wipe)
    until printf '%s\n' "${DISKS[@]}" | grep -qxF -- "$DISK"; do
        [[ -n $DISK ]] && printf '\e[1;33m!! %s is not one of the disks listed above\e[0m\n' "$DISK"
        read -rp "Target disk [${DISKS[0]}]: " DISK
        DISK=${DISK:-${DISKS[0]}}
    done
    read -rp "EVERYTHING on $DISK will be destroyed. Type the disk path again to confirm: " confirm
    [[ $confirm == "$DISK" ]] || die "aborted, nothing changed"
    ;;
*) die "INSTALL_MODE must be free or wipe, not '$INSTALL_MODE'" ;;
esac

if [[ $ENCRYPT == yes ]]; then
    read -rsp "Disk encryption passphrase: " PASS; echo
    read -rsp "Repeat passphrase: " PASS2; echo
    [[ -n $PASS && $PASS == "$PASS2" ]] || die "passphrases empty or different"
fi

log "updating xbps on the live system"
xbps-install -Syu -R "$REPO" xbps
xbps-install -Sy -R "$REPO" btrfs-progs cryptsetup dosfstools e2fsprogs util-linux

if [[ $INSTALL_MODE == wipe ]]; then
    log "partitioning $DISK"
    ESP=$(part 1); BOOT=$(part 2); ROOT=$(part 3)
    wipefs -af "$DISK"
    sfdisk -q "$DISK" <<EOF
label: gpt
size=${ESP_MIB}MiB, type=uefi, name=EFI
size=${BOOT_MIB}MiB, type=linux, name=boot
type=linux, name=void
EOF
    udevadm settle
    mkfs.vfat -F32 -n EFI "$ESP"
else
    log "adding /boot and the Void partition in the free space on $DISK"
    # new_part <start> <size> <name>: append a partition, print its device
    new_part() {
        local before
        before=$(lsblk -lnpo NAME "$DISK" | sort)
        echo "start=$1, size=$2, type=linux, name=$3" | sfdisk -q --append "$DISK"
        udevadm settle
        comm -13 <(echo "$before") <(lsblk -lnpo NAME "$DISK" | sort)
    }
    SS=$(blockdev --getss "$DISK")
    START=$(( (START + 2047) / 2048 * 2048 ))   # 1 MiB alignment (512-byte sectors; coarser on 4K)
    BOOT_SECT=$(( BOOT_MIB * 1048576 / SS ))
    SIZE=$(( (END - START - BOOT_SECT + 1) / 2048 * 2048 ))
    BOOT=$(new_part "$START" "$BOOT_SECT" boot)
    ROOT=$(new_part "$((START + BOOT_SECT))" "$SIZE" void)
    [[ -b $BOOT && -b $ROOT ]] || die "could not find the new partitions on $DISK"
    log "new partitions: $BOOT (/boot), $ROOT (Void)"
fi
mkfs.ext4 -q -F -L boot "$BOOT"

if [[ $ENCRYPT == yes ]]; then
    log "encrypting $ROOT (LUKS2, argon2id; the initramfs asks for the passphrase)"
    printf '%s' "$PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id --iter-time "$LUKS_ITER_MS" -q --key-file=- "$ROOT"
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
mkdir -p /mnt/btrfsroot /mnt/boot
mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$ESP" /mnt/boot/efi
(( $(df --output=avail -m /mnt/boot/efi | tail -n1) >= 16 )) || die "EFI partition $ESP has less than 16 MB free for grub"
chmod 1777 /mnt/var/tmp

log "bootstrapping Void"
mkdir -p /mnt/var/db/xbps/keys
cp /var/db/xbps/keys/* /mnt/var/db/xbps/keys/
XBPS_ARCH=x86_64 xbps-install -Sy -r /mnt -R "$REPO" base-system btrfs-progs cryptsetup grub-x86_64-efi efibootmgr

log "writing fstab"
FS_UUID=$(blkid -s UUID -o value "$DEV")
ESP_UUID=$(blkid -s UUID -o value "$ESP")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
{
    for sv in "${SUBVOLS[@]}"; do
        echo "UUID=$FS_UUID ${sv#*:} btrfs $BTRFS_OPTS,subvol=${sv%%:*} 0 0"
    done
    echo "UUID=$BOOT_UUID /boot ext4 defaults,noatime 0 2"
    echo "UUID=$ESP_UUID /boot/efi vfat defaults,umask=0077 0 2"
    echo "tmpfs /tmp tmpfs defaults,nosuid,nodev,mode=1777 0 0"
    echo "/swap/swapfile none swap defaults 0 0"
} > /mnt/etc/fstab

CMDLINE="loglevel=4 apparmor=1 security=apparmor zswap.enabled=0"   # swap = plain swapfile, no RAM compression
mkdir -p /mnt/etc/dracut.conf.d
if [[ $ENCRYPT == yes ]]; then
    # /boot is not encrypted, so grub needs no key; the initramfs asks once (no keyfile anywhere)
    LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
    echo "cryptroot UUID=$LUKS_UUID none luks,discard" > /mnt/etc/crypttab
    CMDLINE+=" rd.luks.uuid=$LUKS_UUID rd.luks.allow-discards"
fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMDLINE\"|" /mnt/etc/default/grub
sed -i 's/^#\?GRUB_TIMEOUT=.*/GRUB_TIMEOUT=2/' /mnt/etc/default/grub   # menu (and snapshots) still reachable
echo 'GRUB_DISABLE_OS_PROBER=false' >> /mnt/etc/default/grub            # Windows Boot Manager in the grub menu
echo 'hostonly="yes"' > /mnt/etc/dracut.conf.d/00-hostonly.conf

log "entering chroot"
for d in sys dev proc; do mount --rbind "/$d" "/mnt/$d"; mount --make-rslave "/mnt/$d"; done
cp -L /etc/resolv.conf /mnt/etc/
rm -rf /mnt/root/enter_void
cp -r "$HERE" /mnt/root/enter_void
chroot /mnt /bin/bash -c "
    set -e
    btrfs filesystem mkswapfile --size ${SWAP_GIB}g /swap/swapfile
    swapon /swap/swapfile   # compiling Noctalia needs more than the live system's RAM
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Void
    /root/enter_void/setup.sh all
"

cp "$LOG" /mnt/var/log/
swapoff /mnt/swap/swapfile 2>/dev/null || true
umount -R /mnt || die "installed, but /mnt is busy: run 'umount -lR /mnt' and reboot"
if [[ $ENCRYPT == yes ]]; then cryptsetup close cryptroot; fi
log "done - remove the USB stick and reboot"
