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
# IMPORTANT: this must run against the ORIGINAL blue clips, not against an
# already-recoloured set. A hue rotation applied twice compounds. If the files
# in Resources have already been shifted, restore them from git first:
#   git show 821b33a~1:glance/Resources/<clip>.mp4 > glance/Resources/<clip>.mp4
#
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Defaults tuned by measuring the result rather than by eye: the search in
# tools/ landed on this as the closest match to Apple's dark-mode system green
# (#30D158), reaching #3CC25F. `hue` alone could not get there — it rotates and
# saturates but barely moves brightness, so the first attempt produced a green
# that was correct in hue and much too dark. The eq stage is what supplies the
# lightness.
HUE="${1:--73}"
EQ="${2:-saturation=0.85:brightness=0.12:contrast=1.08}"
# Pulls the black point back down after the eq stage. Raising brightness enough
# to reach the target green also lifts the clips' black background to about
# #131512, which shows as a grey rectangle against the notch's black panel.
# 0.08 restores a true black while costing only a few points of ring brightness.
BLACK_POINT="${3:-0.08}"
RES="glance/Resources"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

for clip in idleanimation unlockanimation unsuccessfulunlockanimation; do
  [ -f "$RES/$clip.mp4" ] || { echo "missing $clip.mp4"; exit 1; }
  echo "==> $clip.mp4"
  # -crf 18 keeps these visually lossless; they are small and re-encoding a
  # gradient-heavy clip at a lower quality shows banding immediately.
  xcrun ffmpeg -loglevel error -y -i "$RES/$clip.mp4" \
    -vf "hue=h=${HUE}:s=1.0,eq=${EQ},colorlevels=rimin=${BLACK_POINT}:gimin=${BLACK_POINT}:bimin=${BLACK_POINT}" \
    -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p -an \
    "$TMP/$clip.mp4"
  mv "$TMP/$clip.mp4" "$RES/$clip.mp4"
done

echo "==> unlockstatic.png"
xcrun ffmpeg -loglevel error -y -i "$RES/unlockstatic.png" \
  -vf "hue=h=${HUE}:s=1.0,eq=${EQ},colorlevels=rimin=${BLACK_POINT}:gimin=${BLACK_POINT}:bimin=${BLACK_POINT}" "$TMP/unlockstatic.png"
mv "$TMP/unlockstatic.png" "$RES/unlockstatic.png"

echo "Done. hue=${HUE} eq=${EQ} black=${BLACK_POINT}"
