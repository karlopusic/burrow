#!/bin/zsh
# Unit tests (no network): builds Tests/*.swift together with the app sources, minus the app's entry point, and
# runs them in a throw-away home folder.
#   scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

source scripts/toolchain.sh

mkdir -p build
swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" -target "$(uname -m)-apple-macos14.0" \
  -F "$SPARKLE_DIR" -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/$SPARKLE_DIR" \
  $(find Sources -name '*.swift' ! -name BurrowApp.swift) Tests/*.swift -o build/UnitTests

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
CFFIXED_USER_HOME="$TEST_HOME" build/UnitTests
