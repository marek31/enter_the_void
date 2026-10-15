# enter_void

Scripts that turn a blank ThinkPad X1 Carbon Gen 10 into `x1-void`: Void Linux, btrfs + snapper every 15 min,
niri + Noctalia on Wayland, Helium, Floorp, Firefox, Opera, LibreOffice, wifi printers and scanners, Resilio Sync and pCloud.
No flatpak, no snap. All decisions are listed (and editable) in [config.sh](config.sh).

## Install

1. Write the Void live image (x86_64, **glibc**, base) to a USB stick: <https://voidlinux.org/download/>
2. BIOS (F1): disable Secure Boot, keep UEFI on. Boot the stick (F12).
   In a VM: UEFI firmware (VirtualBox: System > Enable EFI; Hyper-V: Generation 2, Secure Boot off) and 3D acceleration on.
3. Log in as `root` / `voidlinux` and get online. USB ethernet just works. For wifi, find the interface with `ip link` (AX211 is usually `wlp0s20f3`), then
   `wpa_passphrase SSID PASS > /etc/wpa.conf; wpa_supplicant -B -i wlp0s20f3 -c /etc/wpa.conf; dhcpcd wlp0s20f3`. Then:

```sh
xbps-install -Sy xbps git
git clone https://github.com/marek31/enter_void
cd enter_void
vi config.sh          # optional: disk, swap size, scale, ...
./install.sh          # wipes the disk you pick; asks for the disk passphrase and the user password
```

4. Reboot. After the grub menu the passphrase is asked once (about 2 s to unlock), then the text login (tuigreet).

If install.sh stops during setup (network, a download), do not reinstall: fix the cause, `git pull`, then `./resume.sh` in the same live session. It mounts the installed system (asking for the passphrase if needed) and re-runs setup.sh inside it; every step is safe to repeat. `./resume.sh apps finish` runs only those steps.

### Dual boot on the X1 (Windows stays)

Before installing, make sure in Windows: the disk has free (unallocated) space, Secure Boot is off, BitLocker is off or you have its
recovery key, Fast Startup is off. install.sh offers mode `free` there: it creates one partition in that gap,
shares the 260 MB EFI partition (adds `EFI\Void` next to `EFI\Microsoft`, formats nothing) and puts Windows in the grub menu.

Before installing, in an **admin** PowerShell on Windows (keeps the clock right when switching OSes, both then use UTC):
```powershell
reg add "HKLM\SYSTEM\CurrentControlSet\Control\TimeZoneInformation" /v RealTimeIsUniversal /t REG_DWORD /d 1 /f
```
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
| Dev tools | `claude`, `agy` (Antigravity CLI), `omp` (oh-my-pi), `deno`, `cargo`/`rustup`, `go` - log in to each on first run |
| Speakers | EasyEffects with Lenovo's Dolby tuning for this X1, made from the Windows driver on the first `refresh.sh` / `sudo ~/enter_void/setup.sh speakers` (needs the Windows partition) |
| Phone | KDE Connect: install the KDE Connect app on the phone, same Wi-Fi, pair from the tray icon (firewall opens 1714-1764 to the LAN only) |
| Remote desktop | `rustdesk` (start it when needed, no background service), Remmina for RDP/VNC |
| Backups | snapshots are not backups: `restic` + `rclone` are installed, e.g. `restic -r rclone:pcloud:backup init` |

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
| Super+. | emoji | Super+F / Ctrl+F / M | maximise column / fill free width / maximise to edges |
| Super+V | clipboard history | Super+Shift+F / Alt+F | fullscreen / fullscreen inside the column |
| Super+S | control center | Super+R / Shift+R / Ctrl+R | width presets / height presets / reset height |
| Super+, | settings | Super+- / = (Shift: height) | narrower / wider by 10 % |
| Super+N / Shift+N | do not disturb / dismiss notifications | Super+C / Ctrl+C | centre column / centre all visible |
| Super+Ctrl+N / I / W / T | night light / keep awake / next wallpaper / dark-light | Super+[ / ] | pull window into / push out of the column |
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

After a `git pull` with look changes: `~/enter_void/refresh.sh` (normal runs never overwrite your dotfiles).

`setup.sh` can be re-run any time, whole or per step: `base packages user security snapper login desktop apps devtools kernel finish`.
Logs: `/var/log/enter_void/`.

## Files

| Path | Purpose |
|---|---|
| `config.sh` | every decision: host, user, locale, keyboard, disk, snapshot policy, ports |
| `packages.txt` | everything installed with xbps |
| `install.sh` | live ISO -> partitions, LUKS, btrfs subvolumes, bootstrap, grub |
| `refresh.sh` | on the running desktop: `git pull` + take the repo's dotfiles (old ones to `~/.backup`) + restart Noctalia |
| `resume.sh` | live ISO -> re-enter the installed system and run setup.sh steps (after a failed install, or to repair) |
| `setup.sh` | system config, services, hardening, snapper, desktop, upstream apps |
| `files/` | configs copied to `/etc` and the home folder (dotfiles never overwrite your edits) |
| `enter_void_design.md` | why things are the way they are, gotchas, changelog |
