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

# A leftover mount of the same name is what forces the "Irys 1" rename above.
for stale in /Volumes/"$VOLNAME"*; do
  [ -d "$stale" ] && hdiutil detach "$stale" -force -quiet 2>/dev/null || true
done

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

# Take the mount point FROM hdiutil rather than assuming /Volumes/$VOLNAME.
#
# If anything already has a volume of this name mounted — a previous build, or a
# copy the user opened — macOS mounts this one as "Irys 1" instead. The script
# then styled a volume that was not the one being built, which is why the image
# came out with no window rect and no background recorded in its .DS_Store at
# all, while every command appeared to succeed.
ATTACH_OUT="$(hdiutil attach "$TMPDMG" -readwrite -noverify -noautoopen)"
MOUNTPT="$(echo "$ATTACH_OUT" | grep -o '/Volumes/.*$' | tail -1)"
[ -d "$MOUNTPT" ] || { echo "could not determine mount point"; exit 1; }
ACTUAL_VOL="$(basename "$MOUNTPT")"
echo "    mounted as: $ACTUAL_VOL"
# The Finder needs a moment after attach before it will answer AppleScript about
# the new volume; without this the view settings silently do not stick.
sleep 3

echo "==> Applying window style"
# Non-fatal: this needs Finder automation permission, and on a machine that has
# not granted it the DMG should still be produced, just unstyled.
osascript <<APPLESCRIPT || echo "    (Finder styling skipped — grant Automation access to style the window)"
tell application "Finder"
  tell disk "$ACTUAL_VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set vopts to the icon view options of container window
    set arrangement of vopts to not arranged
    set icon size of vopts to 112
    set text size of vopts to 12
    set label position of vopts to bottom
    set background picture of vopts to file ".background:background.png"
    set position of item "Irys.app" of container window to {152, 196}
    set position of item "Applications" of container window to {468, 196}
    try
      set position of item ".background" of container window to {900, 900}
    end try

    -- Set the bounds, then READ THEM BACK and retry until they take.
    --
    -- Finder restores a remembered window geometry for a volume of a given name
    -- and will quietly overwrite a size set moments earlier, which is why simply
    -- assigning bounds once left a strip of empty window beside the background.
    -- Assign-and-verify is the only reliable way to know it actually applied.
    --
    -- 620x420 is the background's size; the extra 28pt of height is the title
    -- bar, which 'bounds' includes and the content area does not.
    set targetBounds to {200, 140, 820, 588}
    repeat 8 times
      set the bounds of container window to targetBounds
      delay 0.4
      if the bounds of container window is targetBounds then exit repeat
    end repeat

    update without registering applications
    delay 1
    -- Assign once more after the update: 'update' itself can reflow the window.
    set the bounds of container window to targetBounds
    delay 0.6
    close
  end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store asynchronously; give it a beat, then confirm the
# styling is actually in the file rather than assuming osascript's exit code
# meant anything. A silently unstyled image is the failure mode this whole
# section keeps producing.
sleep 2
sync
if [ -f "$MOUNTPT/.DS_Store" ] && grep -qa "fwi0" "$MOUNTPT/.DS_Store"; then
  echo "    window geometry recorded"
else
  echo "    WARNING: no window geometry in .DS_Store — the image will open unstyled"
fi

hdiutil detach "$MOUNTPT" -quiet || hdiutil detach "$MOUNTPT" -force -quiet
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
