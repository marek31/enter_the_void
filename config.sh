# shellcheck shell=bash
# Every install decision lives here. install.sh and setup.sh source this file.
#
# Decisions (2026-10-14):
#   distro      Void Linux x86_64 glibc, runit, no flatpak/snap/AppImage-runtime
#   target      ThinkPad X1 Carbon Gen 10 (21CC): i5-1250P, Iris Xe, 16 GB, 512 GB NVMe, 2560x1440,
#               AX211 wifi, SOF audio, Synaptics 06cb:00fc fingerprint reader, USB4/Thunderbolt
#   disk        X1: dual boot - Void goes into the 97 GiB unallocated between C: and Windows Recovery,
#               sharing Windows' 260 MB EFI partition (grub next to Windows Boot Manager, os-prober menu).
#               VM/blank disk: GPT, 1 GiB EFI + 1 GiB /boot + rest. Either way /boot is plain ext4 and the
#               rest LUKS2 (argon2id) + btrfs: the initramfs asks for the passphrase once, ~2 s, no grub wait
#   swap        plain swapfile on disk (@swap subvolume, inside LUKS); no zram, zswap disabled
#   btrfs       @ / @home / @snapshots / @var_log / @var_cache / @var_tmp / @swap, /tmp is tmpfs
#   snapshots   snapper, root + home every 15 min; caches, logs, temp, swap, snapshots are separate
#               subvolumes so they are never snapshotted; grub-btrfs lists snapshots in the boot menu
#   desktop     Wayland only: niri + Noctalia shell (built from source), greetd + tuigreet login
#   look        minimal: Kanagawa palette pushed by Noctalia to niri/foot/GTK/Qt/KDE/btop/starship,
#               thin floating bar, single-accent focus ring, no borders, Inter + JetBrains Mono,
#               Bibata cursor, Hokusai "Great Wave" wallpaper (public domain)
#   dev         Go (xbps), Rust (rustup), Deno, Claude Code, Antigravity CLI (agy), oh-my-pi (omp)
#   remote      RustDesk (upstream package), Remmina; KDE Connect for the phone (LAN-only firewall rule)
#   upkeep      browsers/Noctalia auto-update once a day, update notifications, monthly btrfs scrub,
#               smartd, earlyoom, hibernate at 5 % battery, USB automount (udiskie)
#   browsers    Helium (default) + Floorp: upstream tarballs in /opt, updated by `setup.sh apps`;
#               Firefox + Opera (nonfree) from xbps
#   office      LibreOffice (Polish UI pack + spelling)
#   printing    CUPS + cups-browsed + avahi (wifi/IPP Everywhere), sane-airscan for network scanners
#   sync        Resilio Sync (run `resilio`) and pCloud via rclone (`cloud`), nothing autostarted;
#               the official pCloud app stays available through pcloud-install
#   kernel      BORE scheduler (as in CachyOS): Void's kernel template + CachyOS's BORE patch, built
#               locally with xbps-src as linux<series>-bore, default in grub; stock kernel kept as fallback
#   init        runit, no systemd anywhere (elogind for seats/suspend only)
#   power       TLP (+ tlp-pd so Noctalia's power-profile switch works), thermald
#   security    nftables default-deny inbound, sysctl hardening, AppArmor enforce, root locked,
#               no sshd, wifi MAC randomisation, Resilio WebUI on localhost only, UPnP off
#   sudo        password once per day, shared across terminals; fingerprint accepted for sudo
#   fonts       open-licence families that also install on Windows (Noto, Inter, JetBrains Mono,
#               Cascadia Code, IBM Plex, Fira, Source, Liberation, Carlito/Caladea, ...)

HOSTNAME=x1-void
USERNAME=marek          # login name: shadow's useradd rejects capitals, so "Marek" becomes the full name
FULLNAME=Marek
TIMEZONE=Europe/Warsaw
LANG_UI=en_US.UTF-8     # program language
LANG_FORMATS=pl_PL.UTF-8 # dates, money, paper (A4), units
CONSOLE_KEYMAP=pl2
CONSOLE_FONT=ter-v24n   # readable on the 2560x1440 14" panel
XKB_LAYOUT=pl           # "pl" basic variant == Polish (programmer's)
DISPLAY_SCALE=1.25      # eDP-1 in niri; 1.0-1.5 are sane on this panel

INSTALL_MODE=""         # free = new partition in the largest unallocated area, keep Windows (dual boot)
                        # wipe = erase a whole disk; empty = install.sh asks (default free if there is space)
MIN_FREE_GIB=40         # smallest unallocated area offered for "free"
DISK=""                 # wipe mode only, e.g. /dev/nvme0n1; empty = install.sh asks
ENCRYPT=yes             # yes = LUKS2 encryption of everything except /boot, no = plain btrfs
LUKS_ITER_MS=2000       # argon2id unlock time (Linux does it, not grub): ~2 s at boot, cryptsetup default
BOOT_MIB=1024           # unencrypted /boot (kernels + initramfs; Void keeps old kernels until vkpurge)
ESP_MIB=1024
SWAP_GIB=16             # = RAM
BTRFS_OPTS="noatime,compress=zstd:1"
REPO=https://repo-default.voidlinux.org/current

SNAPSHOT_EVERY_MIN=15
SNAP_KEEP_HOURLY=24     # older 15-min snapshots collapse into hourly/daily/... after 1 h
SNAP_KEEP_DAILY=7
SNAP_KEEP_WEEKLY=4
SNAP_KEEP_MONTHLY=3
# Paths under /home/$USERNAME turned into nested subvolumes = excluded from home snapshots.
HOME_NOSNAP=(.cache .local/share/Trash .local/share/resilio-sync .pcloud)

KERNEL_BORE=yes         # build + boot the BORE-patched kernel (first build ~1 h on AC power, needs ~25 GB free)

GREETER=tuigreet        # login screen: tuigreet (text, default) or noctalia (graphical; blank screen in VMware)

SUDO_TIMEOUT_MIN=1440   # ask for the sudo password once per day
RESILIO_PORT=55555      # fixed listening port, opened in the firewall
