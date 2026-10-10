#!/bin/bash
# Renders Icon/icon_1024.png and packs it into Icon/AppIcon.icns.
set -euo pipefail
cd "$(dirname "$0")"
TMP=$(mktemp -d)
swiftc -O make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" icon_1024.png
SET="$TMP/AppIcon.iconset"; mkdir "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s icon_1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) icon_1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$TMP"
echo "Built Icon/AppIcon.icns"
