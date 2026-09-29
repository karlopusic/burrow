#!/bin/zsh
# Prepare a signed appcast entry after a release DMG is built (Developer ID + notarized, or the self-signed identity).
# Publish the DMG under v<VERSION>, then commit appcast.xml so installed apps can see it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
DMG="dist/Burrow-$VERSION.dmg"
SPARKLE_DIR=".build/vendor/Sparkle-2.10.0"
STAGE=".build/update-feed-$VERSION"
[[ -f "$DMG" ]] || { echo "Missing $DMG"; exit 1; }
[[ -x "$SPARKLE_DIR/bin/generate_appcast" ]] || { echo "Run scripts/build.sh first"; exit 1; }
if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
  # Not notarized: allowed for the self-signed identity, never for an ad-hoc development build.
  MNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null 2>&1
  SIG="$(codesign -dv --verbose=2 "$MNT/Burrow.app" 2>&1 || true)"   # Authority= is only printed with --verbose=2
  hdiutil detach "$MNT" >/dev/null 2>&1
  if [[ "$SIG" != *"Authority="* ]]; then echo "$DMG is ad-hoc signed. Build with SIGN_ID (see RELEASING.md)."; exit 1; fi
  echo "Note: $DMG is not notarized; users confirm it once with Open Anyway."
fi
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
# The EdDSA key keeps the Keychain name from before the rename to Burrow; it matches SUPublicEDKey.
"$SPARKLE_DIR/bin/generate_appcast" \
  --account hr.push.storageboxsync --maximum-deltas 0 \
  --download-url-prefix "https://github.com/karlopusic/burrow/releases/download/v$VERSION/" \
  -o "$STAGE/appcast.xml" "$STAGE"
python3 scripts/merge_appcast.py appcast.xml "$STAGE/appcast.xml" "$VERSION"
echo "Prepared appcast.xml for v$VERSION. Publish the DMG before committing the feed."
