#!/bin/sh
# Run as yourself inside niri: pull the repo, install packages/apps/dev tools added since (and update the
# system), take its dotfiles (your old ones go to ~/.backup),
# restart Noctalia so the new look shows up. niri reloads its own config by itself.
set -e
# as root, the restart below would start Noctalia for root, outside your session: no bar, no launcher
[ "$(id -u)" -ne 0 ] || { echo "run refresh.sh as yourself, not root (it calls sudo itself)"; exit 1; }
cd "$(dirname "$0")"
git pull --ff-only
sudo ./setup.sh packages security apps login devtools speakers dotfiles
# bar changes made in Settings (Mod+Comma) win over the repo's config.toml
grep -Eqs '^\[(bar|widget)' ~/.local/state/noctalia/settings.toml &&
    echo "note: ~/.local/state/noctalia/settings.toml overrides the bar; remove its [bar...]/[widget...] sections to get the repo look"
# restart only from inside niri: from a text console Noctalia has no display and dies, and under Plasma
# it would draw a second bar
if [ "$XDG_CURRENT_DESKTOP" != niri ] || [ -z "$WAYLAND_DISPLAY" ]; then
    echo "done - not inside niri, so Noctalia was not restarted (log out and back in to see changes)"
    exit 0
fi
log=~/.local/state/noctalia/$(date '+%F')-noctalia.log
mkdir -p "$(dirname "$log")"
pkill -x noctalia || true
setsid -f noctalia >>"$log" 2>&1
sleep 3
pgrep -x noctalia >/dev/null || { echo "Noctalia did not start - last lines of $log:"; tail -n 20 "$log"; exit 1; }
echo "done"
