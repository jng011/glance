#!/bin/bash
#
# Build, sign, notarize and staple Irys.
#
# Usage:  tools/release.sh [output-dir]
#
# Requires, once, on this machine:
#   - "Developer ID Application: Daniel Ghiyam (6TTTJ5468H)" in the login keychain
#   - a notarytool keychain profile named "irys-notary", created with:
#       xcrun notarytool store-credentials "irys-notary" \
#         --key AuthKey.p8 --key-id <id> --issuer <issuer-uuid>
#     An App Store Connect API key is used rather than an app-specific password
#     because it needs no interactive 2FA.
#
set -euo pipefail

TEAM="6TTTJ5468H"
IDENTITY="Developer ID Application: Daniel Ghiyam ($TEAM)"
PROFILE="irys-notary"
# keychain-access-groups contains $(AppIdentifierPrefix) and can only be
# authorised by a provisioning profile. Without it the app builds and notarizes
# fine but fails at runtime with errSecMissingEntitlement the moment it touches
# the Touch-ID-gated Keychain item. build-support/Irys.provisionprofile is a
# Developer ID (MAC_APP_DIRECT) profile for com.jng011.irys; install it with:
#   cp build-support/Irys.provisionprofile \
#      ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles/
PROFILE_NAME="Irys Developer ID"
OUT="${1:-$HOME/Desktop}"
BUILD="$(mktemp -d)"

cleanup() { rm -rf "$BUILD"; }
trap cleanup EXIT

echo "==> Building Release"
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO matters: without it Xcode adds
# com.apple.security.get-task-allow, which notarization rejects outright.
xcodebuild -project glance.xcodeproj -scheme glance -configuration Release \
  -destination 'platform=macOS' -derivedDataPath "$BUILD" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM" PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED" || true

APP="$BUILD/Build/Products/Release/Irys.app"
[ -d "$APP" ] || { echo "no app produced"; exit 1; }

# Fail loudly rather than shipping an app that dies on first Touch ID prompt.
if ! codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q keychain-access-groups; then
  echo "REFUSING: keychain-access-groups missing from the signed app."
  echo "  The provisioning profile \"$PROFILE_NAME\" is probably not installed."
  exit 1
fi

echo "==> Signing Sparkle's nested helpers"
# Xcode does not descend into apps and XPC services nested inside a framework,
# so these keep Sparkle's own signature and fail notarization. Sign inside-out:
# sealing a container freezes whatever is already inside it.
SPK="$APP/Contents/Frameworks/Sparkle.framework"
for target in \
  "$SPK/Versions/B/XPCServices/Downloader.xpc" \
  "$SPK/Versions/B/XPCServices/Installer.xpc" \
  "$SPK/Versions/B/Autoupdate" \
  "$SPK/Versions/B/Updater.app" \
  "$SPK/Versions/B" \
  "$APP"
do
  [ -e "$target" ] || continue
  codesign --force --timestamp --options=runtime \
           --preserve-metadata=entitlements --sign "$IDENTITY" "$target"
  echo "    signed ${target##*/}"
done

codesign --verify --deep --strict "$APP"
echo "==> Signature verified"

echo "==> Notarizing (a few minutes)"
ZIP="$BUILD/Irys.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$APP"
spctl -a -vvv -t install "$APP"

mkdir -p "$OUT"
rm -rf "$OUT/Irys.app"
ditto "$APP" "$OUT/Irys.app"
echo "==> Done: $OUT/Irys.app"
