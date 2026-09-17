#!/bin/bash
#
# Build a styled Irys.dmg from an already-built, signed Irys.app.
#
# Usage:  tools/make_dmg.sh /path/to/Irys.app [output.dmg]
#
# The window gets a background image, a fixed size, hidden chrome and the two
# icons placed on the arrow drawn into the background. Everything here is
# ordinary hdiutil plus one AppleScript pass — no third-party tooling.
#
# The DMG is signed and notarized in its own right. A notarized app inside an
# un-notarized disk image still trips Gatekeeper on the *image*, which is the
# first thing the user double-clicks, so doing only the app is not enough.
#
set -euo pipefail

APP="${1:?usage: make_dmg.sh /path/to/Irys.app [output.dmg]}"
OUT="${2:-$HOME/Desktop/Irys.dmg}"
VOLNAME="Irys"
TEAM="6TTTJ5468H"
IDENTITY="Developer ID Application: Daniel Ghiyam ($TEAM)"
PROFILE="irys-notary"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BG="$REPO/build-support/dmg-background.png"
BG2X="$REPO/build-support/dmg-background@2x.png"

[ -d "$APP" ] || { echo "no such app: $APP"; exit 1; }
[ -f "$BG" ] || { echo "missing $BG"; exit 1; }

STAGE="$(mktemp -d)"
TMPDMG="$(mktemp -u).dmg"
cleanup() {
  [ -n "${MOUNTPT:-}" ] && hdiutil detach "$MOUNTPT" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$TMPDMG" 2>/dev/null || true
}
trap cleanup EXIT

echo "==> Staging"
ditto "$APP" "$STAGE/Irys.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.png"
[ -f "$BG2X" ] && cp "$BG2X" "$STAGE/.background/background@2x.png"

# Sized from the app plus generous slack; a DMG that needs resizing mid-build is
# a classic source of "no space left on device" right at the copy step.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 120 ))

echo "==> Creating read/write image (${SIZE_MB}MB)"
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" "$TMPDMG" -quiet

MOUNTPT="/Volumes/$VOLNAME"
hdiutil attach "$TMPDMG" -readwrite -noverify -noautoopen -quiet
# The Finder needs a moment after attach before it will answer AppleScript about
# the new volume; without this the view settings silently do not stick.
sleep 2

echo "==> Applying window style"
# Non-fatal: this needs Finder automation permission, and on a machine that has
# not granted it the DMG should still be produced, just unstyled.
osascript <<APPLESCRIPT || echo "    (Finder styling skipped — grant Automation access to style the window)"
tell application "Finder"
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 820, 560}
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 112
    set text size of vopts to 12
    set label position of vopts to bottom
    set background picture of vopts to file ".background:background.png"
    -- Positions match the arrow drawn into the background image.
    set position of item "Irys.app" of container window to {158, 180}
    set position of item "Applications" of container window to {462, 180}
    -- Hidden entries still occupy the grid unless pushed out of the viewport.
    try
      set position of item ".background" of container window to {700, 700}
    end try
    close
    open
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNTPT" -quiet
MOUNTPT=""

echo "==> Compressing"
rm -f "$OUT"
hdiutil convert "$TMPDMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" -quiet

echo "==> Signing the image"
codesign --force --timestamp --sign "$IDENTITY" "$OUT"

echo "==> Notarizing the image"
xcrun notarytool submit "$OUT" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT"
spctl -a -vvv -t open --context context:primary-signature "$OUT" 2>&1 | tail -3

echo "==> Done: $OUT"
