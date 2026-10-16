# enter_void - design

## Requirements
- Void Linux workstation on a ThinkPad X1 Carbon Gen 10 (21CC, i5-1250P, Iris Xe, 16 GB, 512 GB NVMe, 14" 1920x1200 panel (LEN403A), external Dell G3223Q 32" 4K on HDMI, AX211, SOF audio, Synaptics 06cb:00fc fingerprint, USB4).
- Reproducible from a GitHub repo: one script from the live ISO, re-runnable setup afterwards.
- btrfs + snapper, snapshots every 15 min; caches, temp files, logs, swap and the snapshots themselves excluded.
- Wayland only: niri + Noctalia, KDE Plasma 6 as a second session chosen at login, configured to look like the niri one (panel on the left). Helium + Floorp. LibreOffice. Wifi printers + scanners. Fingerprint login for sudo and the lock screen.
- Resilio Sync and pCloud installed but started by hand.
- Hardened against network attacks. sudo password at most once per day. TLP for battery.
- Host `x1-void`, user Marek, Polish programmer's keyboard, Europe/Warsaw. Open-licence fonts usable on Windows too.

## Non-goals
- Flatpak, snap, AppImage runtime. Secure Boot (not decided yet).
- X11 sessions (X apps run through xwayland-satellite). musl. Other laptops (works, but hardware bits target the X1).
- Automatic off-machine backups: restic + rclone are installed, but the target (pCloud, external disk) is not decided yet.

## Decisions (ADR)
- **Disk layout (frozen after install):** EFI partition at `/boot/efi` (1 GiB new, or Windows' shared one), 1 GiB ext4 `/boot` (not encrypted), the rest btrfs (inside LUKS2 only with `ENCRYPT=yes`, off by default since 2026-10-15) with flat subvolumes `@ @home @snapshots @var_log @var_cache @var_tmp @swap`, top level mounted at `/btrfsroot` only by snapper-rollback (`dev=` in its config). Changing it means reinstalling.
- **Install modes:** `free` (X1, dual boot) creates one partition in the largest unallocated area (>= `MIN_FREE_GIB`) with `sfdisk --append`, 1 MiB aligned, and shares the existing EFI partition without formatting it; grub goes to `EFI\Void`, `--removable` is not used so `EFI\Boot\bootx64.efi` (Windows fallback) stays. `GRUB_DISABLE_OS_PROBER=false` + os-prober put Windows Boot Manager in the menu. `wipe` (VM, blank disk) creates a fresh GPT with a 1 GiB EFI partition. Only disks with nothing mounted are offered in either mode.
- **Swap:** a plain swapfile `/swap/swapfile` (`btrfs filesystem mkswapfile`, size `SWAP_GIB`), no swap partition, no zram, and `zswap.enabled=0` on the kernel command line so the kernel does no RAM compression. The file sits in its own `@swap` subvolume because btrfs can't snapshot a subvolume holding an active swapfile.
- **LUKS2 + plain /boot (since 2026-10-15; replaces LUKS1 + /boot inside the encrypted root):** grub no longer unlocks anything, so the 10-30 s PBKDF2 wait at grub is gone; the initramfs asks once and argon2id unlocks in ~2 s (`LUKS_ITER_MS=2000`). Stronger KDF, no keyfile anywhere. Costs: kernel + initramfs are readable on disk (tampering needs physical access; Secure Boot would close that), and root snapshots no longer contain the kernel. Void keeps old kernels in /boot and /usr/lib/modules until `vkpurge`, so an older snapshot still finds its kernel: purge only kernels older than your oldest snapshot. A separate /boot is used instead of the ESP because Windows' 260 MB EFI partition is too small for 2-3 kernels with initramfs.
- **Snapshots:** snapper has no timer on Void (no systemd, and the package ships no cron script). `/usr/local/bin/snapper-tick` runs from `/etc/cron.d` every 15 min: creates a timeline snapshot per config, then cleans up. `TIMELINE_MIN_AGE=3600` keeps the last hour at 15-min resolution, then hourly 24 / daily 7 / weekly 4 / monthly 3. Exclusion = separate subvolume (btrfs snapshots stop at subvolume boundaries); home exclusions are in `HOME_NOSNAP`.
- **Root snapshots on `@snapshots`, not nested `/.snapshots`:** needed by `snapper-rollback`, which swaps `@` for a snapshot. Home uses snapper's default nested `/home/.snapshots`.
- **grub-btrfs without its daemon:** a daemon would rerun grub-mkconfig every 15 minutes. snapper-tick refreshes the menu once an hour.
- **Login:** greetd + tuigreet on vt7; `/usr/local/bin/niri-void-session` runs `dbus-run-session niri --session` because `niri-session` needs systemd. pipewire is started by niri.
- **Noctalia v5** is a native C++ app, no longer Quickshell-based, and not packaged in Void. It is built from the latest release tag with the deps listed in its BUILDING.md (all in Void), and installed to `/usr/local`. Password checks use the PAM `login` service; the fingerprint goes through fprintd D-Bus (`[lockscreen] fingerprint = true`).
- **Browsers/Resilio:** upstream tarballs into `/opt/<name>` (atomic swap, `.version` stamp). `setup.sh apps` updates them. HTTPS from the vendor/GitHub is the trust root; signatures are not checked (Helium ships `.asc`, but no pinned key here).
- **RustDesk:** not in Void; upstream ships no tarball, but its Arch package is a plain `.tar.zst`. `usr/share/rustdesk` is unpacked to the same path (opt_install folder argument), runtime libs from xbps (`libayatana-appindicator` replaces Arch's libappindicator). Its systemd service file is ignored: started by hand.
- **KDE Connect:** started by niri (`kdeconnect-indicator`, since niri runs no XDG autostart); firewall opens 1714-1764 tcp/udp to private IPv4 ranges only.
- **pCloud via rclone (default):** `cloud` wraps rclone 1.75: OAuth remote `pcloud:` (region set during login), `rclone mount` with full VFS cache at ~/pCloud on demand, `rclone bisync --resilient --recover --conflict-resolve newer --max-delete 25` for the folder pairs in ~/.config/cloud-sync.conf (first run per pair uses --resync, tracked in ~/.local/state/cloud), `rclone link` for share links. Nothing runs in the background; schedule with `crontab -e` if wanted. LibreOffice lock files and temp files are excluded.
- **pCloud app (optional):** the only Linux build is an AppImage behind a per-session link, so it cannot be scripted. `pcloud-install` unpacks it into `/opt/pcloud` (no FUSE2 runtime needed to start it; `fuse`/`fuse3` are installed for its virtual drive).
- **X1 speakers:** EasyEffects 8 (`--service-mode --hide-window`, started by niri) with a preset made by speaker-tuning-to-easyeffects (MIT) from Lenovo's own Dolby tuning for this machine (`DEV_0287_SUBSYS_17AA22E7_*.xml` in the Windows DriverStore). `setup.sh speakers` mounts the Windows partition read-only, converts, sets autoload for the internal speakers; the proprietary file never enters the repo. Runs on the live desktop only (needs PipeWire); no Windows partition -> skipped.
- **Power profiles (TLP 1.10):** AC -> balanced (`_ON_BAT` values: balance_performance, platform balanced, boost on), battery -> power-saver (`_ON_SAV`: EPP power, platform low-power, no boost, CPU max 60 %, GPU boost 900 MHz, ASPM powersupersave), performance (`_ON_AC`) only by hand. Settings without `_SAV` variants use `_ON_BAT` in power-saver, so those are set to saving.
- **Power:** TLP + tlp-pd (TLP's power-profiles D-Bus API, so Noctalia's profile switch works). It conflicts with power-profiles-daemon. thermald stays.
- **Firewall:** nftables, inbound default drop; allowed: established, loopback, rate-limited ICMP, DHCPv6, mDNS from LAN (printer/scanner discovery), Resilio port 55555 and LAN discovery 3838. No sshd. Resilio WebUI only on 127.0.0.1, UPnP off.
- **Hardening:** sysctl (kptr/dmesg restrict, no unprivileged BPF, ptrace scope 1, no redirects/source routes, rp_filter loose), AppArmor enforce, no core dumps, root account locked, NetworkManager random MAC for scans and a stable random MAC per network, IPv6 privacy addresses.
- **sudo:** `timestamp_timeout=1440` + `timestamp_type=global`, so one password per day across all terminals (reset on reboot). pam_fprintd is `sufficient` in `/etc/pam.d/sudo`. Login stays password-only so gnome-keyring unlocks.
- **User name:** `marek` login with full name "Marek". shadow's useradd rejects capitals by default.
- **Locale:** English UI, Polish formats (LC_TIME, LC_PAPER=A4, ...). LC_NUMERIC stays English, because a decimal comma breaks scripts.
- **Look (minimal):** Noctalia owns the palette (builtin Kanagawa) and pushes it through its builtin templates to niri (`include "noctalia.kdl"`), foot, GTK 3/4, qt5ct/qt6ct, KDE colour scheme, btop and starship, so there is one colour scheme everywhere and switching it in Settings restyles everything. Dotfiles therefore hold layout only, no colours (niri keeps fallback colours). One vertical capsule bar on the left (no top/bottom bar) with launcher + 7 widgets, 2 px single-colour focus ring, no borders, soft shadow, 12 px corners, Inter + JetBrains Mono, Bibata cursor (GitHub release, Void has no package), Hokusai wallpaper (public domain, Wikimedia).
- **Upkeep (cron, root-owned copy in /usr/local/lib/enter_void):** `xbps-install -S` every 6 h; `setup.sh apps` once a day when `power-ok 80` (on AC and battery > 80 %, so you can unplug and go at any time; hourly cron checks it and `/var/lib/enter_void/apps.stamp`, so a laptop that was off still catches up; an app in use is skipped, so a running browser is never swapped out), monthly `btrfs scrub`, daily `updatedb`, `battery-guard` every 2 min. The desktop gets update notices from `update-notify`. Cron never runs a script the user can edit.
- **Hibernation:** into the swapfile (`resume=` + `resume_offset=` from `btrfs inspect-internal map-swapfile`, dracut `resume` module). elogind has no suspend-then-hibernate, so `battery-guard` hibernates at 5 % while discharging; it cannot run during suspend.
- **Dev tools:** Go from xbps, Rust through rustup (`~/.cargo`), Claude Code / Antigravity CLI / oh-my-pi through their official checksum-verifying installers into `~/.local/bin`, run as the user. Each updates itself. A failed installer only warns.
- **BORE scheduler:** no Void package and no prebuilt runit-friendly kernel exists, so `setup.sh kernel` clones void-packages into `/var/cache/void-packages` (never snapshotted), copies the stock `linux<series>` template to `linux<series>-bore` (own pkgname, `-bore` in `_kernver` and `CONFIG_LOCALVERSION` so /boot and /usr/lib/modules never collide), adds CachyOS's standalone `<series>/sched/0001-bore.patch`, and `x86_64-dotconfig-custom` = Void config + `CONFIG_SCHED_BORE=y`, `CONFIG_MIN_BASE_SLICE_NS=2000000` (the only options the patch adds, so `make oldconfig` never prompts). Built as the user with xbps-src, installed from the local repo, made default with `GRUB_TOP_LEVEL`. Stock kernel stays installed as the fallback. Not built in the install chroot (an hour of compiling); cron checks every 6 h and rebuilds only when the template version changes and the laptop is on AC. If CachyOS has no patch for a new series yet, the old BORE kernel keeps running.
- **No systemd (frozen):** runit + elogind only. This rules out systemd timers, suspend-then-hibernate and systemd-cryptenroll TPM unlock; cron and battery-guard replace the first two.
- **Key bindings:** one grammar: Mod+dir focus, +Ctrl move window, +Shift send column (workspace up/down, monitor left/right), +Alt resize; H/J/K/L = arrows; focus and move cross into the next workspace/monitor at the edge (`*-or-monitor-*`, `*-or-workspace-*`). Windows habits where they do not clash (Super+V clipboard, Super+. emoji, Ctrl+Shift+Esc, Alt+Tab); screenshots only on PrtSc: PrtSc whole screen, Shift region, Alt window, Ctrl annotate. No Ctrl+Alt+key binds because IDEs use them; lock moved to Super+Esc so Super+Alt+L can resize. All 140 binds checked against the niri 26.04 action list and for duplicates.
- **Fonts:** Void packages plus JetBrains Mono and Cascadia Code from their GitHub releases, which Void doesn't package. All are OFL/Apache, the same files install on Windows.
- **Wifi on the first boot:** the AX211 needs `iwlwifi` + `linux-firmware-network`, which `linux-base` (pulled by the kernel) depends on, on the live ISO and on the installed system alike; if the live ISO is online over wifi, so is the install. install.sh turns every WPA-PSK network in the live session's `/etc/wpa.conf` / `/etc/wpa_supplicant/*.conf` into a NetworkManager keyfile (`/etc/NetworkManager/system-connections`, 600), so no password is typed again. `linux-firmware-intel` (i915 GuC/HuC/DMC) is listed explicitly: `linux-firmware` does not depend on it.
- **Second session, KDE Plasma 6:** `kde-plasma` from xbps. `plasma-void-session` = `dbus-run-session startplasma-wayland` (Plasma's own plasma.desktop has no session bus without systemd). tuigreet lists only `/usr/local/share/wayland-sessions` (F3, `--remember-session`); `/usr/share`'s niri.desktop needs systemd and X11 is out of scope. Look: a look-and-feel package `org.enter_void.desktop` (dotfile) holds only the layout script (one 40 px left panel: kickoff, pager, icon tasks, tray, clock; wallpaper); Plasma runs it on the first start without a layout, the rest falls back to Breeze. Settings (fonts, icons, cursor, keyboard, no borders, animations off, 4 desktops, KWallet off, shortcuts) are not dotfiles but `plasma-void-config`: kwriteconfig6 merges only its own keys, run by plasma-void-session before Plasma starts, once per `VERSION` (stamp in ~/.local/state/enter_void), so System Settings changes survive. Whole-file dotfiles were tried first (see dead ends). Colours: `plasma-noctalia-colors` (autostart) applies Noctalia's `noctalia.colors` when it changed. Keyring: KWallet off, gnome-keyring secrets started by autostart, so both sessions share one store. Plasma needs XDG autostart for what niri spawns itself (pipewire, keyring, EasyEffects, update-notify); those entries are `OnlyShowIn=KDE` so nothing in niri starts them twice. Shortcuts mirror the main niri keys; Plasma defaults on the same keys (Meta+Q activities, Meta+D peek, Meta+1..4 task entries) are set to none.

- **Screens:** native modes set explicitly. niri: `eDP-1` 1920x1200 at `DISPLAY_SCALE` (1.25), the Dell matched by make/model/serial (`Dell Inc. DELL G3223Q 5CM14P3`, so any port) at 3840x2160, `DISPLAY_SCALE_4K` (1.5 = Windows' setting). Values read on the X1 in Windows (WmiMonitorID / preferred source mode / GetDpiForMonitor, 2026-10-16); the repo said 2560x1440 before, which this X1 does not have. Plasma: `plasma-displays` (autostart) sets every connected output to its preferred (native) mode via `kscreen-doctor`, eDP at 1.25, outputs with a 3840-wide mode at 1.5, others 1; once per connector name (stamp), so System Settings wins afterwards. kscreen-doctor's JSON has no model field, so Plasma goes by connector + size, not by the Dell's name.

- **Key cheat-sheet wallpapers:** typst (already installed for documents) renders `files/wallpaper/keys-{niri,plasma}.typ` (shared `keys-style.typ`) to 3840x2400 PNGs in ~/Pictures/Wallpapers during the desktop and dotfiles steps, so they follow the repo and refresh.sh. One 16:10 image per desktop, not one per screen: Noctalia only offers per-monitor *folders*, and Plasma's crop fill does the same job. 3840x2400 = the X1 panel x2 (sharp after downscaling) and the Dell's width; on 16:9 the crop takes ~5 % off top and bottom, which the page margins absorb, and the left margin clears the bar/panel. Each sheet sets its own text size and column count to fill the page; a second page = text too big. The sheets are hand-kept in sync with the binds (niri config.kdl, plasma-void-config). Previewed on Windows with portable typst 0.15.1 + Inter 4.1 before committing.
- **Tailscale:** Void packages it (1.104.1) with a runit service `tailscaled`; enabled in the security step, idle until `tailscale up`. nftables accepts everything on `tailscale0` (only your tailnet, governed by its ACLs) and UDP 41641 (WireGuard, for direct peer links instead of DERP relays). `flush ruleset` in nftables.conf also removes the rules tailscaled adds for itself; the accept on tailscale0 makes them unnecessary for normal use (exit node / subnet routes would need its NAT rules: restart tailscaled after restarting nftables).

- **Printer autodetection:** network printers are found with avahi (mDNS, allowed through the firewall from the LAN) and get a CUPS queue from cups-browsed. Void's cups-browsed defaults to `CreateIPPPrinterQueues LocalOnly`, which only covers USB, so setup.sh appends `All`. USB printers: ipp-usb runs constantly (Void's README says udev-only start is unreliable at boot), and system-config-printer-udev adds classic USB printers when they're plugged in.
- **Audio:** PipeWire mixes every app; pavucontrol (Mod+A) handles per-app volume and output, qpwgraph handles routing. Void ships bluetooth audio separately as `libspa-bluetooth`; without it headphones pair but never show up as an output.

## Dead ends
- `power-profiles-daemon`: replaced by TLP on request; the two conflict.
- suspend-then-hibernate on lid close: elogind only offers `suspend`/`ignore` for `HandleLidSwitch`.
- Chromium password store auto-detection: on niri it falls back to "basic" (unencrypted); the Helium wrapper forces `gnome-libsecret`.
- Noctalia from the release tarball: the release assets are source, and the docs only describe building from git.
- Plasma settings as whole-file dotfiles (kdeglobals, kwinrc, kglobalshortcutsrc, ...): kdeglobals already exists under niri (written by KDE apps / Noctalia's KDE template), so refresh.sh replaced it and wiped those keys (VM, 2026-10-16); Plasma also rewrites these files itself, so every refresh would have reverted System Settings. Replaced by plasma-void-config (key merge).
- `hunspell-pl_PL`, `font-jetbrains-mono`, `adw-gtk3`, `mission-center`, `rustdesk` don't exist in the Void repos (checked 2026-10-14).

## Known gotchas
- Installs from before 2026-10-15 (LUKS1, /boot encrypted, keyfile in the initramfs) keep working and keep the grub wait; switching layouts needs a reinstall. On those, `cryptsetup luksChangeKey --iter-time 500 /dev/sda2` shortens the wait.
- Booting a snapshot from grub gives a read-only `/`. Use it to inspect, then `snapper-rollback N` + reboot.
- The GitHub API allows 60 unauthenticated requests per hour; `setup.sh apps` uses about 5.
- `nft -c` validates the ruleset at setup time; after hand edits run `sudo nft -c -f /etc/nftables.conf` before restarting.
- Dotfiles are copied only when missing. `refresh.sh` (or `setup.sh dotfiles`) replaces changed ones with the repo version and backs the old ones up to `~/.backup/<name> <date>`; Noctalia re-adds its colour includes to niri/foot on restart.
- VMs: firmware must be UEFI (VirtualBox: System > Enable EFI; Hyper-V: Generation 2 with Secure Boot off; virt-manager: choose UEFI before creating the VM, it can't be changed later) and 3D acceleration on, or niri has no GPU to render with.
- install.sh refuses any disk with a mounted partition, so it can't wipe the system it runs on; it must run from the live ISO.
- `exec > >(tee ...)` is asynchronous: without the EXIT trap that closes stdout and waits for tee, messages show up after the shell prompt.
- refresh.sh run from a root shell kills your Noctalia and starts one for root, which can't attach to your session: no bar, no launcher. It now refuses to run as root.
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
- At shutdown elogind revokes the seat before runit stops niri, so niri logs DRM "page flip ... permission denied" warnings until it is killed. Harmless; niri-void-session sends niri's log to ~/.local/state/niri/<date>-niri.log (14 days kept) so it no longer shows on the console.
- thermald needs Intel thermal zones; without them (VM) it exits and runit restarts it every 2 s, flooding socklog. setup.sh enables it only on Intel hardware with /sys/class/thermal/thermal_zone* and not under VMware.
- Noctalia Greeter in VMware: its wlroots compositor fails to import the client's dmabuf on vmwgfx (`wlr_linux_dmabuf_v1: Failed to close buffer handle ... Invalid argument`, client disconnected, blank screen). Under VMware greetd runs it with `WLR_RENDERER=pixman LIBGL_ALWAYS_SOFTWARE=1`. Debug: put `env NOCTALIA_GREETER_LOG=/tmp/greeter.log WLR_LOG=debug` in front of the greetd command.
- Plasma settings changed in `plasma-void-config` reach an existing install only after bumping its `VERSION`; then every key it lists is written again at the next Plasma login (System Settings changes to those keys are overwritten, others kept). The panel layout lives in plasma-org.kde.plasma.desktop-appletsrc, which nothing in the repo writes.
- `pkill noctalia` returns before Noctalia has exited; starting the new one right away fails with "noctalia is already running" and leaves no bar. refresh.sh waits up to 5 s (then SIGKILL) before starting it.
- `refresh.sh undo` scope: home in full (between the run's pre/post snapshots), but on / only `/usr/local` and `/etc/greetd`. Undoing more of / under newer packages is unsafe: /boot is outside the snapshots, so reverting /usr/lib/modules after a kernel update leaves grub's newest kernel without its modules. Whole-system undo = boot the pre snapshot + snapper-rollback (README). Undo runs from a /tmp copy because it rewrites refresh.sh itself. The run list is `~/.local/state/enter_void/refresh-snapshots` (written after the post snapshot, so undo never reverts it); each undo drops the last line.
- refresh.sh is not VM-only: it is the way to apply repo changes to any running install. Normal updates (xu, cron) never need it.
- BitLocker and the speakers step: suspending BitLocker only stores the key in clear, the volume stays encrypted (lsblk shows `BitLocker`, not `ntfs`), so `setup.sh speakers` finds no Windows partition and skips. It works only on an unencrypted C:; there is no dislocker step.
- Java/Swing apps (IBKR TWS, Ghidra) are blank under xwayland-satellite unless `_JAVA_AWT_WM_NONREPARENTING=1` (niri's Application Issues page); set in niri's environment block, harmless for other apps. TWS is IBKR's install4j installer with a bundled JRE, installed per user into ~/Jts and self-updating, so it is not scripted here. Under fractional scale 1.25 X11 apps may look soft (not checked); TWS has its own font size setting.
- Unverified Plasma assumptions (checked from memory, not on a machine): a look-and-feel package with only `contents/layouts` falls back to Breeze for the rest; `panel.floating` exists in the Plasma 6 scripting API (if not, the panel floats, set it in panel settings); Noctalia's kcolorscheme template writes `~/.local/share/color-schemes/noctalia.colors` (inferred from qt6ct listing "noctalia (KColorScheme)").
- Plasma under refresh.sh: Noctalia is restarted only when `XDG_CURRENT_DESKTOP=niri`, otherwise it would draw a second bar inside Plasma.
- Plasma display scale and touchpad (tap-to-click, natural scrolling) are not preset: KDE keys them by output/device name. Set them once in System Settings.
- Plasma's powerdevil switches TLP profiles through tlp-pd (same D-Bus API as power-profiles-daemon); its own idle defaults (dim, screen off, suspend) apply in Plasma, Noctalia's in niri.
- `sv` commands do nothing inside the chroot; services are enabled by symlinks in `/etc/runit/runsvdir/default`.

## To do later

Open items from the 2026-10-14/15 sessions. Tick them off here when done.

**Before / during the X1 install**
- [ ] Windows (admin): run the reclaim script with `SetBIOSTimeUTC`, or the one `reg add ... RealTimeIsUniversal` line (README).
- [ ] Back up the laptop. install.sh mode `free` is untested on real hardware: rehearse it in the VM first (README: fake the X1 layout with sfdisk).
- [ ] Use a long passphrase (4-5 random words).

**After the first boot on the X1**
- [ ] Speakers: `sudo ~/enter_void/setup.sh speakers` (if it did not run), then compare with EasyEffects bypassed; `python3 /var/cache/speaker-tuning/dolby_to_easyeffects.py --doctor` if it sounds unchanged.
- [ ] `fprintd-enroll`, then check fingerprint on sudo and the lock screen.
- [ ] `fwupdmgr refresh && fwupdmgr update` (BIOS, fingerprint reader firmware).
- [ ] BORE kernel: let cron build it on AC (~45-90 min, estimate), then `uname -r` ends in `-bore` and `sysctl kernel.sched_bore` = 1.
- [ ] Wi-Fi printer: `lpstat -v` shows a queue, simple-scan finds the scanner. No queue? Find its `.local` name with `avahi-browse -rt _ipp._tcp`, then `sudo lpadmin -p Printer -E -v ipp://<name>.local/ipp/print -m everywhere`
- [ ] `cloud setup`, list folders in `~/.config/cloud-sync.conf`, `cloud sync -n` then `cloud sync`.
- [ ] KDE Connect: pair the phone. If no tray icon, check the binary name (`ls /usr/bin | grep kdeconnect`) and fix `spawn-at-startup` in niri config.
- [ ] RustDesk: check outgoing sessions; incoming control on Wayland may be limited.
- [ ] Hibernation: `loginctl hibernate` once, confirm it resumes (resume offset from the swapfile).
- [ ] Decide on Polish vs English formats (currently Polish formats, English language).

**Decisions still open (from the gap review)**
- [ ] Graphical login: Noctalia Greeter is built in but OFF (`GREETER=tuigreet`): blank screen in VMware even with software rendering. Retry on the X1 (real Intel GPU) with `GREETER=noctalia` + `sudo ~/enter_void/setup.sh login`. Still open: themed/hidden grub menu.
- [x] Screen recording: Noctalia Screen Recorder + gpu-screen-recorder (2026-10-15); annotation is Ctrl+PrtSc.
- [ ] VPN plugins: `NetworkManager-openvpn`, `NetworkManager-openconnect`.
- [x] Faster unlock: LUKS2 + plain /boot (2026-10-15) - needs a reinstall to take effect.
- [ ] Secure Boot with `sbctl` (own keys, sign grub + kernel).
- [ ] Off-machine backups: target for restic (pCloud via rclone or an external disk) + schedule.
- [ ] Tools offered but not added: `nodejs` + `mise`, `qemu`/`libvirt`/`virt-manager` (+ libvirtd service), PowerShell 7 (tarball), the rest of the dev list (git: delta/difftastic/git-absorb/tig, debug: gdb/lldb/valgrind/perf/hotspot, LSPs: clangd/gopls/ruff, shell: atuin/direnv/hyperfine/xh/yazi/...).

- [ ] Plasma (untested, 2026-10-16): F3 lists both sessions; left panel on first login; sound, keyring (Helium passwords), Super+Q/D/Return; `noctalia.colors` path matches what Noctalia writes.
- [ ] IBKR TWS: install, log in (IBKR Mobile 2FA), check that windows are not blank and dialogs open usable in niri and Plasma.
- [ ] Is C: BitLocker-encrypted on the X1? If yes, the speakers step cannot read the Dolby tuning (see gotchas).
- [ ] X1: `niri msg outputs` shows `Dell Inc. DELL G3223Q 5CM14P3` (else fix the output name in niri config) and both screens at native mode; in Plasma `kscreen-doctor -o` shows the same.
- [ ] VM: `refresh.sh` then `refresh.sh undo` - a changed dotfile comes back, `snapper -c home list` shows the pair, Noctalia restarts.
- [ ] Wifi carry-over: after the first boot `nmcli connection` shows the live-session network and it connects.

**VM only**
- [ ] `KERNEL_BORE=no` in /usr/local/lib/enter_void/config.sh (an hours-long build tells nothing new).
- [ ] Bridged network adapter for printer / KDE Connect tests; more RAM/CPU for builds. (open-vm-tools is installed automatically under VMware since 2026-10-15; never run VMware's own Tools installer from the virtual CD.)

## Current functionality
install.sh: wipe or free-space mode, ESP + plain /boot + LUKS2, btrfs subvolumes, bootstrap, fstab, live-session wifi -> NetworkManager, grub, then setup.sh in a chroot.
Login (tuigreet, F3): niri + Noctalia (default) or KDE Plasma 6.
setup.sh steps: base (host, tz, locale, console), packages, user (groups, sudo, fingerprint for sudo), security, snapper, login, desktop (services, audio, TLP, fonts, dconf theme, dotfiles), apps (Helium, Floorp, Resilio, pCloud installer, fonts, cursor, Noctalia), devtools (rustup, Claude Code, agy, omp), kernel (BORE build, cron-driven), finish (initramfs + grub).

## Changelog
- 2026-10-14: first version.
- 2026-10-14: install.sh refuses disks with mounted partitions; log output flushed before exit; clearer UEFI error (first VM test).
- 2026-10-14: disk picker lists only usable disks; zswap disabled (swap = plain swapfile only).
- 2026-10-14: bluetooth audio (libspa-bluetooth: SBC/AAC/aptX/LDAC/LC3, wireplumber-elogind, blueman, battery levels, btusb kept out of TLP autosuspend); printers: network IPP queues auto-created (cups-browsed `CreateIPPPrinterQueues All`), ipp-usb service enabled, USB printers auto-added (system-config-printer-udev), user in lpadmin; qpwgraph + Mod+A mixer.
- 2026-10-14: review fixes: Helium uses libsecret + VA-API; keyring registered on the session bus; /btrfsroot no longer mounted; auto-updates + update notices; earlyoom, udiskie, smartd, monthly scrub, updatedb pruning, snapper FREE_LIMIT; hibernation + battery-guard; turbo boost on battery; alsa-ucm-conf; default apps; keepassxc, restic, rclone; cliphist removed. Minimal look with one Noctalia palette (Kanagawa) everywhere, Bibata cursor, Great Wave wallpaper, starship prompt. Dev tools: rustup, Claude Code, Antigravity CLI, oh-my-pi.
- 2026-10-14: faster boot: LUKS_ITER_MS=500 for the passphrase slot, minimum iterations for the keyfile slot, GRUB_TIMEOUT=2.
- 2026-10-14: dual boot: install mode `free` (new partition in unallocated space, shared EFI partition, os-prober); X1 disk checked (free space between C: and Recovery).
- 2026-10-14: BORE scheduler kernel built from Void's template + CachyOS patch (step `kernel`, cron on AC); no-systemd recorded as a frozen decision.
- 2026-10-15: first full VM run reached the apps step: fixed font unzip, AppArmor (no config file on Void), snapper TIMELINE_CREATE=no (no systemctl calls); added resume.sh to continue a half-finished install.
- 2026-10-15: Noctalia build OOM in the VM: memory-sized job count, swap on during install/resume.
- 2026-10-15: bar moved to the left edge (vertical), launcher button on the bar, Super+D as second launcher key (Super+Space is taken by Windows hosts).
- 2026-10-15: refresh.sh + setup.sh step `dotfiles` to take repo dotfiles on a running system without copy-pasting commands.
- 2026-10-15: full key binding suite (140 binds, one grammar), floating scratch terminal, task manager, clipboard/emoji/power menu/DND/night light/caffeine keys; lock is now Super+Esc.
- 2026-10-15: screenshots only on PrtSc (Shift+PrtSc = annotate); dropped Super+Shift+S and Super+Ctrl+S.
- 2026-10-15: Firefox + Opera (Void nonfree) added; PrtSc = whole screen, Shift+PrtSc = region, Ctrl+PrtSc = annotate; refresh.sh also installs new packages.
- 2026-10-15: sqlite, lazygit, typst, tinymist added.
- 2026-10-15: Deno (dev tools), RustDesk, KDE Connect (+ LAN-only firewall rule, applied live), snapshot; refresh.sh now also runs security, apps and devtools.
- 2026-10-15: pCloud through rclone (`cloud` command, Thunar "Send to pCloud", launcher entry) instead of the pCloud app.
- 2026-10-15: idle lock after 60 min (screen off 1 min later); "To do later" section added.
- 2026-10-15: TLP profiles: balanced on AC, power-saver on battery, performance on demand.
- 2026-10-15: LUKS2 (argon2id) + unencrypted 1 GiB /boot instead of LUKS1 + keyfile (no grub unlock wait); Noctalia Greeter login; screen recording (Super+PrtSc).
- 2026-10-15: X1 speakers: EasyEffects + Lenovo Dolby tuning converted on the device (step `speakers`); litecli, pgcli.
- 2026-10-15: PDF and Markdown readers: sioyek, xournalpp, pdfarranger, poppler-utils, qpdf, ghostwriter (default for .md), glow.
- 2026-10-15: psmisc (fuser, killall, pstree).
- 2026-10-15: under VMware, open-vm-tools is installed and vmtoolsd + vmware-vmblock-fuse enabled automatically.
- 2026-10-15: niri log to a daily file instead of the console (shutdown DRM warnings).
- 2026-10-15: upstream apps update once a day instead of every 6 h.
- 2026-10-15: daily app updates only on AC or with battery above 50 % (power-ok).
- 2026-10-15: power-ok now means on AC AND battery above 80 % (daily app updates).
- 2026-10-15: thermald only on real Intel hardware (crash loop in the VM).
- 2026-10-15: Noctalia Greeter under VMware uses software rendering (vmwgfx dmabuf import fails in wlroots).
- 2026-10-15: back to tuigreet as the default login; Noctalia Greeter kept as an option (GREETER=noctalia).
- 2026-10-15: animations super fast: niri slowdown 0.25, Noctalia [shell.animation] speed 3.0, lock 100 ms, wallpaper 300 ms.
- 2026-10-15: animations off by default (niri `animations { off }`, Noctalia `[shell.animation] enabled = false`); lock/wallpaper fades kept at their minimum.
- 2026-10-15: bar thinner (30 px) and flush with the left edge, full height, square (`margin_edge = 0`, `margin_ends = 0`, `radius = 0`); Super+F = `maximize-window-to-edges` (no gaps/ring, only the bar stays), Super+M = old full-width column; refresh.sh warns when Settings overrides the bar.
- 2026-10-15: refresh.sh refuses to run as root (it restarted Noctalia as root: no bar, no launcher).
- 2026-10-15: SBCL (Common Lisp) added.
- 2026-10-15: Noctalia weather off (`[weather] enabled = false`).
- 2026-10-15: disk encryption off by default (`ENCRYPT=no`: no boot passphrase; a stolen disk is readable). LUKS2 path kept behind `ENCRYPT=yes`.
- 2026-10-15: bar shows app icons per workspace: `taskbar` widget with `group_by_workspace` instead of `workspaces` (app names only work on horizontal bars).
- 2026-10-15: refresh.sh restarts Noctalia only inside niri (`WAYLAND_DISPLAY` set), logs it to `~/.local/state/noctalia/<date>-noctalia.log` and reports when it fails to start (was: output to /dev/null, grey screen with no clue).
- 2026-10-15: caffeine (keep awake) removed: control center tiles = Noctalia's default set without it, Super+Ctrl+I unbound.
- 2026-10-15: Num Lock off at login (dropped `numlock` from niri's keyboard input).
- 2026-10-16: wifi from the live session copied into NetworkManager (first boot online without a cable); linux-firmware-intel listed explicitly.
- 2026-10-16: Plasma gets niri's Super+Shift+/ overlay: `plasma-keys` shows keys-plasma.png full screen in imv (same key or Esc closes), plasma-void-config VERSION 3; the cheat sheet becomes the Plasma wallpaper by autostart (`plasma-keys --wallpaper`, once per rendered image), also on Plasmas set up before it existed.
- 2026-10-16: key cheat-sheet wallpapers for niri and Plasma (typst, 3840x2400, include screen/scale commands); Plasma: Meta+Shift+D peeks at the desktop, Meta+P back to Plasma's screen switcher (KeePassXC unbound), plasma-void-config VERSION 2; spectacle for Plasma screenshots. Tailscale (package, tailscaled service, firewall accepts tailscale0 + UDP 41641).
- 2026-10-16: native screen modes: X1 panel is 1920x1200 (not 2560x1440), Dell G3223Q 4K at scale 1.5 (`DISPLAY_SCALE_4K`); niri output blocks + Plasma `plasma-displays` (kscreen-doctor, once per connector).
- 2026-10-16: refresh.sh wraps every run in snapper pre/post snapshots (root + home, number cleanup) and gets `refresh.sh undo`; README "When a refresh breaks something" (undo, single file from ~/.backup, boot snapshot + snapper-rollback).
- 2026-10-16: Plasma settings merged by plasma-void-config (kwriteconfig6, once per version) instead of whole-file dotfiles that clobbered kdeglobals; refresh.sh waits for the old Noctalia to exit before starting the new one (VM: "already running", no bar).
- 2026-10-16: niri sets `_JAVA_AWT_WM_NONREPARENTING=1` (IBKR TWS); README: wifi check on the live stick before touching the disk, TWS install, refresh.sh scope, BitLocker blocks the speakers step.
- 2026-10-16: KDE Plasma 6 as a second session (tuigreet F3), minimal look matching niri: left panel, no borders, no animations, Noctalia palette, shared keyring, niri-like shortcuts. refresh.sh restarts Noctalia only in niri.
- 2026-10-15: README install guide: ISO choice + checksum, Rufus DD mode, Windows prep (BitLocker, Fast Startup, shrink C:), BIOS, partition modes and config.sh options.
