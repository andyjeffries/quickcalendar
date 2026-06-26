#!/usr/bin/env bash
#
# quickcalendar installer.
#
#   ./install.sh            Copy files into place (recommended for users).
#   ./install.sh --link     Symlink files back to this repo (the repo stays the
#                           source of truth — handy if you track it in dotfiles
#                           or want `git pull` to update the live install).
#   ./install.sh --uninstall
#                           Remove installed files + disable the timer.
#                           Leaves your config and cached state alone.
#
# Installs two commands:
#   quickcalendar        the calendar viewer (Quickshell week view)
#   quickcalendar-sync   the background agent (ICS sync, reminders, alerts)
#
# Honours XDG_* and the BINDIR/QMLDIR/... env overrides below.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BINDIR="${BINDIR:-$HOME/.local/bin}"
QMLDIR="${QMLDIR:-${XDG_DATA_HOME:-$HOME/.local/share}/quickcalendar}"
APPDIR="${APPDIR:-${XDG_DATA_HOME:-$HOME/.local/share}/applications}"
UNITDIR="${UNITDIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
CONFIGDIR="${CONFIGDIR:-${XDG_CONFIG_HOME:-$HOME/.config}/quickcalendar}"

MODE="copy"
case "${1:-}" in
  --link)       MODE="link" ;;
  --uninstall)  MODE="uninstall" ;;
  -h|--help)    sed -n '3,18p' "$0"; exit 0 ;;
  "")           ;;
  *)            echo "unknown option: $1 (try --help)" >&2; exit 2 ;;
esac

say()    { printf '  %s\n' "$*"; }
heading(){ printf '\n\033[1m%s\033[0m\n' "$*"; }

# ── place SRC DST : copy or symlink one file, depending on MODE ───────────────
place() {
  local src="$1" dst="$2"
  mkdir -p "$(dirname "$dst")"
  rm -f "$dst"
  if [ "$MODE" = "link" ]; then
    ln -s "$src" "$dst"
  else
    cp "$src" "$dst"
  fi
}

# ── uninstall ────────────────────────────────────────────────────────────────
if [ "$MODE" = "uninstall" ]; then
  heading "Uninstalling quickcalendar"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now quickcalendar-sync.timer 2>/dev/null || true
  fi
  rm -f "$BINDIR/quickcalendar" "$BINDIR/quickcalendar-sync" \
        "$UNITDIR/quickcalendar-sync.service" "$UNITDIR/quickcalendar-sync.timer" \
        "$APPDIR/quickcalendar.desktop"
  rm -rf "$QMLDIR"
  command -v systemctl >/dev/null 2>&1 && systemctl --user daemon-reload || true
  say "Removed. Your config ($CONFIGDIR) and cache were left untouched."
  exit 0
fi

# ── dependency check (warn only) ─────────────────────────────────────────────
heading "Checking dependencies"
missing=()
need() { command -v "$1" >/dev/null 2>&1 || missing+=("$2"); }
need python3 "python3"
need quickshell "quickshell"
need notify-send "libnotify (notify-send)"
need xdg-open "xdg-utils (xdg-open)"
python3 -c 'import dateutil.rrule' 2>/dev/null || missing+=("python-dateutil")
python3 -c 'import gi; gi.require_version("Gtk","4.0")' 2>/dev/null || missing+=("gtk4 + python-gobject")
[ -e /usr/lib/libgtk4-layer-shell.so ] || [ -e /usr/lib64/libgtk4-layer-shell.so ] || missing+=("gtk4-layer-shell")
if [ "${#missing[@]}" -eq 0 ]; then
  say "All present."
else
  say "Missing (the fullscreen alert/reminders need these):"
  for m in "${missing[@]}"; do say "  - $m"; done
  say "On Arch: sudo pacman -S --needed python-dateutil gtk4 gtk4-layer-shell python-gobject libnotify quickshell"
fi

# ── install ──────────────────────────────────────────────────────────────────
heading "Installing ($MODE mode)"
place "$REPO/bin/quickcalendar"      "$BINDIR/quickcalendar"
place "$REPO/bin/quickcalendar-sync" "$BINDIR/quickcalendar-sync"
[ "$MODE" = "copy" ] && chmod +x "$BINDIR/quickcalendar" "$BINDIR/quickcalendar-sync"
say "binaries → $BINDIR  (quickcalendar, quickcalendar-sync)"

for f in "$REPO"/qml/*.qml; do place "$f" "$QMLDIR/$(basename "$f")"; done
say "qml → $QMLDIR"

place "$REPO/systemd/quickcalendar-sync.service" "$UNITDIR/quickcalendar-sync.service"
place "$REPO/systemd/quickcalendar-sync.timer"   "$UNITDIR/quickcalendar-sync.timer"
say "units → $UNITDIR"

# The .desktop embeds an absolute path, so always render a real file (never a
# symlink) with @BINDIR@ resolved.
mkdir -p "$APPDIR"
sed "s#@BINDIR@#$BINDIR#g" "$REPO/share/quickcalendar.desktop" > "$APPDIR/quickcalendar.desktop"
say "desktop → $APPDIR/quickcalendar.desktop"

# Seed the config only if the user doesn't already have one.
mkdir -p "$CONFIGDIR"
if [ -e "$CONFIGDIR/calendars.txt" ]; then
  say "config → $CONFIGDIR/calendars.txt (kept existing)"
else
  cp "$REPO/config/calendars.example.txt" "$CONFIGDIR/calendars.txt"
  say "config → $CONFIGDIR/calendars.txt (seeded from example — edit it!)"
fi

# ── enable the timer ─────────────────────────────────────────────────────────
heading "Enabling background sync"
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user daemon-reload
  systemctl --user enable --now quickcalendar-sync.timer
  say "quickcalendar-sync.timer enabled (polls every minute)."
else
  say "No user systemd session detected — enable later with:"
  say "  systemctl --user enable --now quickcalendar-sync.timer"
fi

command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPDIR" 2>/dev/null || true

heading "Done"
say "1. Edit your feeds:   \$EDITOR $CONFIGDIR/calendars.txt"
say "2. Force a sync now:  quickcalendar-sync refresh"
say "3. Open the viewer:   quickcalendar   (or the 'Quickcalendar' app launcher)"
