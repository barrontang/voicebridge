#!/usr/bin/env bash
# make-icon.sh — build Resources/AppIcon.icns from the two master PNGs.
#
# The icon has two masters on purpose: macOS renders 16/32/64 px straight from
# the .icns, and the sound arcs turn into mud at those sizes. Small sizes use
# the simplified art (no arcs, thicker mic); 128 px and up use the full one.
#
# Usage:
#   scripts/make-icon.sh            # rebuild the .icns from the committed PNGs
#   scripts/make-icon.sh --redraw   # re-render the PNGs first (needs Pillow)
#
# `--redraw` needs a python3 with Pillow. The committed PNGs mean a normal
# build never does: sips + iconutil ship with macOS.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BIG="Resources/AppIcon-1024.png"
SMALL="Resources/AppIcon-1024-small.png"
OUT="Resources/AppIcon.icns"
PY="${PYTHON:-python3}"

if [ "${1:-}" = "--redraw" ] || [ ! -f "$BIG" ] || [ ! -f "$SMALL" ]; then
  if ! "$PY" -c 'import PIL' 2>/dev/null; then
    echo "error: --redraw needs python3 with Pillow (pip install pillow)" >&2
    exit 1
  fi
  "$PY" scripts/make-icon.py "$BIG"
  "$PY" scripts/make-icon.py --simplified "$SMALL"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
iconset="$work/AppIcon.iconset"
mkdir -p "$iconset"

# Small art: 16/32/64 px. Detailed art: 128 px and up.
sips -z 16 16 "$SMALL" --out "$iconset/icon_16x16.png" >/dev/null
sips -z 32 32 "$SMALL" --out "$iconset/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$SMALL" --out "$iconset/icon_32x32.png" >/dev/null
sips -z 64 64 "$SMALL" --out "$iconset/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$BIG" --out "$iconset/icon_128x128.png" >/dev/null
sips -z 256 256 "$BIG" --out "$iconset/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$BIG" --out "$iconset/icon_256x256.png" >/dev/null
sips -z 512 512 "$BIG" --out "$iconset/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$BIG" --out "$iconset/icon_512x512.png" >/dev/null
cp "$BIG" "$iconset/icon_512x512@2x.png"

iconutil -c icns "$iconset" -o "$OUT"
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))"
