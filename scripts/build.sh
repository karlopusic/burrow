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
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_DIR=".build/vendor/Sparkle-$SPARKLE_VERSION"
SPARKLE_ARCHIVE=".build/vendor/Sparkle-$SPARKLE_VERSION.tar.xz"

# Keep this pinned and checksum-verified. The custom swiftc build does not resolve Package.swift.
if [[ ! -d "$SPARKLE_DIR/Sparkle.framework" ]]; then
  mkdir -p "$SPARKLE_DIR"
  curl -fL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" -o "$SPARKLE_ARCHIVE"
  ACTUAL_SHA256="$(shasum -a 256 "$SPARKLE_ARCHIVE" | awk '{print $1}')"
  [[ "$ACTUAL_SHA256" == "$SPARKLE_SHA256" ]] || { echo "Sparkle archive checksum mismatch"; exit 1; }
  tar -xf "$SPARKLE_ARCHIVE" -C "$SPARKLE_DIR"
fi

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

rm -rf "$APP" "build/$EXE-arm64" "build/$EXE-x86_64" build/dmg dist
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" -target arm64-apple-macos14.0 \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  $(find Sources -name '*.swift') -o "build/$EXE-arm64"
swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" -target x86_64-apple-macos14.0 \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
  $(find Sources -name '*.swift') -o "build/$EXE-x86_64"
lipo -create "build/$EXE-arm64" "build/$EXE-x86_64" -output "$APP/Contents/MacOS/$EXE"

# Icon (generated once, then committed)
if [[ ! -f Resources/AppIcon.icns ]]; then
  zsh scripts/regenerate_icon.sh
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE_DIR/Sparkle.framework" "$APP/Contents/Frameworks/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp LICENSE THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp "$SPARKLE_DIR/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"

# Bundled rclone: scheduled backups never depend on Homebrew state.
cp "$RCLONE" "$APP/Contents/Resources/rclone"
chmod +x "$APP/Contents/Resources/rclone"

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUNDLE_ID__/$BUNDLE_ID/g" -e "s/__EXE__/$EXE/g" \
  Resources/Info.plist > "$APP/Contents/Info.plist"

# Ad-hoc signature. Replace "-" with a Developer ID identity (and notarize) for public releases.
SIGN_ID="${SIGN_ID:--}"
SIGN_FLAGS=(--force --sign "$SIGN_ID")
# Ad-hoc signatures have no Team ID, so library validation would reject the embedded Sparkle framework.
# Developer ID releases retain Hardened Runtime for notarization.
if [[ "$SIGN_ID" != "-" ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
SPARKLE_B="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_B/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$SPARKLE_B/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE_B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_FLAGS[@]}" "$APP/Contents/Resources/rclone"
codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --deep "$APP"

STAGE=build/dmg; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/StorageBox-Sync-$VERSION.dmg" >/dev/null
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "dist/StorageBox-Sync-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/StorageBox-Sync-$VERSION.dmg"
fi
echo "OK → dist/StorageBox-Sync-$VERSION.dmg"
