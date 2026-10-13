#!/bin/sh
# Regenerates assets/logo.png and Resources/AppIcon.icns from scripts/make-icon.swift.
set -e
cd "$(dirname "$0")/.."
swift scripts/make-icon.swift assets/logo.png
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/logo.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/logo.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
