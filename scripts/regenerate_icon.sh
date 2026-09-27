#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build/AppIcon.iconset
swift scripts/make_icon.swift build/icon.png
for s in 16 32 128 256 512; do
  sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
sips -z 256 256 build/icon.png --out docs/icon.png >/dev/null
