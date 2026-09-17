#!/bin/bash
#
# Recolour the notch animations from the inherited blue to Irys green.
#
# Usage:  tools/recolor_animations.sh [hue-shift] [saturation]
#
# A hue rotation, not a redraw: the animations themselves are unchanged, only
# their colour moves. All three clips measured at hue 209.6 (blue) including the
# failure one, which is not red — so they all shift by the same amount and stay
# consistent with each other.
#
# Defaults land on roughly #4E9142, a muted green close to the Face ID scan
# colour rather than a neon one. Re-run with different numbers to retune; the
# sources are in git, so this is always reversible.
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

HUE="${1:--95}"
SAT="${2:-0.50}"
RES="glance/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for clip in idleanimation unlockanimation unsuccessfulunlockanimation; do
  [ -f "$RES/$clip.mp4" ] || { echo "missing $clip.mp4"; exit 1; }
  echo "==> $clip.mp4"
  # -crf 18 keeps these visually lossless; they are small and re-encoding a
  # gradient-heavy clip at a lower quality shows banding immediately.
  xcrun ffmpeg -loglevel error -y -i "$RES/$clip.mp4" \
    -vf "hue=h=${HUE}:s=${SAT}" \
    -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -an \
    "$TMP/$clip.mp4"
  mv "$TMP/$clip.mp4" "$RES/$clip.mp4"
done

echo "==> unlockstatic.png"
xcrun ffmpeg -loglevel error -y -i "$RES/unlockstatic.png" \
  -vf "hue=h=${HUE}:s=${SAT}" "$TMP/unlockstatic.png"
mv "$TMP/unlockstatic.png" "$RES/unlockstatic.png"

echo "Done. hue=${HUE} sat=${SAT}"
