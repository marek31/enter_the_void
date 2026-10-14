# enter_void

Scripts that turn a blank ThinkPad X1 Carbon Gen 10 into `x1-void`: Void Linux, btrfs + snapper every 15 min,
niri + Noctalia on Wayland, Helium + Floorp, LibreOffice, wifi printers and scanners, Resilio Sync and pCloud.
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

4. Reboot. grub asks for the disk passphrase once, tuigreet starts niri.

## First login

| What | How |
|---|---|
| Fingerprint | `fprintd-enroll` (then works for sudo and the lock screen) |
| Firmware (BIOS, fingerprint, ...) | `fwupdmgr refresh && fwupdmgr update` |
| Resilio Sync | `resilio` (start + WebUI), `resilio stop` |
| pCloud | download the Linux AppImage from <https://www.pcloud.com/download-free-online-cloud-file-storage.html>, then `pcloud-install`, then `pcloud` |
| Printer / scanner on wifi | usually found automatically; otherwise `system-config-printer`, scan with `simple-scan` |
| Wallpapers | drop images into `~/Pictures/Wallpapers` |

## Daily use

| Key | Action |
|---|---|
| Super+Space | launcher |
| Super+S / Super+, | control center / Noctalia settings |
| Super+Return / B / Shift+B / E | foot / Helium / Floorp / Thunar |
| Super+O | overview |
| Super+Alt+L | lock |
| Super+Shift+/ | all key bindings |

```sh
xu                         # update everything, wrapped in a snapper pre/post snapshot
xi <pkg>                   # install, same snapshot wrapping
snapper -c root list       # snapshots of /, also bootable from the grub menu
sudo snapper-rollback N    # make snapshot N the new / (reboot afterwards)
sudo ~/enter_void/setup.sh apps    # update Helium, Floorp, Resilio, fonts, Noctalia
```

`setup.sh` can be re-run any time, whole or per step: `base packages user security snapper login desktop apps finish`.
Logs: `/var/log/enter_void/`.

## Files

| Path | Purpose |
|---|---|
| `config.sh` | every decision: host, user, locale, keyboard, disk, snapshot policy, ports |
| `packages.txt` | everything installed with xbps |
| `install.sh` | live ISO -> partitions, LUKS, btrfs subvolumes, bootstrap, grub |
| `setup.sh` | system config, services, hardening, snapper, desktop, upstream apps |
| `files/` | configs copied to `/etc` and the home folder (dotfiles never overwrite your edits) |
| `enter_void_design.md` | why things are the way they are, gotchas, changelog |
