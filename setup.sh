#!/usr/bin/env bash
# Stage 2 - run as root, inside the install chroot (install.sh does it) or later on the running system.
# Safe to re-run. Usage: sudo ./setup.sh [all | step...]
# Steps: base packages user security snapper login desktop apps     (e.g. `sudo ./setup.sh apps` updates browsers + Noctalia)
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
mkdir -p /var/log/void-workstation
LOG=/var/log/void-workstation/$(date +%F_%H-%M-%S)-setup.log
exec > >(tee -a "$LOG") 2>&1

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
as_user() { runuser -u "$USERNAME" -- "$@"; }

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
    xbps-install -Sy "${pkgs[@]}"
}

step_user() {
    log "user $USERNAME, sudo"
    id "$USERNAME" &>/dev/null || useradd -m -c "$FULLNAME" -s /bin/bash "$USERNAME"
    local g
    for g in wheel audio video input lp scanner network bluetooth storage optical plugdev _seatd; do
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
    put 644 /etc/sysctl.d/90-hardening.conf < "$FILES/sysctl-hardening.conf"
    printf '* hard core 0\n' | put 644 /etc/security/limits.d/90-nocore.conf
    setkv /etc/default/apparmor APPARMOR enforce
    grep -q 'apparmor=1' /etc/default/grub ||
        sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&apparmor=1 security=apparmor /' /etc/default/grub
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
        snapper --no-dbus -c "$c" set-config TIMELINE_CREATE=yes TIMELINE_CLEANUP=yes TIMELINE_MIN_AGE=3600 \
            TIMELINE_LIMIT_HOURLY="$SNAP_KEEP_HOURLY" TIMELINE_LIMIT_DAILY="$SNAP_KEEP_DAILY" \
            TIMELINE_LIMIT_WEEKLY="$SNAP_KEEP_WEEKLY" TIMELINE_LIMIT_MONTHLY="$SNAP_KEEP_MONTHLY" \
            TIMELINE_LIMIT_YEARLY=0 NUMBER_CLEANUP=yes NUMBER_LIMIT=20 ALLOW_GROUPS=wheel SYNC_ACL=yes
    done
    local rel
    for rel in "${HOME_NOSNAP[@]}"; do nosnap_subvol "$UHOME/$rel"; done
    put 755 /usr/local/bin/snapper-tick < "$FILES/snapper-tick"
    put 644 /etc/cron.d/snapper-tick <<EOF
PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin
*/$SNAPSHOT_EVERY_MIN * * * * root /usr/local/bin/snapper-tick
EOF
}

step_login() {
    log "greetd + tuigreet -> niri"
    put 755 /usr/local/bin/niri-void-session < "$FILES/niri-void-session"
    put 644 /etc/greetd/config.toml <<EOF
[terminal]
vt = 7

[default_session]
command = "tuigreet --time --remember --asterisks --greeting '$HOSTNAME' --cmd /usr/local/bin/niri-void-session"
user = "_greeter"
EOF
    install -d -o _greeter -g _greeter /var/cache/tuigreet
    # unlock gnome-keyring with the login password
    grep -q pam_gnome_keyring /etc/pam.d/greetd || printf '%s\n' \
        'auth       optional     pam_gnome_keyring.so' \
        'session    optional     pam_gnome_keyring.so auto_start' >> /etc/pam.d/greetd
}

step_desktop() {
    log "services, audio, power, fonts, theme, dotfiles"
    sv_enable dbus elogind polkitd NetworkManager bluetoothd chronyd cronie socklog-unix nanoklogd \
        cupsd cups-browsed avahi-daemon tlp tlp-pd thermald snapperd greetd

    mkdir -p /etc/pipewire/pipewire.conf.d /etc/alsa/conf.d
    ln -sf /usr/share/examples/wireplumber/10-wireplumber.conf /etc/pipewire/pipewire.conf.d/
    ln -sf /usr/share/examples/pipewire/20-pipewire-pulse.conf /etc/pipewire/pipewire.conf.d/
    ln -sf /usr/share/alsa/alsa.conf.d/50-pipewire.conf /etc/alsa/conf.d/
    ln -sf /usr/share/alsa/alsa.conf.d/99-pipewire-default.conf /etc/alsa/conf.d/

    put 644 /etc/tlp.d/10-x1.conf < "$FILES/tlp.conf"
    # .local hostnames (printers, scanners) through avahi
    grep -q mdns_minimal /etc/nsswitch.conf ||
        sed -i 's/^hosts:.*files/& mdns_minimal [NOTFOUND=return]/' /etc/nsswitch.conf

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
font-antialiasing='rgba'
font-hinting='slight'
EOF
    dconf update

    # dotfiles: copied once, never overwrite what you changed
    local src dst
    while IFS= read -r -d '' src; do
        dst=$UHOME/${src#"$FILES/home/"}
        if [[ -e $dst ]]; then
            tpl "$src" | cmp -s - "$dst" || log "kept your $dst (repo version differs)"
        else
            as_user mkdir -p "$(dirname "$dst")"
            tpl "$src" | as_user tee "$dst" >/dev/null
        fi
    done < <(find "$FILES/home" -type f -print0)
    as_user mkdir -p "$UHOME/Pictures/Screenshots" "$UHOME/Pictures/Wallpapers"
    if [[ $HERE != "$UHOME/void-workstation" ]]; then   # keep a copy for later re-runs
        rm -rf "$UHOME/void-workstation"
        cp -r "$HERE" "$UHOME/void-workstation"
        chown -R "$USERNAME:$USERNAME" "$UHOME/void-workstation"
    fi
}

# --- upstream software outside the Void repos -------------------------------------------------
gh_asset() { # gh_asset <owner/repo> <asset-name regex> -> download URL of the latest release
    curl -fsSL --max-time 30 "https://api.github.com/repos/$1/releases/latest" |
        jq -r --arg re "$2" '[.assets[] | select(.name | test($re))][0].browser_download_url // empty' ||
        die "GitHub API request failed for $1 (rate limit is 60/hour)"
}
opt_install() { # opt_install <name> <url> <tar --strip-components> <version key>
    local dest=/opt/$1 tmp
    [[ -n $2 ]] || die "no download URL for $1"
    if [[ $(cat "$dest/.version" 2>/dev/null) == "$4" ]]; then log "$1 is current"; return 0; fi
    log "installing $1 from $2"
    mkdir -p /opt
    tmp=$(mktemp -d /opt/.install.XXXXXX)
    curl -fL --retry 3 --max-time 900 -o "$tmp/pkg" "$2"
    mkdir "$tmp/root"
    tar -xf "$tmp/pkg" -C "$tmp/root" --strip-components="$3" --no-same-owner
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
    unzip -joq "$tmp/f.zip" '*.ttf' -d "$dest"
    echo "$url" > "$dest/.version"
    rm -rf "$tmp"
}

step_apps() {
    local url web="text/html;x-scheme-handler/http;x-scheme-handler/https;application/xhtml+xml;application/pdf"

    url=$(gh_asset imputnet/helium-linux 'x86_64_linux\.tar\.xz$')
    opt_install helium "$url" 1 "$url"
    printf '#!/bin/sh\nexec /opt/helium/helium-wrapper --ozone-platform-hint=auto "$@"\n' | put 755 /usr/local/bin/helium
    desktop_entry helium Helium "helium %U" /opt/helium/product_logo_256.png "Network;WebBrowser;" "$web"

    url=$(gh_asset Floorp-Projects/Floorp '^floorp-linux-x86_64\.tar\.xz$')
    opt_install floorp "$url" 1 "$url"
    ln -sf /opt/floorp/floorp /usr/local/bin/floorp
    desktop_entry floorp Floorp "floorp %u" /opt/floorp/browser/chrome/icons/default/default128.png "Network;WebBrowser;" "$web"

    url=https://download-cdn.resilio.com/stable/linux/x64/0/resilio-sync_x64.tar.gz
    opt_install resilio "$url" 0 "$(curl -fsIL --max-time 30 "$url" | tr -d '\r' | awk -F': ' 'tolower($1)=="etag"{e=$2} END{print e}')"
    ln -sf /opt/resilio/rslsync /usr/local/bin/rslsync
    put 755 /usr/local/bin/resilio < "$FILES/resilio"
    desktop_entry resilio "Resilio Sync" "resilio start" folder-sync "Network;FileTransfer;"

    put 755 /usr/local/bin/pcloud-install < "$FILES/pcloud-install"

    font_zip JetBrainsMono JetBrains/JetBrainsMono
    font_zip CascadiaCode microsoft/cascadia-code
    fc-cache -f >/dev/null

    local tag src=/var/cache/noctalia-src
    tag=$(curl -fsSL --max-time 30 https://api.github.com/repos/noctalia-dev/noctalia/releases/latest | jq -r .tag_name)
    [[ $tag == v* ]] || die "could not read the latest Noctalia release tag"
    if [[ $(cat /usr/local/share/noctalia/.version 2>/dev/null) != "$tag" ]]; then
        log "building Noctalia $tag (a few minutes)"
        rm -rf "$src"
        git clone -q --depth 1 --branch "$tag" https://github.com/noctalia-dev/noctalia "$src"
        (cd "$src" && just configure release && just build release && just install release)
        echo "$tag" > /usr/local/share/noctalia/.version
    else
        log "Noctalia $tag is current"
    fi
}

step_finish() {
    log "rebuilding initramfs + grub menu"
    xbps-reconfigure -fa
    find /boot -xdev -exec chmod g-rwx,o-rwx {} +   # the initramfs holds the LUKS keyfile (-xdev: skip the vfat ESP)
}

steps=("$@")
[[ ${#steps[@]} -eq 0 || ${steps[0]} == all ]] && steps=(base packages user security snapper login desktop apps finish)
for s in "${steps[@]}"; do
    declare -F "step_$s" >/dev/null || die "unknown step '$s'"
    "step_$s"
done
log "setup finished: ${steps[*]}  (log: $LOG)"
