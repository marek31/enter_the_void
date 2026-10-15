#!/bin/sh
# Run as yourself inside niri: pull the repo, install packages/apps/dev tools added since (and update the
# system), take its dotfiles (your old ones go to ~/.backup),
# restart Noctalia so the new look shows up. niri reloads its own config by itself.
set -e
cd "$(dirname "$0")"
git pull --ff-only
sudo ./setup.sh packages security apps devtools dotfiles
pkill -x noctalia || true
setsid -f noctalia >/dev/null 2>&1
echo "done"
