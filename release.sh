#!/bin/bash
# Makes a shareable Floebin DMG — run from Terminal:  bash release.sh
#
# With a "Developer ID Application" certificate (paid Apple Developer account, $99/year)
# the app and DMG are signed + notarized, so they open on any Mac without warnings.
# One-time setup for that:
#   1. Xcode → Settings → Accounts → add your Apple ID → Manage Certificates → + → "Developer ID Application".
#   2. Create an app-specific password at appleid.apple.com, then:
#        xcrun notarytool store-credentials floebin-notary \
#          --apple-id "you@example.com" --team-id "YOURTEAMID" --password "app-specific-password"
#
# Without one, you still get a DMG. macOS blocks it the first time; people allow it once via
# System Settings → Privacy & Security → Open Anyway (see README → Opening Floebin the first time).
#
# Then publish: GitHub → shahemtiaj/floebin → Releases → tag vX.Y.Z → attach the DMG.
# Every copy of Floebin sees it through Settings → General → Check for updates.
set -euo pipefail
cd "$(dirname "$0")"

PROFILE="${FLOEBIN_NOTARY_PROFILE:-floebin-notary}"
DEVID="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

bash build.sh

APP="build/Floebin.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Floebin-$VERSION.dmg"

if [ -n "$DEVID" ]; then
  echo "→ Notarizing the app (this can take a few minutes)…"
  ZIP="build/Floebin-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
fi

echo "→ Making $DMG"
rm -rf build/dmg "$DMG"
mkdir -p build/dmg
cp -R "$APP" build/dmg/
ln -s /Applications build/dmg/Applications
hdiutil create -volname "Floebin $VERSION" -srcfolder build/dmg -ov -format UDZO "$DMG" >/dev/null
rm -rf build/dmg

if [ -n "$DEVID" ]; then
  codesign --force --sign "$DEVID" "$DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo ""
  echo "✓ $DMG is signed, notarized and ready to share."
else
  echo ""
  echo "✓ $DMG is ready (not notarized — no Developer ID on this Mac)."
  echo "  On another Mac: open it once, then System Settings → Privacy & Security → Open Anyway."
  echo "  (README → Opening Floebin the first time)"
fi
echo "  Publish it: GitHub → shahemtiaj/floebin → Releases → tag v$VERSION → attach the DMG."
