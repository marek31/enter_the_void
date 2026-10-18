#!/bin/sh
# Run as yourself inside niri: pull the repo, install packages/apps/dev tools added since (and update the
# system), take its dotfiles (your old ones go to ~/.backup),
# restart Noctalia so the new look shows up. niri reloads its own config by itself.
#
# Every run is wrapped in snapper pre/post snapshots of / and /home. If something breaks afterwards:
#   ~/enter_void/refresh.sh undo     (also works from a text console: Ctrl+Alt+F2, log in)
# reverts everything the last run changed in your home (dotfiles, repo checkout) plus /usr/local (Noctalia,
# scripts) and /etc/greetd (login screen). Installed/updated packages stay; see README "When a refresh breaks something".
set -e
# as root, the restart below would start Noctalia for root, outside your session: no bar, no launcher
[ "$(id -u)" -ne 0 ] || { echo "run refresh.sh as yourself, not root (it calls sudo itself)"; exit 1; }
state=${XDG_STATE_HOME:-$HOME/.local/state}/enter_void/refresh-snapshots   # one line per run: root_pre root_post home_pre home_post

restart_noctalia() {
    # only from inside niri: from a text console Noctalia has no display and dies, under Plasma it would draw a second bar
    if [ "$XDG_CURRENT_DESKTOP" != niri ] || [ -z "$WAYLAND_DISPLAY" ]; then
        echo "not inside niri, so Noctalia was not restarted (log out and back in to see changes)"
        return 0
    fi
    log=~/.local/state/noctalia/$(date '+%F')-noctalia.log
    mkdir -p "$(dirname "$log")"
    pkill -x noctalia || true
    # pkill does not wait: a new instance started too early sees the old one and exits ("already running")
    i=0
    while pgrep -x noctalia >/dev/null && [ $i -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
    pkill -KILL -x noctalia 2>/dev/null || true
    setsid -f noctalia >>"$log" 2>&1
    sleep 3
    pgrep -x noctalia >/dev/null || { echo "Noctalia did not start - last lines of $log:"; tail -n 20 "$log"; return 1; }
}

if [ "$1" = undo ]; then
    # undo also reverts this repo, refresh.sh included: run from a copy, not from a file being rewritten
    if [ -z "$REFRESH_UNDO_COPY" ]; then
        copy=$(mktemp "${TMPDIR:-/tmp}/refresh-undo.XXXXXX")
        cp "$0" "$copy"
        REFRESH_UNDO_COPY=$copy exec sh "$copy" undo
    fi
    [ -s "$state" ] || { echo "no refresh.sh run recorded in $state - see README: When a refresh breaks something"; exit 1; }
    read -r rpre rpost hpre hpost <<EOF
$(tail -n 1 "$state")
EOF
    echo "undoing the last refresh: home snapshots $hpre..$hpost, / snapshots $rpre..$rpost (/usr/local, /etc/greetd only)"
    sudo snapper --no-dbus -c home undochange "$hpre..$hpost"
    # only paths that are safe to roll back under newer packages; kernel modules, /etc of packages etc. stay
    sudo snapper --no-dbus -c root status "$rpre..$rpost" | sed 's/^[^ ]* //' | grep -E '^/(usr/local|etc/greetd)(/|$)' |
        xargs -r -d '\n' sudo snapper --no-dbus -c root undochange "$rpre..$rpost"
    sed -i '$d' "$state"   # the next undo goes one run further back
    restart_noctalia || true
    rm -f "$REFRESH_UNDO_COPY"
    echo "done - log out and back in if the desktop still looks wrong"
    exit 0
fi

cd "$(dirname "$0")"
# safety net first, before git pull touches the checkout
rpre=$(sudo snapper --no-dbus -c root create -t pre -p -c number -d "refresh.sh")
hpre=$(sudo snapper --no-dbus -c home create -t pre -p -c number -d "refresh.sh")
finish() {
    rc=$?
    rpost=$(sudo snapper --no-dbus -c root create -t post --pre-number "$rpre" -p -c number -d "refresh.sh")
    hpost=$(sudo snapper --no-dbus -c home create -t post --pre-number "$hpre" -p -c number -d "refresh.sh")
    mkdir -p "${state%/*}"
    echo "$rpre $rpost $hpre $hpost" >> "$state"
    [ $rc -eq 0 ] && echo "done" || echo "refresh.sh failed (exit $rc)"
    echo "something wrong now? ~/enter_void/refresh.sh undo   (reverts this run's changes)"
    exit $rc
}
trap finish EXIT

git pull --ff-only
sudo ./setup.sh packages security apps login devtools speakers dotfiles
# bar changes made in Settings (Mod+Comma) win over the repo's config.toml
grep -Eqs '^\[(bar|widget)' ~/.local/state/noctalia/settings.toml &&
    echo "note: ~/.local/state/noctalia/settings.toml overrides the bar; remove its [bar...]/[widget...] sections to get the repo look"
# GitHub login is interactive (browser), so it can't be scripted: remind until it's done
if ! gh auth status >/dev/null 2>&1 || ! git config --global --get credential.https://github.com.helper >/dev/null; then
    echo "note: git can't push to GitHub yet - run once: gh auth login (GitHub.com > HTTPS > Login with a web browser), then: gh auth setup-git"
fi
restart_noctalia
