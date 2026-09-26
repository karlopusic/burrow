#!/bin/zsh
# Builds "StorageBox Sync.app" and a drag-to-install DMG into dist/.
#   VERSION=1.1 scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="StorageBox Sync"
EXE="StorageBoxSync"
BUNDLE_ID="hr.push.storageboxsync"
VERSION="${VERSION:-$(cat VERSION)}"
APP="build/$NAME.app"

# macOS 27 SDK implements @State etc. as macros whose plugin ships only with full Xcode.
# With Command Line Tools alone we compile against the newest 26.x SDK instead.
if [[ -z "${SDKROOT:-}" ]]; then
  if xcodebuild -version >/dev/null 2>&1; then
    SDKROOT="$(xcrun --show-sdk-path)"
  else
    SDKROOT="$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1)"
  fi
fi
echo "SDK: $SDKROOT"

RCLONE="${RCLONE:-$(command -v rclone || true)}"
[[ -n "$RCLONE" ]] || { echo "rclone not found – brew install rclone"; exit 1; }
RCLONE="$(readlink -f "$RCLONE")"

rm -rf build dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" -target arm64-apple-macos14.0 \
  $(find Sources -name '*.swift') -o "build/$EXE-arm64"
swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" -target x86_64-apple-macos14.0 \
  $(find Sources -name '*.swift') -o "build/$EXE-x86_64"
lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"

# Icon (generated once, then committed)
if [[ ! -f Resources/AppIcon.icns ]]; then
  swift scripts/make_icon.swift build/icon.png
  mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  sips -z 256 256 build/icon.png --out docs/icon.png >/dev/null
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"

# Bundled rclone: scheduled backups never depend on Homebrew state.
cp "$RCLONE" "$APP/Contents/Resources/rclone"
chmod +x "$APP/Contents/Resources/rclone"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__EXE__/$EXE/g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature. Replace "-" with a Developer ID identity (and notarize) for public releases.
SIGN_ID="${SIGN_ID:--}"
codesign --force --sign "$SIGN_ID" "$APP/Contents/Resources/rclone"
codesign --force --sign "$SIGN_ID" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep "$APP"

STAGE=build/dmg; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/StorageBox-Sync-$VERSION.dmg" >/dev/null
echo "OK → dist/StorageBox-Sync-$VERSION.dmg"
