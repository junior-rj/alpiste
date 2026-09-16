#!/bin/bash
#
# pre-release.sh — Convention hook run by the release skill before archiving.
# Regenerates the app icon.
#
# python3 on PATH may be a venv without Pillow, so probe known binaries first,
# honouring an explicit $PYTHON. If none has Pillow, bootstrap a persistent venv
# once and reuse it: brew's python is externally-managed, so a global
# `pip install pillow` is refused by PEP 668, and --break-system-packages risks
# the Homebrew install. A migrated or freshly upgraded machine loses a
# hand-installed Pillow, and without this the whole release used to hard-fail on
# the icon step even though the committed AppIcon is already current (see
# erros.md 2026-09-15).
#
set -euo pipefail
cd "$(dirname "$0")/.."

# Fast path: a python that already imports PIL. Zero cost on a set-up machine.
FOUND=""
for CANDIDATE in "${PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  [ -n "$CANDIDATE" ] || continue
  if "$CANDIDATE" -c "import PIL" 2>/dev/null; then FOUND="$CANDIDATE"; break; fi
done

# Fallback: a dedicated venv, created once and reused. Kept in ~/Library/Caches
# (never iCloud-synced, so no re-stamped attributes) and out of the brew prefix
# (PEP 668). Override the location with $ALPISTE_ICON_VENV.
if [ -z "$FOUND" ]; then
  VENV="${ALPISTE_ICON_VENV:-$HOME/Library/Caches/Alpiste/icon-venv}"
  if [ ! -x "$VENV/bin/python3" ]; then
    BASE=""
    for CANDIDATE in /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
      command -v "$CANDIDATE" >/dev/null 2>&1 && { BASE="$CANDIDATE"; break; }
    done
    [ -n "$BASE" ] || { echo "No python3 available to build the icon venv" >&2; exit 1; }
    echo "==> Bootstrapping icon venv at $VENV"
    "$BASE" -m venv "$VENV"
    "$VENV/bin/python3" -m pip install --quiet --upgrade pip pillow
  fi
  # Reused venv might predate Pillow (interrupted bootstrap); make sure it is there.
  "$VENV/bin/python3" -c "import PIL" 2>/dev/null \
    || "$VENV/bin/python3" -m pip install --quiet pillow
  FOUND="$VENV/bin/python3"
fi

"$FOUND" scripts/make-icon.py
