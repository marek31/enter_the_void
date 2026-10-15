#!/usr/bin/env bash
# Stage 2 - run as root, inside the install chroot (install.sh does it) or later on the running system.
# Safe to re-run. Usage: sudo ./setup.sh [all | step...]
# Steps: base packages user security snapper desktop apps login devtools speakers kernel finish   (e.g. `sudo ./setup.sh apps`)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=config.sh
source "$HERE/config.sh"
FILES=$HERE/files
UHOME=/home/$USERNAME

log() { printf '\e[1;34m==> %s\e[0m\n' "$*"; }
warn() { printf '\e[1;33m!! %s\e[0m\n' "$*" >&2; }
die() { printf '\e[1;31m!! %s\e[0m\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root: sudo $0 $*"
# On the live ISO / is a small RAM overlay: setup.sh belongs to the installed system
# (install.sh runs it in a chroot). The full package set needs roughly 15 GB (estimate, TeX is ~5 GB).
[[ $(findmnt -no FSTYPE /) == btrfs ]] ||
    die "/ is $(findmnt -no FSTYPE /), not the installed btrfs system - on the live ISO run ./install.sh instead"
FREE_GB=$(df --output=avail -BG / | tail -n1 | tr -dc 0-9)
(( FREE_GB >= 15 )) || die "only ${FREE_GB} GB free on / - the full package set needs about 15 GB"
mkdir -p /var/log/enter_void
LOG=/var/log/enter_void/$(date +%F_%H-%M-%S)-setup.log
exec > >(tee -a "$LOG") 2>&1
TEE_PID=$!
trap 'exec >&- 2>&-; wait "$TEE_PID"' EXIT   # flush the log before the shell prompt returns

# put <mode> <dest> < content: atomic write, skipped if unchanged, old version backed up to /root/.backup
put() {
    local tmp
    mkdir -p "$(dirname "$2")"
    tmp=$(mktemp "$2.tmp.XXXXXX")
    cat > "$tmp"
    if [[ -f $2 ]] && cmp -s "$tmp" "$2"; then rm -f "$tmp"; return 0; fi
    if [[ -f $2 ]]; then
        mkdir -p /root/.backup
        cp -a "$2" "/root/.backup/$(basename "$2") $(date '+%F %H-%M-%S')"
    fi
    chmod "$1" "$tmp"
    mv -f "$tmp" "$2"
}
# fill @PLACEHOLDERS@ in a template from config.sh
tpl() {
    sed -e "s|@USER@|$USERNAME|g" -e "s|@HOME@|$UHOME|g" -e "s|@HOSTNAME@|$HOSTNAME|g" \
        -e "s|@XKB@|$XKB_LAYOUT|g" -e "s|@SCALE@|$DISPLAY_SCALE|g" -e "s|@RESILIO_PORT@|$RESILIO_PORT|g" "$1"
}
# setkv <file> <KEY> <value>: set KEY="value" in a shell-style config, uncommenting or appending
setkv() {
    if grep -qE "^#?\s*$2=" "$1"; then sed -i -E "s|^#?\s*$2=.*|$2=\"$3\"|" "$1"; else echo "$2=\"$3\"" >> "$1"; fi
}
sv_enable() {
    local s
    for s; do
        if [[ -d /etc/sv/$s ]]; then ln -sfn "/etc/sv/$s" "/etc/runit/runsvdir/default/$s"; else warn "no runit service '$s'"; fi
    done
}
sv_disable() { local s; for s; do rm -f "/etc/runit/runsvdir/default/$s"; done; }
# run as the desktop user with that user's HOME (runuser alone may keep root's HOME inside the chroot)
in_vmware() { grep -qi vmware /sys/class/dmi/id/sys_vendor 2>/dev/null; }
in_chroot() { [[ $(stat -c %d:%i /) != "$(stat -c %d:%i /proc/1/root/. 2>/dev/null)" ]]; }
as_user() {
    local vars=(HOME="$UHOME" USER="$USERNAME" LOGNAME="$USERNAME"
        PATH="$UHOME/.local/bin:$UHOME/.cargo/bin:/usr/local/bin:/usr/bin:/usr/sbin:/bin")
    local rt
    rt=/run/user/$(id -u "$USERNAME" 2>/dev/null || true)
    [[ -d $rt ]] && vars+=(XDG_RUNTIME_DIR="$rt")   # running desktop: lets tools reach PipeWire
    # without the SUDO_* variables: some tools refuse to run "under sudo"
    (cd "$UHOME" && runuser -u "$USERNAME" -- env -u SUDO_USER -u SUDO_UID -u SUDO_GID -u SUDO_COMMAND \
        "${vars[@]}" "$@")
}
# cmdline_set <key> [value]: put key[=value] on the grub kernel command line, replacing any old value
cmdline_set() {
    local line w words=() out=()
    line=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' /etc/default/grub)
    read -ra words <<< "$line"
    for w in "${words[@]}"; do [[ $w == "$1" || $w == "$1="* ]] || out+=("$w"); done
    out+=("$1${2:+=$2}")
    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${out[*]}\"|" /etc/default/grub
}

step_base() {
    log "hostname, time zone, locale, console"
    echo "$HOSTNAME" | put 644 /etc/hostname
    printf '127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t%s\n' "$HOSTNAME" | put 644 /etc/hosts
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
    sed -i -E "s/^#\s*(${LANG_UI}|${LANG_FORMATS}) /\1 /" /etc/default/libc-locales
    xbps-reconfigure -f glibc-locales
    put 644 /etc/locale.conf <<EOF
LANG=$LANG_UI
LC_TIME=$LANG_FORMATS
LC_MONETARY=$LANG_FORMATS
LC_PAPER=$LANG_FORMATS
LC_MEASUREMENT=$LANG_FORMATS
LC_ADDRESS=$LANG_FORMATS
LC_TELEPHONE=$LANG_FORMATS
EOF
    setkv /etc/rc.conf KEYMAP "$CONSOLE_KEYMAP"
    setkv /etc/rc.conf FONT "$CONSOLE_FONT"
    setkv /etc/rc.conf HARDWARECLOCK UTC
}

step_packages() {
    log "installing packages from packages.txt"
    xbps-install -Syu xbps
    xbps-install -Sy void-repo-nonfree
    xbps-install -Syu
    local pkgs
    mapfile -t pkgs < <(sed 's/#.*//' "$HERE/packages.txt" | tr -s ' \t' '\n' | sed '/^$/d')
    grep -q GenuineIntel /proc/cpuinfo && pkgs+=(intel-ucode)
    grep -q AuthenticAMD /proc/cpuinfo && pkgs+=(linux-firmware-amd)
    in_vmware && pkgs+=(open-vm-tools)   # VM tests: clipboard, time sync, display resize
    xbps-install -Sy "${pkgs[@]}"
}

step_user() {
    log "user $USERNAME, sudo"
    id "$USERNAME" &>/dev/null || useradd -m -c "$FULLNAME" -s /bin/bash "$USERNAME"
    local g
    for g in wheel audio video input lp lpadmin scanner network bluetooth storage optical plugdev _seatd; do
        getent group "$g" >/dev/null && usermod -aG "$g" "$USERNAME"
    done
    [[ $(passwd -S "$USERNAME" | awk '{print $2}') == P ]] || { echo "Password for $USERNAME:"; passwd "$USERNAME"; }

    # Password once per day; timestamp_type=global shares it between all terminals (cleared on reboot).
    local tmp; tmp=$(mktemp)
    cat > "$tmp" <<EOF
%wheel ALL=(ALL:ALL) ALL
Defaults timestamp_timeout=$SUDO_TIMEOUT_MIN
Defaults timestamp_type=global
EOF
    visudo -cqf "$tmp" || die "generated sudoers is invalid: $tmp"
    put 440 /etc/sudoers.d/10-workstation < "$tmp"; rm -f "$tmp"

    # Fingerprint accepted for sudo; falls back to the password after 2 tries / 10 s.
    grep -q pam_fprintd /etc/pam.d/sudo ||
        sed -i '0,/^auth/s//auth\t\tsufficient\tpam_fprintd.so max-tries=2 timeout=10\n&/' /etc/pam.d/sudo
    as_user xdg-user-dirs-update || true
}

step_security() {
    log "firewall, sysctl, AppArmor, root lock"
    tpl "$FILES/nftables.conf" | put 644 /etc/nftables.conf
    nft -c -f /etc/nftables.conf || die "nftables.conf does not parse"
    if ! in_chroot && [[ -L /var/service/nftables ]]; then nft -f /etc/nftables.conf; fi   # apply now
    put 644 /etc/sysctl.d/90-hardening.conf < "$FILES/sysctl-hardening.conf"
    printf '* hard core 0\n' | put 644 /etc/security/limits.d/90-nocore.conf
    # AppArmor on Void = the kernel parameters below; enforce is the default mode (no config file)
    setkv /etc/default/grub GRUB_DISABLE_OS_PROBER false   # Windows Boot Manager in the grub menu (dual boot)
    cmdline_set apparmor 1
    cmdline_set security apparmor
    cmdline_set zswap.enabled 0          # swap is a plain swapfile, no RAM compression
    if [[ -f /swap/swapfile ]]; then     # hibernate into the swapfile (encrypted only with ENCRYPT=yes)
        cmdline_set resume "UUID=$(findmnt -no UUID -T /swap/swapfile)"
        cmdline_set resume_offset "$(btrfs inspect-internal map-swapfile -r /swap/swapfile)"
        echo 'add_dracutmodules+=" resume "' | put 644 /etc/dracut.conf.d/20-resume.conf
    fi
    put 644 /etc/NetworkManager/conf.d/20-privacy.conf <<'EOF'
[device]
wifi.scan-rand-mac-address=yes

[connection]
# stable random MAC per network, IPv6 temporary addresses
wifi.cloned-mac-address=stable
ipv6.ip6-privacy=2
EOF
    sv_disable sshd dhcpcd wpa_supplicant acpid power-profiles-daemon
    sv_enable nftables
    # Root login is only useful as an attack target once the user can sudo.
    if [[ $(passwd -S "$USERNAME" | awk '{print $2}') == P ]] && id -nG "$USERNAME" | grep -qw wheel; then
        passwd -l root >/dev/null
    fi
}

nosnap_subvol() { # turn a path into a nested btrfs subvolume so snapshots of its parent skip it
    local p=$1
    btrfs subvolume show "$p" &>/dev/null && return 0
    as_user mkdir -p "$(dirname "$p")"
    [[ -e $p ]] && mv "$p" "$p.old"
    btrfs subvolume create "$p" >/dev/null
    if [[ -e $p.old ]]; then cp -a --reflink=auto "$p.old/." "$p/"; rm -rf "$p.old"; fi
    chown "$USERNAME:$USERNAME" "$p"
}

step_snapper() {
    log "snapper: root + home every $SNAPSHOT_EVERY_MIN min"
    if [[ ! -f /etc/snapper/configs/root ]]; then
        # snapper insists on creating /.snapshots itself; swap it for the top-level @snapshots
        # subvolume so snapper-rollback can replace @ without losing the snapshots.
        umount /.snapshots 2>/dev/null || true
        rmdir /.snapshots
        snapper --no-dbus -c root create-config /
        btrfs subvolume delete /.snapshots >/dev/null
        mkdir /.snapshots
        mount /.snapshots
    fi
    [[ -f /etc/snapper/configs/home ]] || snapper --no-dbus -c home create-config /home
    chmod 750 /.snapshots /home/.snapshots
    local c
    for c in root home; do
        # TIMELINE_CREATE only switches snapper's systemd timer; snapshots come from snapper-tick (cron)
        snapper --no-dbus -c "$c" set-config TIMELINE_CREATE=no TIMELINE_CLEANUP=yes TIMELINE_MIN_AGE=3600 \
            TIMELINE_LIMIT_HOURLY="$SNAP_KEEP_HOURLY" TIMELINE_LIMIT_DAILY="$SNAP_KEEP_DAILY" \
            TIMELINE_LIMIT_WEEKLY="$SNAP_KEEP_WEEKLY" TIMELINE_LIMIT_MONTHLY="$SNAP_KEEP_MONTHLY" \
            TIMELINE_LIMIT_YEARLY=0 NUMBER_CLEANUP=yes NUMBER_LIMIT=20 ALLOW_GROUPS=wheel SYNC_ACL=yes \
            FREE_LIMIT=0.2   # cleanup also deletes old snapshots until 20 % of the disk is free
    done
    # snapper-rollback mounts the btrfs top level itself, so nothing (search, backups, Thunar) sees
    # every snapshot under a permanent /btrfsroot mount.
    local fs_uuid; fs_uuid=$(findmnt -no UUID /)
    if grep -qE '^#?\s*dev\s*=' /etc/snapper-rollback.conf; then
        sed -i -E "s|^#?\s*dev\s*=.*|dev = /dev/disk/by-uuid/$fs_uuid|" /etc/snapper-rollback.conf
    else
        echo "dev = /dev/disk/by-uuid/$fs_uuid" >> /etc/snapper-rollback.conf
    fi
    if grep -q ' /btrfsroot ' /etc/fstab; then   # installs made before 2026-10-14
        sed -i '\| /btrfsroot |d' /etc/fstab
        umount /btrfsroot 2>/dev/null || true
    fi
    local rel
    for rel in "${HOME_NOSNAP[@]}"; do nosnap_subvol "$UHOME/$rel"; done
    put 755 /usr/local/bin/snapper-tick < "$FILES/snapper-tick"
    put 644 /etc/cron.d/snapper-tick <<EOF
PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin
*/$SNAPSHOT_EVERY_MIN * * * * root /usr/local/bin/snapper-tick
EOF
}

# Noctalia Greeter has no releases yet: build its main branch (only when it changed). 0 = installed.
build_greeter() {
    local src=/var/cache/noctalia-greeter-src head jobs
    head=$(git ls-remote https://github.com/noctalia-dev/noctalia-greeter HEAD 2>/dev/null | cut -f1)
    [[ -n $head ]] || { warn "Noctalia Greeter: GitHub unreachable"; command -v noctalia-greeter-session >/dev/null; return; }
    mkdir -p /var/lib/enter_void
    [[ $(cat /var/lib/enter_void/greeter.version 2>/dev/null) == "$head" ]] && return 0
    log "building Noctalia Greeter ${head:0:8}"
    rm -rf "$src"
    git clone -q --depth 1 https://github.com/noctalia-dev/noctalia-greeter "$src"
    jobs=$(build_jobs)
    if (cd "$src" && meson setup build-release --prefix=/usr --buildtype=release &&
        meson compile -C build-release -j "$jobs" && meson install -C build-release); then
        echo "$head" > /var/lib/enter_void/greeter.version
    else
        warn "Noctalia Greeter build failed"
        return 1
    fi
}

# Login screen: Noctalia Greeter (graphical, matches the shell) or tuigreet (text) as the fallback.
step_login() {
    put 755 /usr/local/bin/niri-void-session < "$FILES/niri-void-session"
    # what the greeter offers: niri's own niri.desktop runs niri-session, which needs systemd
    put 644 /usr/local/share/wayland-sessions/niri-void.desktop <<'EOF'
[Desktop Entry]
Name=Niri (Void)
Comment=niri + Noctalia, runit session
Exec=/usr/local/bin/niri-void-session
Type=Application
DesktopNames=niri
EOF
    local cmd
    if [[ $GREETER == noctalia ]] && build_greeter && command -v noctalia-greeter-session >/dev/null; then
        log "login: Noctalia Greeter"
        install -d -o _greeter -g _greeter -m 750 /var/lib/noctalia-greeter
        GREETER_USER=_greeter noctalia-greeter-apply-appearance --setup-system || warn "greeter appearance setup failed"
        put 644 /var/lib/noctalia-greeter/greeter.toml <<EOF
[user]
default = "$USERNAME"

[session]
default = "Niri (Void)"
EOF
        cmd=$(command -v noctalia-greeter-session)
        # VMware (vmwgfx): wlroots cannot import the greeter's GPU buffers ("Failed to close buffer handle",
        # then a blank screen). Software rendering for the login screen only; niri itself is unaffected.
        if in_vmware; then cmd="env WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1 $cmd"; fi
    else
        log "login: tuigreet (text)"
        install -d -o _greeter -g _greeter /var/cache/tuigreet
        cmd="tuigreet --time --remember --asterisks --greeting '$HOSTNAME' --cmd /usr/local/bin/niri-void-session"
    fi
    # takes effect at the next login; greetd is not restarted under a running session
    put 644 /etc/greetd/config.toml <<EOF
[terminal]
vt = 7

[default_session]
command = "$cmd"
user = "_greeter"
EOF
    # unlock gnome-keyring with the login password
    grep -q pam_gnome_keyring /etc/pam.d/greetd || printf '%s\n' \
        'auth       optional     pam_gnome_keyring.so' \
        'session    optional     pam_gnome_keyring.so auto_start' >> /etc/pam.d/greetd
}

# copy_dotfiles keep|replace: repo dotfiles -> home. keep = only missing files (normal runs);
# replace = also overwrite changed ones, the old file goes to ~/.backup/<name> <date>.
copy_dotfiles() {
    local src dst stamp
    stamp=$(date '+%F %H-%M-%S')
    while IFS= read -r -d '' src; do
        dst=$UHOME/${src#"$FILES/home/"}
        if [[ -e $dst ]] && tpl "$src" | cmp -s - "$dst"; then continue; fi
        if [[ -e $dst ]]; then
            if [[ $1 == keep ]]; then log "kept your $dst (repo version differs)"; continue; fi
            as_user mkdir -p "$UHOME/.backup"
            as_user cp -a "$dst" "$UHOME/.backup/$(basename "$dst") $stamp"
            log "replaced $dst (old one in ~/.backup)"
        fi
        as_user mkdir -p "$(dirname "$dst")"
        tpl "$src" | as_user tee "$dst" >/dev/null
    done < <(find "$FILES/home" -type f -print0)
}

# Not part of "all": take the repo's current dotfiles, e.g. after a git pull with look changes.
step_dotfiles() {
    log "dotfiles: replacing changed ones with the repo version"
    copy_dotfiles replace
    log "log out and back in (or: pkill noctalia; setsid -f noctalia) to see the changes"
}

step_desktop() {
    log "services, audio, power, fonts, theme, dotfiles"
    sv_enable dbus elogind polkitd NetworkManager bluetoothd chronyd cronie socklog-unix nanoklogd \
        cupsd cups-browsed avahi-daemon ipp-usb tlp tlp-pd snapperd greetd earlyoom smartd
    # thermald only on Intel hardware with thermal sensors: in a VM it fails and runit restarts it every 2 s
    if grep -q GenuineIntel /proc/cpuinfo && compgen -G "/sys/class/thermal/thermal_zone*" >/dev/null && ! in_vmware; then
        sv_enable thermald
    else
        sv_disable thermald
    fi
    if in_vmware; then sv_enable vmtoolsd vmware-vmblock-fuse; fi

    # cron must never run a script the desktop user can edit: keep a root-owned copy
    if [[ $HERE != /usr/local/lib/enter_void ]]; then
        rm -rf /usr/local/lib/enter_void.new
        cp -r "$HERE" /usr/local/lib/enter_void.new
        chown -R root:root /usr/local/lib/enter_void.new
        rm -rf /usr/local/lib/enter_void
        mv /usr/local/lib/enter_void.new /usr/local/lib/enter_void
    fi
    mkdir -p /var/lib/enter_void
    put 755 /usr/local/bin/battery-guard < "$FILES/battery-guard"
    put 755 /usr/local/bin/power-ok < "$FILES/power-ok"
    put 755 /usr/local/bin/update-notify < "$FILES/update-notify"
    put 644 /etc/cron.d/enter_void <<'EOF'
PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin
# package index refresh, so update-notify (desktop) can count pending updates
17 */6 * * * root xbps-install -S >/dev/null 2>&1
# Helium, Floorp, Resilio, RustDesk, fonts, cursor, Noctalia: once a day, only on AC with battery above 80 %
# (skipped while an app runs). Checked hourly against a stamp, so a laptop that was off, asleep or low
# on battery catches up as soon as it can.
47 * * * * root power-ok 80 && ! find /var/lib/enter_void/apps.stamp -mmin -1440 2>/dev/null | grep -q . && /usr/local/lib/enter_void/setup.sh apps >/dev/null 2>&1 && touch /var/lib/enter_void/apps.stamp
# monthly checksum scrub of the whole btrfs filesystem
0 11 1 * * root btrfs scrub start -Bd / >/dev/null 2>&1 || logger -t enter_void "btrfs scrub reported errors"
# BORE kernel: rebuilt only when Void ships a new kernel, and only on AC power
23 */6 * * * root /usr/local/lib/enter_void/setup.sh kernel >/dev/null 2>&1
# plocate file-name index
30 12 * * * root updatedb
# hibernate at 5 % battery (elogind has no suspend-then-hibernate)
*/2 * * * * root battery-guard
EOF
    put 644 /etc/updatedb.conf <<'EOF'
PRUNE_BIND_MOUNTS="yes"
PRUNEFS="tmpfs proc sysfs devtmpfs devpts fuse.gvfsd-fuse fuse.rclone fuse.pCloud"
PRUNENAMES=".git .snapshots node_modules"
PRUNEPATHS="/tmp /var/tmp /var/cache /.snapshots /home/.snapshots /btrfsroot /swap /proc /sys /run"
EOF
    # user tool dirs on PATH for everything started from the session, not only shells
    put 644 /etc/profile.d/enter_void.sh <<'EOF'
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$HOME/go/bin:$HOME/.deno/bin:$PATH"
EOF

    mkdir -p /etc/pipewire/pipewire.conf.d /etc/alsa/conf.d
    ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
    ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
    ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/
    ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/

    put 644 /etc/tlp.d/10-x1.conf < "$FILES/tlp.conf"
    # .local hostnames (printers, scanners) through avahi
    grep -q mdns_minimal /etc/nsswitch.conf ||
        sed -i 's/^hosts:.*files/& mdns_minimal [NOTFOUND=return]/' /etc/nsswitch.conf
    # cups-browsed defaults to LocalOnly (USB only): also add a queue for every IPP Everywhere /
    # AirPrint printer announced on the network. Later lines win, so the block goes at the end.
    if ! grep -q '^# enter_void' /etc/cups/cups-browsed.conf; then
        sed -i -E 's/^(BrowseRemoteProtocols|CreateIPPPrinterQueues)\b/#&/' /etc/cups/cups-browsed.conf
        printf '%s\n' '# enter_void' 'BrowseRemoteProtocols dnssd' 'CreateIPPPrinterQueues All' >> /etc/cups/cups-browsed.conf
    fi
    # bluetooth: power on at boot, report headset battery level to Noctalia
    sed -i -E -e 's/^#?\s*AutoEnable\s*=.*/AutoEnable = true/' \
        -e 's/^#?\s*Experimental\s*=.*/Experimental = true/' /etc/bluetooth/main.conf

    put 644 /etc/fonts/local.conf < "$FILES/fonts-local.conf"
    ln -sf /usr/share/fontconfig/conf.avail/70-no-bitmaps.conf /etc/fonts/conf.d/
    put 644 /etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF
    put 644 /etc/dconf/db/local.d/00-workstation <<'EOF'
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='Adwaita-dark'
icon-theme='Papirus-Dark'
font-name='Inter 10'
document-font-name='Inter 10'
monospace-font-name='JetBrains Mono 10'
font-antialiasing='grayscale'
font-hinting='slight'
cursor-theme='Bibata-Modern-Classic'
cursor-size=24
EOF
    dconf update

    copy_dotfiles keep
    as_user mkdir -p "$UHOME/Pictures/Screenshots" "$UHOME/Pictures/Wallpapers"
    # default wallpaper (public domain, Hokusai) - matches the Kanagawa palette
    local wp=$UHOME/Pictures/Wallpapers/great-wave.jpg
    if [[ ! -s $wp ]] && ! as_user curl -fsSL --max-time 120 -o "$wp" \
        https://upload.wikimedia.org/wikipedia/commons/a/a5/Tsunami_by_hokusai_19th_century.jpg; then
        rm -f "$wp"
        warn "wallpaper download failed; put any image into ~/Pictures/Wallpapers"
    fi
    if [[ $HERE != "$UHOME/enter_void" ]]; then   # keep a copy for later re-runs
        rm -rf "$UHOME/enter_void"
        cp -r "$HERE" "$UHOME/enter_void"
        chown -R "$USERNAME:$USERNAME" "$UHOME/enter_void"
    fi
}

# --- upstream software outside the Void repos -------------------------------------------------
gh_asset() { # gh_asset <owner/repo> <asset-name regex> -> download URL of the latest release
    curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" |
        jq -r --arg re "$2" '[.assets[] | select(.name | test($re))][0].browser_download_url // empty' ||
        die "GitHub API request failed for $1 (rate limit is 60/hour)"
}
opt_install() { # opt_install <dest dir> <url> <tar --strip-components> <version key> [folder inside the archive]
    local dest=$1 tmp
    [[ -n $2 ]] || die "no download URL for $dest"
    if [[ $(cat "$dest/.version" 2>/dev/null) == "$4" ]]; then log "$dest is current"; return 0; fi
    # swapping the directory under a running browser crashes it; the next cron run retries
    if pgrep -f "^$dest/" >/dev/null; then warn "$dest is in use - update postponed"; return 0; fi
    log "installing $dest from $2"
    mkdir -p "$(dirname "$dest")"
    tmp=$(mktemp -d "$(dirname "$dest")/.install.XXXXXX")
    curl -fL --retry 3 --max-time 900 -o "$tmp/pkg" "$2"
    mkdir "$tmp/root"
    tar -xf "$tmp/pkg" -C "$tmp/root" --strip-components="$3" --no-same-owner ${5:+"$5"}
    echo "$4" > "$tmp/root/.version"
    rm -rf "$dest.old"
    [[ -d $dest ]] && mv "$dest" "$dest.old"
    mv "$tmp/root" "$dest"
    rm -rf "$dest.old" "$tmp"
}
desktop_entry() { # desktop_entry <id> <Name> <Exec> <Icon> <Categories> [MimeType]
    put 644 "/usr/local/share/applications/$1.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=$2
Exec=$3
Icon=$4
Categories=$5
${6:+MimeType=$6}
Terminal=false
EOF
}
font_zip() { # font_zip <dir> <owner/repo>
    local url dest=/usr/local/share/fonts/$1 tmp
    url=$(gh_asset "$2" '\.zip$')
    [[ -n $url ]] || die "no font zip for $2"
    [[ $(cat "$dest/.version" 2>/dev/null) == "$url" ]] && return 0
    log "font $1"
    tmp=$(mktemp -d)
    curl -fL --retry 3 --max-time 300 -o "$tmp/f.zip" "$url"
    rm -rf "$dest"; mkdir -p "$dest"
    # unpack everything and copy the .ttf files: unzip's own '*' does not match across folders on Void
    unzip -q "$tmp/f.zip" -d "$tmp/x"
    find "$tmp/x" -name '*.ttf' -exec cp -t "$dest" {} +
    compgen -G "$dest/*.ttf" >/dev/null || die "no .ttf files in $url"
    echo "$url" > "$dest/.version"
    rm -rf "$tmp"
}

step_apps() {
    local url web="text/html;x-scheme-handler/http;x-scheme-handler/https;application/xhtml+xml;application/pdf"

    url=$(gh_asset imputnet/helium-linux 'x86_64_linux\.tar\.xz$')
    opt_install /opt/helium "$url" 1 "$url"
    # libsecret: on niri Chromium can't detect a desktop and would store passwords unencrypted.
    # VA-API: hardware video decode on Iris Xe (battery).
    put 755 /usr/local/bin/helium <<'EOF'
#!/bin/sh
exec /opt/helium/helium-wrapper --ozone-platform-hint=auto --password-store=gnome-libsecret \
    --enable-features=AcceleratedVideoDecodeLinuxGL,AcceleratedVideoDecodeLinuxZeroCopyGL,AcceleratedVideoEncoder "$@"
EOF
    desktop_entry helium Helium "helium %U" /opt/helium/product_logo_256.png "Network;WebBrowser;" "$web"

    url=$(gh_asset Floorp-Projects/Floorp '^floorp-linux-x86_64\.tar\.xz$')
    opt_install /opt/floorp "$url" 1 "$url"
    ln -sf /opt/floorp/floorp /usr/local/bin/floorp
    desktop_entry floorp Floorp "floorp %u" /opt/floorp/browser/chrome/icons/default/default128.png "Network;WebBrowser;" "$web"

    url=https://download-cdn.resilio.com/stable/linux/x64/0/resilio-sync_x64.tar.gz
    opt_install /opt/resilio "$url" 0 "$(curl -fsIL --max-time 30 "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{e=$2} END{print e}')"
    ln -sf /opt/resilio/rslsync /usr/local/bin/rslsync
    put 755 /usr/local/bin/resilio < "$FILES/resilio"
    desktop_entry resilio "Resilio Sync" "resilio start" folder-sync "Network;FileTransfer;"

    # pCloud: `cloud` (rclone) is the default; pcloud-install keeps the official app as an option
    put 755 /usr/local/bin/cloud < "$FILES/cloud"
    desktop_entry pcloud-folder "pCloud" "cloud open" folder-cloud "Network;FileTransfer;"
    put 755 /usr/local/bin/pcloud-install < "$FILES/pcloud-install"

    # RustDesk: no tarball upstream; its Arch package is a plain .tar.zst. Unpack usr/share/rustdesk to the
    # same path (the app may expect it there). No systemd service: start it when you need it.
    url=$(gh_asset rustdesk/rustdesk 'x86_64\.pkg\.tar\.zst$')
    opt_install /usr/share/rustdesk "$url" 3 "$url" usr/share/rustdesk
    ln -sf /usr/share/rustdesk/rustdesk /usr/local/bin/rustdesk
    desktop_entry rustdesk RustDesk "rustdesk" rustdesk "Network;RemoteAccess;"

    font_zip JetBrainsMono JetBrains/JetBrainsMono
    font_zip CascadiaCode microsoft/cascadia-code
    fc-cache -f >/dev/null

    # cursor: not packaged by Void; /usr/share/icons is on every toolkit's default cursor path
    url=$(gh_asset ful1e5/Bibata_Cursor '^Bibata-Modern-Classic\.tar\.xz$')
    opt_install /usr/share/icons/Bibata-Modern-Classic "$url" 1 "$url"

    local tag src=/var/cache/noctalia-src
    tag=$(curl -fsSL --max-time 30 https://api.github.com/repos/noctalia-dev/noctalia/releases/latest | jq -r .tag_name)
    [[ $tag == v* ]] || die "could not read the latest Noctalia release tag"
    if [[ $(cat /usr/local/share/noctalia/.version 2>/dev/null) == "$tag" ]]; then
        log "Noctalia $tag is current"
    elif pgrep -x noctalia >/dev/null && [[ ! -t 0 ]]; then
        warn "Noctalia $tag is out, but the shell is running - run 'sudo setup.sh apps' from a terminal"
    else
        log "building Noctalia $tag (a few minutes)"
        rm -rf "$src"
        git clone -q --depth 1 --branch "$tag" https://github.com/noctalia-dev/noctalia "$src"
        # `just build` runs one C++ job per CPU thread (~0.7 GB each) and runs out of memory on small
        # machines/VMs, so compile with a memory-sized job count; `just install` never recompiles.
        local jobs; jobs=$(build_jobs)
        log "compiling with $jobs parallel jobs (sized to free memory)"
        (cd "$src" && just configure release &&
            meson configure build-release -Db_lto_threads="$jobs" &&
            meson compile -C build-release -j "$jobs" noctalia &&
            rm -f /usr/local/bin/noctalia &&   # a running shell keeps its copy; no "text file busy"
            just install release)
        echo "$tag" > /usr/local/share/noctalia/.version
    fi
}

step_devtools() {
    log "Rust (rustup), Claude Code, Antigravity CLI, Deno, oh-my-pi"
    # Each one updates itself afterwards (rustup update / claude auto-update / agy / omp installer re-run).
    # A failure only warns: these come from external installers and must not break the system setup.
    as_user mkdir -p "$UHOME/.local/bin"
    [[ -x $UHOME/.cargo/bin/cargo ]] ||
        as_user rustup-init -y --no-modify-path --profile default || warn "rustup-init failed"
    [[ -x $UHOME/.local/bin/claude ]] ||
        as_user bash -o pipefail -c 'curl -fsSL https://claude.ai/install.sh | bash' || warn "Claude Code install failed"
    [[ -x $UHOME/.local/bin/agy ]] ||
        as_user bash -o pipefail -c 'curl -fsSL https://antigravity.google/cli/install.sh | bash' ||
        warn "Antigravity CLI install failed (needs AES-NI; in a VM pass the host CPU through)"
    [[ -x $UHOME/.deno/bin/deno ]] ||
        as_user bash -o pipefail -c 'curl -fsSL https://deno.land/install.sh | sh -s -- -y' || warn "Deno install failed"
    [[ -x $UHOME/.local/bin/omp ]] ||
        as_user bash -o pipefail -c 'curl -fsSL https://omp.sh/install | sh -s -- --binary' || warn "oh-my-pi install failed"
}

build_jobs() { # parallel compile jobs that fit in RAM: ~1.5 GB per C++ job (estimate), between 1 and nproc
    local n
    n=$(awk '/^MemAvailable:/ {print int($2 / 1572864)}' /proc/meminfo)
    (( n < 1 )) && n=1
    (( n > $(nproc) )) && n=$(nproc)
    echo "$n"
}
# X1 speakers: Lenovo ships a Dolby speaker tuning for this exact laptop (codec 0287, subsystem 17AA22E7) in its
# Windows driver. speaker-tuning-to-easyeffects (MIT) turns it into an EasyEffects preset that is loaded
# automatically for the internal speakers. The proprietary file is read from the Windows partition (read-only)
# and never copied into this repo. Needs the running desktop (PipeWire), so it is skipped in the install chroot.
step_speakers() {
    if in_chroot; then log "speakers: tuned after the first boot (sudo ~/enter_void/setup.sh speakers)"; return 0; fi
    local win=/run/enter_void-windows part found="" src=/var/cache/speaker-tuning
    mkdir -p "$win"
    while read -r part; do
        mountpoint -q "$win" || mount -t ntfs3 -o ro "$part" "$win" 2>/dev/null ||
            mount -t ntfs-3g -o ro "$part" "$win" 2>/dev/null || continue
        if [[ -d $win/Windows/System32/DriverStore ]]; then found=$part; break; fi
        umount "$win"
    done < <(lsblk -lnpo NAME,FSTYPE | awk '$2 == "ntfs" {print $1}')
    if [[ -z $found ]]; then warn "speakers: no Windows partition with Lenovo's audio driver - skipped"; return 0; fi
    log "speakers: Dolby tuning from $found"
    install -d -o "$USERNAME" -g "$USERNAME" "$src"
    if [[ -d $src/.git ]]; then as_user git -C "$src" pull -q --ff-only || true
    else as_user git clone -q --depth 1 https://github.com/antoinecellerier/speaker-tuning-to-easyeffects "$src"; fi
    as_user python3 "$src/dolby_to_easyeffects.py" --windows "$win" --autoload ||
        warn "speakers: conversion failed - run it by hand: python3 $src/dolby_to_easyeffects.py --doctor"
    umount "$win"
}

on_ac() { # true on mains power, or when there is no battery at all (desktop, VM)
    local p
    compgen -G '/sys/class/power_supply/BAT*' >/dev/null || return 0
    for p in /sys/class/power_supply/*; do
        [[ $(cat "$p/type" 2>/dev/null) == Mains && $(cat "$p/online" 2>/dev/null) == 1 ]] && return 0
    done
    return 1
}

# BORE scheduler (as in CachyOS): Void's stock kernel template + CachyOS's standalone BORE patch, built with
# xbps-src as linux<series>-bore. The stock kernel stays installed and in the grub menu as the fallback.
step_kernel() {
    [[ $KERNEL_BORE == yes ]] || { log "BORE kernel disabled in config.sh"; return 0; }
    if in_chroot; then
        log "BORE kernel: built after the first boot by cron (on AC power, about an hour), or run: sudo setup.sh kernel"
        return 0
    fi
    exec 9>/run/enter_void-kernel.lock
    flock -n 9 || { log "a BORE kernel build is already running"; return 0; }
    local vp=/var/cache/void-packages series src pkg tver trev cur patch t free
    install -d -o "$USERNAME" -g "$USERNAME" "$vp"
    if [[ -d $vp/.git ]]; then
        as_user git -C "$vp" fetch -q --depth 1 origin master
        as_user git -C "$vp" reset -q --hard FETCH_HEAD
    else
        as_user git clone -q --depth 1 https://github.com/void-linux/void-packages "$vp"
    fi
    series=$(sed -n 's/^version=//p' "$vp/srcpkgs/linux/template")
    src=$vp/srcpkgs/linux$series
    pkg=linux$series-bore
    tver=$(sed -n 's/^version=//p' "$src/template")
    trev=$(sed -n 's/^revision=//p' "$src/template")
    cur=$(xbps-query -p pkgver "$pkg" 2>/dev/null || true)
    if [[ $cur == "$pkg-${tver}_$trev" ]]; then log "$pkg ${tver}_$trev is current"; return 0; fi
    if [[ ! -t 0 ]] && ! on_ac; then log "on battery: $pkg build postponed"; return 0; fi
    free=$(df --output=avail -BG /var/cache | tail -n1 | tr -dc 0-9)
    (( free >= 25 )) || { warn "only ${free} GB free - a kernel build needs about 25 GB (estimate)"; return 0; }
    patch=$(curl -fsSL --max-time 60 "https://raw.githubusercontent.com/CachyOS/kernel-patches/master/$series/sched/0001-bore.patch") ||
        { warn "no BORE patch for linux $series yet - staying on the current kernel"; return 0; }

    # linux6.18 -> linux6.18-bore: own package name, and "-bore" in the kernel release so /boot and
    # /usr/lib/modules never collide with the stock kernel of the same version.
    rm -rf "$vp/srcpkgs/$pkg" "$vp/srcpkgs/$pkg-headers" "$vp/srcpkgs/$pkg-dbg"
    as_user cp -r "$src" "$vp/srcpkgs/$pkg"
    t=$(<"$vp/srcpkgs/$pkg/template")
    t=${t//"pkgname=linux$series"/"pkgname=$pkg"}
    t=${t//"linux$series-headers_package"/"$pkg-headers_package"}
    t=${t//"linux$series-dbg_package"/"$pkg-dbg_package"}
    local rev_lit="_\${revision}"                    # literal text in the template, not expanded here
    t=${t//"$rev_lit\""/"$rev_lit-bore\""}            # _kernver
    t=${t//"$rev_lit\\\""/"$rev_lit-bore\\\""}        # CONFIG_LOCALVERSION
    [[ $t == *"pkgname=$pkg"* && $(grep -c -- '-bore\\\?"' <<< "$t") -ge 2 ]] ||
        die "the linux$series template layout changed - update step_kernel in setup.sh"
    printf '%s\n' "$t" | as_user tee "$vp/srcpkgs/$pkg/template" >/dev/null
    as_user mkdir -p "$vp/srcpkgs/$pkg/patches"
    printf '%s\n' "$patch" | as_user tee "$vp/srcpkgs/$pkg/patches/0001-bore.patch" >/dev/null
    # the template prefers x86_64-dotconfig-custom: Void's config + the two options BORE adds
    { cat "$src/files/x86_64-dotconfig"; printf 'CONFIG_SCHED_BORE=y\nCONFIG_MIN_BASE_SLICE_NS=2000000\n'; } |
        as_user tee "$vp/srcpkgs/$pkg/files/x86_64-dotconfig-custom" >/dev/null
    as_user ln -sfn "$pkg" "$vp/srcpkgs/$pkg-headers"
    as_user ln -sfn "$pkg" "$vp/srcpkgs/$pkg-dbg"

    compgen -G "$vp/masterdir*" >/dev/null || as_user bash -c "cd '$vp' && ./xbps-src binary-bootstrap"
    log "building $pkg ${tver}_$trev (about an hour of compiling)"
    as_user bash -c "cd '$vp' && nice -n 19 ./xbps-src -j$(build_jobs) pkg $pkg"
    xbps-install -Sy --repository "$vp/hostdir/binpkgs" "$pkg"
    xbps-rindex -r "$vp/hostdir/binpkgs" >/dev/null 2>&1 || true
    as_user bash -c "cd '$vp' && ./xbps-src clean" >/dev/null 2>&1 || true

    local vmlinuz
    vmlinuz=$(xbps-query -f "$pkg" | grep -m1 '^/boot/vmlinuz-')
    setkv /etc/default/grub GRUB_TOP_LEVEL "$vmlinuz"   # boot BORE by default; stock kernel stays in the menu
    grub-mkconfig -o /boot/grub/grub.cfg
    log "BORE kernel installed ($vmlinuz) - reboot, then check: sysctl kernel.sched_bore"
}

step_finish() {
    log "rebuilding initramfs + grub menu"
    xbps-reconfigure -fa
    # installs from before 2026-10-15 keep a LUKS keyfile inside the initramfs: keep /boot private there
    if [[ -f /boot/cryptroot.key ]]; then find /boot -xdev -exec chmod g-rwx,o-rwx {} +; fi
}

steps=("$@")
[[ ${#steps[@]} -eq 0 || ${steps[0]} == all ]] && steps=(base packages user security snapper desktop apps login devtools speakers kernel finish)
for s in "${steps[@]}"; do
    declare -F "step_$s" >/dev/null || die "unknown step '$s'"
    "step_$s"
done
log "setup finished: ${steps[*]}  (log: $LOG)"
