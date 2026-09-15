#!/bin/bash
# Signs, packages, notarizes and staples WheelClick Upgrader: build-app.sh
# produces an unsigned universal app, this script codesigns it Developer ID,
# wraps it in a dmg, submits that dmg to Apple's notary service and staples
# the ticket. It prints the dmg's sha256 and stops there — creating the
# GitHub release stays the owner's, because that publishes.
#
# Modelled on ~/Repos/PiPOSS/scripts/release.sh, with two differences forced
# by the Upgrader being a Swift package rather than an Xcode project:
#   - there is no archive/export step. `swift build` cannot set the hardened
#     runtime flag, so this script signs the already-built app directly with
#     `codesign --options runtime`, then verifies the flag is there before
#     spending Apple's time on it.
#   - the signing identity is unlocked via the private WheelClick repo's
#     dedicated signing keychain (scripts/signing-keychain.sh), not the
#     login keychain, so a build run unattended doesn't stall on a password
#     prompt. It is locked again on exit unconditionally.
#
# Every `codesign --sign` call below passes `--keychain` naming that
# dedicated keychain explicitly. Without it, codesign resolves the identity
# by name across the whole search list, and the same certificate also still
# exists in the login keychain (it was exported from there, not moved) —
# whichever keychain codesign happens to pick, the login keychain's copy
# isn't in the `-T` trusted-tools list `signing-keychain.sh setup` grants,
# so a match there prompts for the login password instead of signing
# silently. `--keychain` removes the ambiguity.
#
# Usage: Upgrader/scripts/release.sh
set -euo pipefail

cd "$(dirname "$0")/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

BUILD=.build
STAGING="$BUILD/dmg-staging"
DMG="$BUILD/WheelClick-Upgrader.dmg"
IDENTITY="Developer ID Application: Arthur Ginzburg (R2294BC6J8)"
NOTARY_KEY="$HOME/.config/wheelclick/AuthKey_3HMH55VGJD.p8"
NOTARY_KEY_ID=3HMH55VGJD
NOTARY_ISSUER=29664934-35cb-4e03-bf16-8b0be7c70353
SIGNING_KEYCHAIN="$HOME/Repos/WheelClick/scripts/signing-keychain.sh"
SIGNING_KEYCHAIN_DB="$HOME/Library/Keychains/wheelclick-signing.keychain-db"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

APP="$BUILD/app/WheelClick Upgrader.app"

echo "▸ Unlocking the signing keychain…"
"$SIGNING_KEYCHAIN" unlock
cleanup() {
  "$SIGNING_KEYCHAIN" lock
  # The app this run built and did not install: withdraw its LaunchServices
  # registration, then delete it. The dmg is kept.
  if [[ -d "$APP" ]]; then
    "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
    rm -rf "$APP"
  fi
}
trap cleanup EXIT

echo "▸ Building the unsigned universal app…"
scripts/build-app.sh

echo "▸ Signing with $IDENTITY…"
codesign --force --options runtime --timestamp --keychain "$SIGNING_KEYCHAIN_DB" --sign "$IDENTITY" "$APP"

echo "▸ Checking the signature before notarizing…"
# codesign's signing helper finishes writing the signature asynchronously, so
# a -dv run immediately after signing can occasionally read a stale (partial)
# result. `--verify` blocks until the signature is actually consistent on
# disk, so running it first makes the -dv read below reliable.
codesign --verify --strict --deep "$APP"
DV_OUTPUT=$(codesign -dv --verbose=2 "$APP" 2>&1)
if ! grep -q "Authority=Developer ID Application" <<< "$DV_OUTPUT"; then
  echo "error: the app is not Developer ID signed." >&2
  echo "$DV_OUTPUT" >&2
  exit 1
fi
if ! grep -qE "flags=0x[0-9a-f]*\(.*runtime" <<< "$DV_OUTPUT"; then
  echo "error: the hardened runtime flag is missing, so notarization would be refused." >&2
  echo "$DV_OUTPUT" >&2
  exit 1
fi

echo "▸ Building dmg…"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
rm -f "$DMG"
hdiutil create -volname "WheelClick Upgrader" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo "▸ Signing the dmg…"
codesign --force --keychain "$SIGNING_KEYCHAIN_DB" --sign "$IDENTITY" "$DMG"

echo "▸ Notarizing (waits for Apple)…"
xcrun notarytool submit "$DMG" \
  --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" \
  --wait --output-format plist > "$BUILD/notarization.plist"
NOTARY_STATUS=$(/usr/libexec/PlistBuddy -c "Print :status" "$BUILD/notarization.plist")
if [[ "$NOTARY_STATUS" != Accepted ]]; then
  SUBMISSION_ID=$(/usr/libexec/PlistBuddy -c "Print :id" "$BUILD/notarization.plist")
  echo "Notarization failed with status: $NOTARY_STATUS" >&2
  xcrun notarytool log "$SUBMISSION_ID" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" >&2 || true
  exit 1
fi

echo "▸ Stapling…"
xcrun stapler staple "$DMG"

# Read back from the file that will actually be downloaded. Stapling
# rewrites the dmg, so a hash taken before it is the hash of something else.
# `spctl` is not used as evidence anywhere here: this Mac has assessments
# disabled and prints `accepted` regardless.
xcrun stapler validate "$DMG"
SHA=$(shasum -a 256 "$DMG" | cut -d' ' -f1)

# Releases in this repo are immutable: a published asset can never be replaced, so every build
# gets its own tag. wheelclick.app/download/upgrader redirects to the newest one (landing/vercel.json
# in the private repo); bump that redirect after publishing.
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null \
  || sed -n 's:.*<key>CFBundleShortVersionString</key><string>\([^<]*\)</string>.*:\1:p' scripts/build-app.sh)

cat <<SUMMARY

▸ Done. Notarized and stapled.

    file      $PWD/$DMG
    sha256    $SHA

Still the owner's, because it publishes:

  gh release create upgrader-$VERSION -R artginzburg/WheelClick-Community \\
    --title "WheelClick Upgrader" \\
    --notes "Moves an App Store copy of WheelClick to the direct version, free. See https://wheelclick.app/upgrade" \\
    --latest=false \\
    $DMG
SUMMARY
