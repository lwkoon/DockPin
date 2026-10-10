#!/bin/bash
# Builds DockPin.app (universal binary, ad-hoc signed). Pass --install to copy into /Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/DockPin.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos13.0 \
    -framework Cocoa -framework ServiceManagement \
    Sources/main.swift -o build/DockPin-$arch
done
lipo -create build/DockPin-arm64 build/DockPin-x86_64 -output "$APP/Contents/MacOS/DockPin"
rm build/DockPin-arm64 build/DockPin-x86_64

cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>DockPin</string>
  <key>CFBundleDisplayName</key><string>DockPin</string>
  <key>CFBundleIdentifier</key><string>com.edonesolutions.dockpin</string>
  <key>CFBundleExecutable</key><string>DockPin</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppSleepDisabled</key><true/>
  <key>NSHumanReadableCopyright</key><string>Eddie Lim</string>
</dict></plist>
PLIST

codesign --force --sign - --identifier com.edonesolutions.dockpin "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x DockPin || true
  rm -rf /Applications/DockPin.app
  cp -R "$APP" /Applications/
  open /Applications/DockPin.app
  echo "Installed to /Applications/DockPin.app"
fi
