#!/bin/bash
# Builds Floebin.app into ./build — run from Terminal:  bash build.sh
#
# Signing (picked automatically, best first):
#   1. "Developer ID Application: …"  — from your Apple Developer account (needed to share the app)
#   2. "Floebin Local"                — a free self-made certificate: macOS then remembers
#                                       Floebin's Downloads permission across rebuilds
#   3. ad-hoc                         — works on this Mac only; may ask for permission after each build
# Force one with:  FLOEBIN_SIGN_IDENTITY="Floebin Local" bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift not found. Install Xcode from the App Store, or run:  xcode-select --install"
  exit 1
fi

echo "→ Quitting any running copy"
pkill -x Floebin 2>/dev/null || true
pkill -x Floe 2>/dev/null || true

echo "→ Compiling Floebin (release)…"
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/Floebin.app"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Floebin" "$APP/Contents/MacOS/Floebin"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "→ Building app icon"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
touch "$APP"   # nudge Finder to refresh the icon

# ── Signing ─────────────────────────────────────────────
IDENTITY="${FLOEBIN_SIGN_IDENTITY:-}"
IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [ -z "$IDENTITY" ]; then
  if echo "$IDENTITIES" | grep -q "Developer ID Application"; then
    IDENTITY="$(echo "$IDENTITIES" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"
  elif security find-certificate -c "Floebin Local" >/dev/null 2>&1; then
    IDENTITY="Floebin Local"
  else
    IDENTITY="-"
  fi
fi

if [[ "$IDENTITY" == Developer\ ID* ]]; then
  echo "→ Signing with $IDENTITY (hardened runtime, ready for notarization)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
elif [ "$IDENTITY" = "-" ]; then
  echo "→ Signing ad-hoc (this Mac only)"
  echo "  Tip: create a free \"Floebin Local\" code-signing certificate so macOS stops asking"
  echo "       for Downloads access after every build — see README → Signing."
  codesign --force --sign - "$APP"
else
  echo "→ Signing with \"$IDENTITY\""
  codesign --force --sign "$IDENTITY" "$APP"
fi

echo ""
echo "✓ Built $APP"
echo "  Run it:   open $APP"
echo "  Install:  cp -R $APP /Applications/   (needed for Launch at Login)"
echo "  Share it: bash release.sh   (needs a Developer ID — see README)"
