# Shared by build.sh and test.sh (sourced from the repository root): pinned dependencies and the SDK.

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

# Bundled rclone: the official release for both architectures, pinned and checksum-verified, merged into one
# universal binary (a Homebrew copy only runs on the build Mac's architecture).
RCLONE_VERSION="1.75.1"
RCLONE_SHA256_ARM64="c61d7a371c62bcbbe882c3423aa4b8bf63485c248dd0f692997b8f0c3f6d0c6f"
RCLONE_SHA256_AMD64="29253d0288b8fbbac46baad6e5f6add6cb01d462c79f10805bbd4631c4cdf82c"
RCLONE_DIR=".build/vendor/rclone-$RCLONE_VERSION"
RCLONE="$RCLONE_DIR/rclone"
if [[ ! -x "$RCLONE" ]]; then
  mkdir -p "$RCLONE_DIR"
  for ARCH in arm64 amd64; do
    ZIP="$RCLONE_DIR/rclone-v$RCLONE_VERSION-osx-$ARCH.zip"
    curl -fL "https://downloads.rclone.org/v$RCLONE_VERSION/rclone-v$RCLONE_VERSION-osx-$ARCH.zip" -o "$ZIP"
    EXPECTED="RCLONE_SHA256_${ARCH:u}"
    [[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" == "${(P)EXPECTED}" ]] || { echo "rclone $ARCH checksum mismatch"; exit 1; }
    unzip -o -j -q "$ZIP" "rclone-v$RCLONE_VERSION-osx-$ARCH/rclone" -d "$RCLONE_DIR/$ARCH"
  done
  lipo -create "$RCLONE_DIR/arm64/rclone" "$RCLONE_DIR/amd64/rclone" -output "$RCLONE"
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
