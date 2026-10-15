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
grep -qs '^\[bar' ~/.local/state/noctalia/settings.toml &&
    echo "note: ~/.local/state/noctalia/settings.toml overrides the bar; remove its [bar...] section to get the repo look"
pkill -x noctalia || true
setsid -f noctalia >/dev/null 2>&1
echo "done"
