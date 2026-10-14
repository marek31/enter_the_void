# enter_void - design

## Requirements
- Void Linux workstation on a ThinkPad X1 Carbon Gen 10 (21CC, i5-1250P, Iris Xe, 16 GB, 512 GB NVMe, 2560x1440, AX211, SOF audio, Synaptics 06cb:00fc fingerprint, USB4).
- Reproducible from a GitHub repo: one script from the live ISO, re-runnable setup afterwards.
- btrfs + snapper, snapshots every 15 min; caches, temp files, logs, swap and the snapshots themselves excluded.
- Wayland only: niri + Noctalia. Helium + Floorp. LibreOffice. Wifi printers + scanners. Fingerprint login for sudo and the lock screen.
- Resilio Sync and pCloud installed but started by hand.
- Hardened against network attacks. sudo password at most once per day. TLP for battery.
- Host `x1-void`, user Marek, Polish programmer's keyboard, Europe/Warsaw. Open-licence fonts usable on Windows too.

## Non-goals
- Flatpak, snap, AppImage runtime. Dual boot (install.sh wipes the whole disk). Secure Boot. Hibernation.
- X11 sessions (X apps run through xwayland-satellite). musl. Other laptops (works, but hardware bits target the X1).
- Off-machine backups: snapshots live on the same disk and are not a backup.

## Decisions (ADR)
- **Disk layout (frozen after install):** GPT, 1 GiB ESP at `/boot/efi`, LUKS1 on the rest, btrfs with flat subvolumes `@ @home @snapshots @var_log @var_cache @var_tmp @swap`, top level at `/btrfsroot`. `/boot` sits inside `@`, so a snapshot always holds a matching kernel + modules. Changing it means reinstalling.
- **LUKS1, not LUKS2:** grub can only unlock LUKS2 with PBKDF2 and is unreliable with it. A keyfile in the initramfs (`/boot/cryptroot.key`, mode 000, `/boot` chmod go-rwx) means the passphrase is typed once, at grub.
- **Snapshots:** snapper has no timer on Void (no systemd, and the package ships no cron script). `/usr/local/bin/snapper-tick` runs from `/etc/cron.d` every 15 min: creates a timeline snapshot per config, then cleans up. `TIMELINE_MIN_AGE=3600` keeps the last hour at 15-min resolution, then hourly 24 / daily 7 / weekly 4 / monthly 3. Exclusion = separate subvolume (btrfs snapshots stop at subvolume boundaries); home exclusions are in `HOME_NOSNAP`.
- **Root snapshots on `@snapshots`, not nested `/.snapshots`:** needed by `snapper-rollback`, which swaps `@` for a snapshot. Home uses snapper's default nested `/home/.snapshots`.
- **grub-btrfs without its daemon:** a daemon would rerun grub-mkconfig every 15 minutes. snapper-tick refreshes the menu once an hour.
- **Login:** greetd + tuigreet on vt7; `/usr/local/bin/niri-void-session` runs `dbus-run-session niri --session` because `niri-session` needs systemd. pipewire is started by niri.
- **Noctalia v5** is a native C++ app, no longer Quickshell-based, and not packaged in Void. It is built from the latest release tag with the deps listed in its BUILDING.md (all in Void), and installed to `/usr/local`. Password checks use the PAM `login` service; the fingerprint goes through fprintd D-Bus (`[lockscreen] fingerprint = true`).
- **Browsers/Resilio:** upstream tarballs into `/opt/<name>` (atomic swap, `.version` stamp). `setup.sh apps` updates them. HTTPS from the vendor/GitHub is the trust root; signatures are not checked (Helium ships `.asc`, but no pinned key here).
- **pCloud:** the only Linux build is an AppImage behind a per-session link, so it cannot be scripted. `pcloud-install` unpacks it into `/opt/pcloud` (no FUSE2 runtime needed to start it; `fuse`/`fuse3` are installed for its virtual drive).
- **Power:** TLP + tlp-pd (TLP's power-profiles D-Bus API, so Noctalia's profile switch works). It conflicts with power-profiles-daemon. thermald stays.
- **Firewall:** nftables, inbound default drop; allowed: established, loopback, rate-limited ICMP, DHCPv6, mDNS from LAN (printer/scanner discovery), Resilio port 55555 and LAN discovery 3838. No sshd. Resilio WebUI only on 127.0.0.1, UPnP off.
- **Hardening:** sysctl (kptr/dmesg restrict, no unprivileged BPF, ptrace scope 1, no redirects/source routes, rp_filter loose), AppArmor enforce, no core dumps, root account locked, NetworkManager random MAC for scans and a stable random MAC per network, IPv6 privacy addresses.
- **sudo:** `timestamp_timeout=1440` + `timestamp_type=global`, so one password per day across all terminals (reset on reboot). pam_fprintd is `sufficient` in `/etc/pam.d/sudo`. Login stays password-only so gnome-keyring unlocks.
- **User name:** `marek` login with full name "Marek". shadow's useradd rejects capitals by default.
- **Locale:** English UI, Polish formats (LC_TIME, LC_PAPER=A4, ...). LC_NUMERIC stays English, because a decimal comma breaks scripts.
- **Fonts:** Void packages plus JetBrains Mono and Cascadia Code from their GitHub releases, which Void doesn't package. All are OFL/Apache, the same files install on Windows.

## Dead ends
- `power-profiles-daemon`: replaced by TLP on request; the two conflict.
- Noctalia from the release tarball: the release assets are source, and the docs only describe building from git.
- `hunspell-pl_PL`, `font-jetbrains-mono`, `adw-gtk3`, `mission-center`, `rustdesk` don't exist in the Void repos (checked 2026-10-14).

## Known gotchas
- grub unlocking LUKS1 takes about 10-20 s after the passphrase. That's normal.
- Booting a snapshot from grub gives a read-only `/`. Use it to inspect, then `snapper-rollback N` + reboot.
- The GitHub API allows 60 unauthenticated requests per hour; `setup.sh apps` uses about 5.
- `nft -c` validates the ruleset at setup time; after hand edits run `sudo nft -c -f /etc/nftables.conf` before restarting.
- Dotfiles are copied only when missing. To take a new repo version, delete your file and rerun `setup.sh desktop`.
- `sv` commands do nothing inside the chroot; services are enabled by symlinks in `/etc/runit/runsvdir/default`.

## Current functionality
install.sh: disk wipe + LUKS1 + btrfs subvolumes + bootstrap + fstab + keyfile + grub, then setup.sh in a chroot.
setup.sh steps: base (host, tz, locale, console), packages, user (groups, sudo, fingerprint for sudo), security, snapper, login, desktop (services, audio, TLP, fonts, dconf theme, dotfiles), apps (Helium, Floorp, Resilio, pCloud installer, fonts, Noctalia), finish (initramfs + grub).

## Changelog
- 2026-10-14: first version.
