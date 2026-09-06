#!/bin/bash
#
# pre-release.sh — Convention hook run by the release skill before archiving.
# Regenerates the app icon. python3 on PATH may be a venv without Pillow, so
# probe known binaries instead of trusting PATH.
#
set -euo pipefail
cd "$(dirname "$0")/.."

FOUND=""
for CANDIDATE in "${PYTHON:-}" /opt/homebrew/bin/python3 /usr/local/bin/python3 python3; do
  [ -n "$CANDIDATE" ] || continue
  if "$CANDIDATE" -c "import PIL" 2>/dev/null; then FOUND="$CANDIDATE"; break; fi
done
[ -n "$FOUND" ] || { echo "Nenhum python3 com Pillow encontrado: python3 -m pip install pillow" >&2; exit 1; }

"$FOUND" scripts/make-icon.py
