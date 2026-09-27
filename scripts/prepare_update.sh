#!/bin/zsh
# Prepare a signed appcast entry after a Developer ID + notarized DMG is built.
# Publish the DMG under v<VERSION>, then commit appcast.xml so installed apps can see it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
DMG="dist/StorageBox-Sync-$VERSION.dmg"
SPARKLE_DIR=".build/vendor/Sparkle-2.10.0"
STAGE=".build/update-feed-$VERSION"
[[ -f "$DMG" ]] || { echo "Missing $DMG"; exit 1; }
[[ -x "$SPARKLE_DIR/bin/generate_appcast" ]] || { echo "Run scripts/build.sh first"; exit 1; }
xcrun stapler validate "$DMG" >/dev/null
mkdir -p "$STAGE"
cp "$DMG" "$STAGE/"
"$SPARKLE_DIR/bin/generate_appcast" \
  --account hr.push.storageboxsync --maximum-deltas 0 \
  --download-url-prefix "https://github.com/karlopusic/storagebox-sync/releases/download/v$VERSION/" \
  -o "$STAGE/appcast.xml" "$STAGE"
python3 scripts/merge_appcast.py appcast.xml "$STAGE/appcast.xml" "$VERSION"
echo "Prepared appcast.xml for v$VERSION. Publish the DMG before committing the feed."
