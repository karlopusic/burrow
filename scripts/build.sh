#!/bin/zsh
# Builds "Burrow.app" and a drag-to-install DMG into dist/.
#   VERSION=1.1 scripts/build.sh
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="Burrow"
EXE="Burrow"
BUNDLE_ID="hr.push.burrow"
VERSION="${VERSION:-$(cat VERSION)}"
APP="build/$NAME.app"

source scripts/toolchain.sh   # SDKROOT, pinned Sparkle and universal rclone

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

# Signing identity:
#   "-" (default)             ad-hoc, for development. macOS treats every build as a new app.
#   a self-signed certificate  stable identity without an Apple account: folder permissions and Keychain access
#                              survive updates, but Gatekeeper still asks users to confirm the first launch.
#   "Developer ID Application: …"  public release; signed with Hardened Runtime and notarized (RELEASING.md).
SIGN_ID="${SIGN_ID:--}"
SIGN_FLAGS=(--force --sign "$SIGN_ID")
# Hardened Runtime enforces library validation, which needs a Team ID on both the app and Sparkle – only Developer ID
# certificates have one. Notarization requires it, so it is on exactly for Developer ID builds.
if [[ "$SIGN_ID" == "Developer ID Application:"* ]]; then SIGN_FLAGS+=(--options runtime --timestamp); fi
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
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "dist/Burrow-$VERSION.dmg" >/dev/null
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "dist/Burrow-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "dist/Burrow-$VERSION.dmg"
fi
echo "OK → dist/Burrow-$VERSION.dmg"
