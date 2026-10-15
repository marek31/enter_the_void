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
- Flatpak, snap, AppImage runtime. Secure Boot (not decided yet).
- X11 sessions (X apps run through xwayland-satellite). musl. Other laptops (works, but hardware bits target the X1).
- Automatic off-machine backups: restic + rclone are installed, but the target (pCloud, external disk) is not decided yet.

## Decisions (ADR)
- **Disk layout (frozen after install):** GPT, 1 GiB ESP at `/boot/efi`, LUKS1 on the rest, btrfs with flat subvolumes `@ @home @snapshots @var_log @var_cache @var_tmp @swap`, top level mounted at `/btrfsroot` only by snapper-rollback (`dev=` in its config). `/boot` sits inside `@`, so a snapshot always holds a matching kernel + modules. Changing it means reinstalling.
- **Install modes:** `free` (X1, dual boot) creates one partition in the largest unallocated area (>= `MIN_FREE_GIB`) with `sfdisk --append`, 1 MiB aligned, and shares the existing EFI partition without formatting it; grub goes to `EFI\Void`, `--removable` is not used so `EFI\Boot\bootx64.efi` (Windows fallback) stays. `GRUB_DISABLE_OS_PROBER=false` + os-prober put Windows Boot Manager in the menu. `wipe` (VM, blank disk) creates a fresh GPT with a 1 GiB EFI partition. Only disks with nothing mounted are offered in either mode.
- **Swap:** a plain swapfile `/swap/swapfile` (`btrfs filesystem mkswapfile`, size `SWAP_GIB`), no swap partition, no zram, and `zswap.enabled=0` on the kernel command line so the kernel does no RAM compression. The file sits in its own `@swap` subvolume because btrfs can't snapshot a subvolume holding an active swapfile.
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
- **Look (minimal):** Noctalia owns the palette (builtin Kanagawa) and pushes it through its builtin templates to niri (`include "noctalia.kdl"`), foot, GTK 3/4, qt5ct/qt6ct, KDE colour scheme, btop and starship, so there is one colour scheme everywhere and switching it in Settings restyles everything. Dotfiles therefore hold layout only, no colours (niri keeps fallback colours). One vertical capsule bar on the left (no top/bottom bar) with launcher + 7 widgets, 2 px single-colour focus ring, no borders, soft shadow, 12 px corners, Inter + JetBrains Mono, Bibata cursor (GitHub release, Void has no package), Hokusai wallpaper (public domain, Wikimedia).
- **Upkeep (cron, root-owned copy in /usr/local/lib/enter_void):** `xbps-install -S` + `setup.sh apps` every 6 h (an app in use is skipped, so a running browser is never swapped out), monthly `btrfs scrub`, daily `updatedb`, `battery-guard` every 2 min. The desktop gets update notices from `update-notify`. Cron never runs a script the user can edit.
- **Hibernation:** into the swapfile (`resume=` + `resume_offset=` from `btrfs inspect-internal map-swapfile`, dracut `resume` module). elogind has no suspend-then-hibernate, so `battery-guard` hibernates at 5 % while discharging; it cannot run during suspend.
- **Dev tools:** Go from xbps, Rust through rustup (`~/.cargo`), Claude Code / Antigravity CLI / oh-my-pi through their official checksum-verifying installers into `~/.local/bin`, run as the user. Each updates itself. A failed installer only warns.
- **BORE scheduler:** no Void package and no prebuilt runit-friendly kernel exists, so `setup.sh kernel` clones void-packages into `/var/cache/void-packages` (never snapshotted), copies the stock `linux<series>` template to `linux<series>-bore` (own pkgname, `-bore` in `_kernver` and `CONFIG_LOCALVERSION` so /boot and /usr/lib/modules never collide), adds CachyOS's standalone `<series>/sched/0001-bore.patch`, and `x86_64-dotconfig-custom` = Void config + `CONFIG_SCHED_BORE=y`, `CONFIG_MIN_BASE_SLICE_NS=2000000` (the only options the patch adds, so `make oldconfig` never prompts). Built as the user with xbps-src, installed from the local repo, made default with `GRUB_TOP_LEVEL`. Stock kernel stays installed as the fallback. Not built in the install chroot (an hour of compiling); cron checks every 6 h and rebuilds only when the template version changes and the laptop is on AC. If CachyOS has no patch for a new series yet, the old BORE kernel keeps running.
- **No systemd (frozen):** runit + elogind only. This rules out systemd timers, suspend-then-hibernate and systemd-cryptenroll TPM unlock; cron and battery-guard replace the first two.
- **Key bindings:** one grammar: Mod+dir focus, +Ctrl move window, +Shift send column (workspace up/down, monitor left/right), +Alt resize; H/J/K/L = arrows; focus and move cross into the next workspace/monitor at the edge (`*-or-monitor-*`, `*-or-workspace-*`). Windows habits where they do not clash (Super+V clipboard, Super+. emoji, Ctrl+Shift+Esc, Alt+Tab); screenshots only on PrtSc: PrtSc whole screen, Shift region, Alt window, Ctrl annotate. No Ctrl+Alt+key binds because IDEs use them; lock moved to Super+Esc so Super+Alt+L can resize. All 140 binds checked against the niri 26.04 action list and for duplicates.
- **Fonts:** Void packages plus JetBrains Mono and Cascadia Code from their GitHub releases, which Void doesn't package. All are OFL/Apache, the same files install on Windows.

- **Printer autodetection:** network printers are found with avahi (mDNS, allowed through the firewall from the LAN) and get a CUPS queue from cups-browsed. Void's cups-browsed defaults to `CreateIPPPrinterQueues LocalOnly`, which only covers USB, so setup.sh appends `All`. USB printers: ipp-usb runs constantly (Void's README says udev-only start is unreliable at boot), and system-config-printer-udev adds classic USB printers when they're plugged in.
- **Audio:** PipeWire mixes every app; pavucontrol (Mod+A) handles per-app volume and output, qpwgraph handles routing. Void ships bluetooth audio separately as `libspa-bluetooth`; without it headphones pair but never show up as an output.

## Dead ends
- `power-profiles-daemon`: replaced by TLP on request; the two conflict.
- suspend-then-hibernate on lid close: elogind only offers `suspend`/`ignore` for `HandleLidSwitch`.
- Chromium password store auto-detection: on niri it falls back to "basic" (unencrypted); the Helium wrapper forces `gnome-libsecret`.
- Noctalia from the release tarball: the release assets are source, and the docs only describe building from git.
- `hunspell-pl_PL`, `font-jetbrains-mono`, `adw-gtk3`, `mission-center`, `rustdesk` don't exist in the Void repos (checked 2026-10-14).

## Known gotchas
- grub runs PBKDF2 several times slower than the kernel, so the unlock wait scales with `LUKS_ITER_MS` (cryptsetup default 2000 ms = 10-30 s at grub, worse in a VM). Default here is 500 ms, which needs a long passphrase. The keyfile slot uses the minimum 1000 iterations (random 2 KiB key, stretching adds nothing). Existing disks: `cryptsetup luksChangeKey --iter-time 500 /dev/sda2` (type the same passphrase twice).
- Booting a snapshot from grub gives a read-only `/`. Use it to inspect, then `snapper-rollback N` + reboot.
- The GitHub API allows 60 unauthenticated requests per hour; `setup.sh apps` uses about 5.
- `nft -c` validates the ruleset at setup time; after hand edits run `sudo nft -c -f /etc/nftables.conf` before restarting.
- Dotfiles are copied only when missing. `refresh.sh` (or `setup.sh dotfiles`) replaces changed ones with the repo version and backs the old ones up to `~/.backup/<name> <date>`; Noctalia re-adds its colour includes to niri/foot on restart.
- VMs: firmware must be UEFI (VirtualBox: System > Enable EFI; Hyper-V: Generation 2 with Secure Boot off; virt-manager: choose UEFI before creating the VM, it can't be changed later) and 3D acceleration on, or niri has no GPU to render with.
- install.sh refuses any disk with a mounted partition, so it can't wipe the system it runs on; it must run from the live ISO.
- `exec > >(tee ...)` is asynchronous: without the EXIT trap that closes stdout and waits for tee, messages show up after the shell prompt.
- Antigravity CLI needs AES-NI: in a VM pass the host CPU through, or `agy` dies with an illegal instruction.
- Noctalia template ids that are not listed in `builtin_ids` are not applied: an empty list means none, not all.
- Dual boot clock: Windows keeps the RTC in local time; set `RealTimeIsUniversal=1` in Windows so both use UTC (Void keeps `HARDWARECLOCK=UTC`).
- X1 disk on 2026-10-14: p1 EFI 260 MB, p2 MSR, p3 C: 378.7 GB, 97.1 GB unallocated, p4 Recovery 0.9 GB at the end. Void becomes p5 inside the gap (partition numbers do not follow disk order).
- GRUB_TOP_LEVEL names the exact BORE vmlinuz; `setup.sh kernel` rewrites it after every build. If that kernel is removed by hand, clear the line before running grub-mkconfig.
- Check BORE after reboot: `uname -r` ends in `-bore`, `sysctl kernel.sched_bore` = 1.
- Void's unzip: `*` does not match across folders, so `unzip zip '*.ttf'` finds nothing in zips with subfolders; unpack fully and `find`.
- AppArmor on Void has no /etc/default/apparmor: `apparmor=1 security=apparmor` on the kernel line is all, enforce is the default.
- snapper `TIMELINE_CREATE=yes` makes snapper call `systemctl enable snapper-timeline.timer`; keep it `no`, snapper-tick creates the snapshots.
- Building Noctalia with `just build` runs one C++ job per thread at ~0.5-0.7 GB each and got OOM-killed in a VM. setup.sh compiles with `meson compile -j N` (N = MemAvailable / 1.5 GB, also used for LTO and the kernel build), and the swapfile is switched on during the install and in resume.sh.
- `sv` commands do nothing inside the chroot; services are enabled by symlinks in `/etc/runit/runsvdir/default`.

## Current functionality
install.sh: disk wipe + LUKS1 + btrfs subvolumes + bootstrap + fstab + keyfile + grub, then setup.sh in a chroot.
setup.sh steps: base (host, tz, locale, console), packages, user (groups, sudo, fingerprint for sudo), security, snapper, login, desktop (services, audio, TLP, fonts, dconf theme, dotfiles), apps (Helium, Floorp, Resilio, pCloud installer, fonts, cursor, Noctalia), devtools (rustup, Claude Code, agy, omp), kernel (BORE build, cron-driven), finish (initramfs + grub).

## Changelog
- 2026-10-14: first version.
- 2026-10-14: install.sh refuses disks with mounted partitions; log output flushed before exit; clearer UEFI error (first VM test).
- 2026-10-14: disk picker lists only usable disks; zswap disabled (swap = plain swapfile only).
- 2026-10-14: bluetooth audio (libspa-bluetooth: SBC/AAC/aptX/LDAC/LC3, wireplumber-elogind, blueman, battery levels, btusb kept out of TLP autosuspend); printers: network IPP queues auto-created (cups-browsed `CreateIPPPrinterQueues All`), ipp-usb service enabled, USB printers auto-added (system-config-printer-udev), user in lpadmin; qpwgraph + Mod+A mixer.
- 2026-10-14: review fixes: Helium uses libsecret + VA-API; keyring registered on the session bus; /btrfsroot no longer mounted; auto-updates + update notices; earlyoom, udiskie, smartd, monthly scrub, updatedb pruning, snapper FREE_LIMIT; hibernation + battery-guard; turbo boost on battery; alsa-ucm-conf; default apps; keepassxc, restic, rclone; cliphist removed. Minimal look with one Noctalia palette (Kanagawa) everywhere, Bibata cursor, Great Wave wallpaper, starship prompt. Dev tools: rustup, Claude Code, Antigravity CLI, oh-my-pi.
- 2026-10-14: faster boot: LUKS_ITER_MS=500 for the passphrase slot, minimum iterations for the keyfile slot, GRUB_TIMEOUT=2.
- 2026-10-14: dual boot: install mode `free` (new partition in unallocated space, shared EFI partition, os-prober); X1 checked ready (97.1 GB free, Secure Boot/BitLocker/Fast Startup off).
- 2026-10-14: BORE scheduler kernel built from Void's template + CachyOS patch (step `kernel`, cron on AC); no-systemd recorded as a frozen decision.
- 2026-10-15: first full VM run reached the apps step: fixed font unzip, AppArmor (no config file on Void), snapper TIMELINE_CREATE=no (no systemctl calls); added resume.sh to continue a half-finished install.
- 2026-10-15: Noctalia build OOM in the VM: memory-sized job count, swap on during install/resume.
- 2026-10-15: bar moved to the left edge (vertical), launcher button on the bar, Super+D as second launcher key (Super+Space is taken by Windows hosts).
- 2026-10-15: refresh.sh + setup.sh step `dotfiles` to take repo dotfiles on a running system without copy-pasting commands.
- 2026-10-15: full key binding suite (140 binds, one grammar), floating scratch terminal, task manager, clipboard/emoji/power menu/DND/night light/caffeine keys; lock is now Super+Esc.
- 2026-10-15: screenshots only on PrtSc (Shift+PrtSc = annotate); dropped Super+Shift+S and Super+Ctrl+S.
- 2026-10-15: Firefox + Opera (Void nonfree) added; PrtSc = whole screen, Shift+PrtSc = region, Ctrl+PrtSc = annotate; refresh.sh also installs new packages.
- 2026-10-15: sqlite, lazygit, typst, tinymist added.
