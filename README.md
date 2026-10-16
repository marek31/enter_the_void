# enter_void

Scripts that turn a blank ThinkPad X1 Carbon Gen 10 into `x1-void`: Void Linux, btrfs + snapper every 15 min,
niri + Noctalia on Wayland (KDE Plasma as a second session), Helium, Floorp, Firefox, Opera, LibreOffice, wifi printers and scanners, Resilio Sync and pCloud.
No flatpak, no snap. All decisions are listed (and editable) in [config.sh](config.sh).

## Install

### 1. USB stick

- **Image:** `void-live-x86_64-<date>-base.iso` from <https://repo-default.voidlinux.org/live/current/>, plus `sha256sum.txt` from the same folder.
  Take **glibc** (no `musl` in the name) and **base** (not xfce): install.sh brings the desktop.
- **Check it:** Windows: `(Get-FileHash .\void-live-x86_64-*-base.iso).Hash` must match its line in `sha256sum.txt`.
  Linux: `sha256sum -c sha256sum.txt --ignore-missing`. Signature check: [Verifying images](https://docs.voidlinux.org/installation/index.html#verifying-images).
- **Write it** (erases the stick, 2 GB or more):
  Windows: [Rufus](https://rufus.ie/) > pick the ISO > Start > choose **DD Image mode** when asked.
  Linux: `dd bs=4M if=void-live-x86_64-*-base.iso of=/dev/sdX status=progress; sync`.

### 2. Before booting it: Windows (dual boot only)

Skip this when the whole disk is wiped.

0. **Wifi check first:** boot the stick once (step 3) and connect to wifi as in step 5, before changing anything on the disk.
   If the stick gets online, the installed system will too (same driver and firmware).

1. **BitLocker:** write down the recovery key (`manage-bde -protectors -get C:` in an admin PowerShell) and suspend protection
   (Control Panel > BitLocker > Suspend protection). Turning Secure Boot off otherwise makes Windows ask for that key.
2. **Fast Startup off:** Control Panel > Power Options > Choose what the power buttons do > untick "Turn on fast startup".
   Otherwise Windows leaves its partitions half-mounted.
3. **Make room:** `diskmgmt.msc` > right-click C: > Shrink Volume. Leave the space **unallocated**, don't create a volume in it.
   80-100 GiB recommended (the BORE kernel build needs ~25 GB, swap takes 16 GiB); 40 GiB is the minimum install.sh offers.
4. **Clock** (both systems then keep the RTC in UTC), admin PowerShell:
   ```powershell
   reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
   ```

### 3. BIOS and boot

- Power on, **F1** = BIOS setup: Security > Secure Boot **off** (grub and the self-built BORE kernel are not signed). UEFI stays on (the Gen 10 has no legacy mode).
- **F12** = boot menu: pick the USB stick.
- VM: UEFI firmware (VirtualBox: System > Enable EFI; Hyper-V: Generation 2, Secure Boot off) and 3D acceleration on.

### 4. Partitioning: what to pick

Don't use `void-installer` from the ISO; install.sh partitions, encrypts and installs by itself. It asks for the mode:

| Mode | When | Result |
|---|---|---|
| `free` (recommended on the X1) | Windows stays | Windows' EFI partition shared (≥16 MB free needed, nothing formatted) + new 1 GiB `/boot` (ext4) + new Void partition with the rest of the gap |
| `wipe` | blank disk, VM, Linux only | GPT: 1 GiB EFI + 1 GiB `/boot` + the rest for Void |

In both modes the Void partition is btrfs, **not encrypted** by default (boots without a passphrase):
subvolumes `@` `/`, `@home`, `@snapshots`, `@var_log`, `@var_cache`, `@var_tmp`, `@swap` (16 GiB swapfile, used for hibernation).
With `ENCRYPT=yes` the btrfs sits inside LUKS2 (argon2id, passphrase asked once at boot, ~2 s); `/boot` stays unencrypted either way.
This layout is fixed after install; changing it (encryption included) means reinstalling.

Settings worth a look in [config.sh](config.sh) before running it:

| Setting | Default | Change when |
|---|---|---|
| `INSTALL_MODE` / `DISK` | ask | you want no questions |
| `ENCRYPT` | `no` | `yes` if the laptop leaves the house: without it a stolen disk is readable by anyone |
| `SWAP_GIB` | `16` (= RAM) | less RAM; below RAM size hibernation can fail |
| `BOOT_MIB` | `1024` | keep: 3-4 kernels + initramfs fit |
| `LUKS_ITER_MS` | `2000` | lower = faster unlock, weaker against passphrase guessing |

### 5. Run the installer

Log in as `root` / `voidlinux` and get online. USB ethernet just works. For wifi, find the interface with `ip link` (AX211 is usually `wlp0s20f3`), then
`wpa_passphrase SSID PASS > /etc/wpa.conf; wpa_supplicant -B -i wlp0s20f3 -c /etc/wpa.conf; dhcpcd wlp0s20f3`.
The live ISO already has the AX211 driver and firmware (`linux-firmware-network`, pulled in by the kernel), so no cable is needed.
install.sh copies this network (WPA-PSK) into NetworkManager, so the installed system connects by itself at the first boot.
No wifi on the stick? A phone with USB tethering on the USB-C port works without drivers. Then:

```sh
xbps-install -Sy xbps git
git clone https://github.com/marek31/enter_void
cd enter_void
vi config.sh          # optional: disk, swap size, scale, ...
./install.sh          # asks the mode (free/wipe) and the user password (+ disk passphrase with ENCRYPT=yes)
```

Remove the stick and reboot: grub menu, then the text login (tuigreet). With `ENCRYPT=yes` the passphrase is asked once before it (about 2 s to unlock).

If install.sh stops during setup (network, a download), do not reinstall: fix the cause, `git pull`, then `./resume.sh` in the same live session. It mounts the installed system (asking for the passphrase if needed) and re-runs setup.sh inside it; every step is safe to repeat. `./resume.sh apps finish` runs only those steps.

Dual boot: Windows appears in the grub menu. Resume BitLocker in Windows afterwards (Control Panel > BitLocker > Resume protection).
If Windows ever boots straight to itself after an update, pick Void with F12 or move it first in BIOS > Startup > Boot.

## First login

| What | How |
|---|---|
| Fingerprint | `fprintd-enroll` (then works for sudo and the lock screen) |
| Firmware (BIOS, fingerprint, ...) | `fwupdmgr refresh && fwupdmgr update` |
| Resilio Sync | `resilio` (start + WebUI), `resilio stop` |
| pCloud | `cloud setup` once (browser login). Then `cloud open` (pCloud as a folder, also "pCloud" in the launcher), `cloud sync` (two-way sync of the folders listed in `~/.config/cloud-sync.conf`), `cloud send FILE` or right-click > "Send to pCloud" in Thunar (uploads, copies a share link). The official app is still available: `pcloud-install`. |
| Printer / scanner on wifi | usually found automatically; otherwise `system-config-printer`, scan with `simple-scan` |
| Wallpapers | drop images into `~/Pictures/Wallpapers` |
| Look | Super+, -> Theme: pick another palette, or "wallpaper" to derive colours from the wallpaper; every app follows |
| BORE kernel | built automatically after the first boot when on AC (about an hour), or now: `sudo ~/enter_void/setup.sh kernel`; check with `uname -r` (ends in `-bore`) |
| Dev tools | `claude`, `agy` (Antigravity CLI), `omp` (oh-my-pi), `deno`, `cargo`/`rustup`, `go`, `sbcl` (Common Lisp) - log in to each on first run |
| Speakers | EasyEffects with Lenovo's Dolby tuning for this X1, made from the Windows driver: `sudo ~/enter_void/setup.sh speakers` once after the first login (needs a readable Windows partition: with BitLocker on, even suspended, C: is still encrypted and the step is skipped) |
| Interactive Brokers TWS | Linux build from IBKR (bundled Java, installs into your home, no sudo): download [tws-latest-standalone-linux-x64.sh](https://download2.interactivebrokers.com/installers/tws/latest-standalone/tws-latest-standalone-linux-x64.sh) (or [stable](https://download2.interactivebrokers.com/installers/tws/stable-standalone/tws-stable-standalone-linux-x64.sh)), then `sh ~/Downloads/tws-*-linux-x64.sh`. It runs through XWayland; niri sets `_JAVA_AWT_WM_NONREPARENTING=1` so its windows are not blank |
| Phone | KDE Connect: install the KDE Connect app on the phone, same Wi-Fi, pair from the tray icon (firewall opens 1714-1764 to the LAN only) |
| Tailscale | `sudo tailscale up` once (opens a login link), then `sudo tailscale set --operator=$USER` so `tailscale status` / `tailscale up/down` work without sudo. The firewall trusts the tailnet (`tailscale0`): your own devices reach KDE Connect, Resilio etc. over it |
| Key wallpapers | The default wallpapers are cheat sheets of the keys (niri and Plasma each have their own), rendered from `files/wallpaper/*.typ` into `~/Pictures/Wallpapers/keys-*.png`. Read them on an empty workspace (niri: Super+Page Down) or Meta+Shift+D (Plasma). Back to the Hokusai print: Noctalia Settings > Wallpaper, or `plasma-apply-wallpaperimage ~/Pictures/Wallpapers/great-wave.jpg`. On a Plasma set up before this change: `plasma-apply-wallpaperimage ~/Pictures/Wallpapers/keys-plasma.png` once |
| Remote desktop | `rustdesk` (start it when needed, no background service), Remmina for RDP/VNC |
| Backups | snapshots are not backups: `restic` + `rclone` are installed, e.g. `restic -r rclone:pcloud:backup init` |

## niri or KDE Plasma

Both are installed. At the login screen press **F3** and pick `Niri (Void)` or `Plasma (Void)`; the last choice is remembered.
To switch: log out (niri: Super+Shift+E, Plasma: Super+Shift+E or Ctrl+Alt+Del), F3, pick the other one.

Plasma is set up to look like the niri desktop: one thin panel on the left edge (launcher, desktops, open apps, tray, clock),
no window borders, maximised windows without a title bar border, animations off, Inter / JetBrains Mono / Papirus / Bibata,
Hokusai wallpaper, the Noctalia palette (taken over at the next Plasma login after you change it in niri), the same keyring.
The main keys match: Super+Return terminal, Super+D / Space launcher (KRunner), Super+Q close, Super+F maximise,
Super+Shift+F fullscreen, Super+O overview, Super+1..4 / Shift desktop, Super+B / Shift+B / E / A apps, Super+P screen switcher (Plasma's own), Super+Shift+D peek at desktop, Super+Esc lock,
Super+V clipboard, Super+. emoji. Plasma tiling: Super+T.
Panel back to the repo layout: `plasma-apply-lookandfeel -a org.enter_void.desktop --resetLayout`.

## Daily use

One grammar (Super = Mod), H/J/K/L and arrows interchangeable. `Super+Shift+/` shows everything on screen.

| Modifier + direction | Does |
|---|---|
| Super + dir | focus (crosses into the next workspace / monitor at the edge) |
| Super+Ctrl + dir | move the window |
| Super+Shift + dir | send the column: up/down = workspace above/below, left/right = other monitor |
| Super+Alt + dir | resize (left/right = width, up/down = height) |
| Super+1..9 / +Shift / +Ctrl | go to workspace / send column there / send only the window there |

| Key | Action | Key | Action |
|---|---|---|---|
| Super+Space, Super+D | launcher | Super+Q | close window |
| Super+. | emoji | Super+F / Ctrl+F / M | maximise to edges (whole screen bar aside) / fill free width / maximise column (gaps kept) |
| Super+V | clipboard history | Super+Shift+F / Alt+F | fullscreen / fullscreen inside the column |
| Super+S | control center | Super+R / Shift+R / Ctrl+R | width presets / height presets / reset height |
| Super+, | settings | Super+- / = (Shift: height) | narrower / wider by 10 % |
| Super+N / Shift+N | do not disturb / dismiss notifications | Super+C / Ctrl+C | centre column / centre all visible |
| Super+Ctrl+N / W / T | night light / next wallpaper / dark-light | Super+[ / ] | pull window into / push out of the column |
| Super+Return / Shift+Return | terminal / floating terminal | Super+W | tabs in the column |
| Super+B / Shift+B | Helium / Floorp | Super+T / Shift+T | float-tile / jump between float and tile |
| Super+E / A / P | files / audio mixer / KeePassXC | Super+O | overview (drag windows between workspaces) |
| Ctrl+Shift+Esc | task manager (btop) | Super+Tab / Super+` | previous workspace / previous window |
| Alt+Tab | window switcher | Super+U / I, Page Down / Up | workspace below / above |
| PrtSc / Shift / Alt / Ctrl +PrtSc | screenshot whole screen / region / window / annotate |
| Super+PrtSc / Super+Shift+PrtSc | record screen (start/stop) / record region | | | Super+Shift+Page Down / Up | reorder workspaces |
| | | Super+Home / End (+Ctrl) | first / last column (move there) |
| Super+Esc | lock | Super+Shift+Esc | power menu |
| Super+Ctrl+Esc | pass all keys to the app (VM, remote desktop) | Super+Shift+E / P | quit niri / screens off |

```sh
xu                         # update everything, wrapped in a snapper pre/post snapshot
xi <pkg>                   # install, same snapshot wrapping
snapper -c root list       # snapshots of /, also bootable from the grub menu
sudo snapper-rollback N    # make snapshot N the new / (reboot afterwards)
sudo ~/enter_void/setup.sh apps    # update Helium, Floorp, Resilio, fonts, Noctalia now (cron: once a day, on AC with battery above 80 %)
```

Updates need no repo: `xu` for packages, cron for the upstream apps. `~/enter_void/refresh.sh` is only for taking changes
made to this repo onto a running system (VM or laptop, dual boot makes no difference). It replaces every dotfile that differs from the repo,
including your own edits to niri/foot/fish configs (old files go to `~/.backup`; Noctalia's Settings live in `~/.local/state`
and Plasma's System Settings are merged, not replaced, so both are kept), so skip it if you have edited those files by hand.

### When a refresh breaks something

Every `refresh.sh` run takes snapper snapshots of `/` and `/home` before it changes anything (`snapper -c home list` shows them as `refresh.sh` pre/post pairs). Easiest first:

1. **Undo the last run:** `~/enter_void/refresh.sh undo`. Reverts everything that run changed in your home (dotfiles, the repo checkout) plus `/usr/local` (Noctalia, scripts) and `/etc/greetd` (login screen), then restarts Noctalia. Run it again to go one more run back.
   No desktop? Ctrl+Alt+F2 gives a text login; run it there, then Ctrl+Alt+F7 back to the login screen.
2. **One file only:** each replaced dotfile is also in `~/.backup/<name> <date>`, e.g.
   `ls -t ~/.backup | head` then `cp ~/.backup/"config.kdl 2026-10-16 21-45-00" ~/.config/niri/config.kdl`.
   To see what a run changed: `snapper -c home status PRE..POST` (numbers from `snapper -c home list`).
3. **The system itself is broken** (a package update, or it no longer boots): in the grub menu pick the snapshots entry
   and boot the `refresh.sh` pre snapshot (read-only, to check), then make it permanent with `sudo snapper-rollback N` and reboot.
   If the run also updated the kernel, pick the previous kernel under "Advanced options" in grub.

`refresh.sh undo` leaves installed packages as they are; only step 3 takes packages back.

`setup.sh` can be re-run any time, whole or per step: `base packages user security snapper login desktop apps devtools kernel finish`.
Logs: `/var/log/enter_void/`.

## Files

| Path | Purpose |
|---|---|
| `config.sh` | every decision: host, user, locale, keyboard, disk, snapshot policy, ports |
| `packages.txt` | everything installed with xbps |
| `install.sh` | live ISO -> partitions, LUKS, btrfs subvolumes, bootstrap, grub |
| `refresh.sh` | on the running desktop: snapshots, `git pull` + take the repo's dotfiles (old ones to `~/.backup`) + restart Noctalia; `refresh.sh undo` reverts the last run |
| `resume.sh` | live ISO -> re-enter the installed system and run setup.sh steps (after a failed install, or to repair) |
| `setup.sh` | system config, services, hardening, snapper, desktop, upstream apps |
| `files/` | configs copied to `/etc` and the home folder (dotfiles never overwrite your edits) |
| `enter_void_design.md` | why things are the way they are, gotchas, changelog |
