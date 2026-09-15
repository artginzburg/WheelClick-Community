#!/bin/bash
# Builds "WheelClick Upgrader.app" (unsigned) at Upgrader/.build/app/.
# Signing and notarization happen in the release step, on this exact path.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build -c release --arch arm64 --arch x86_64 --product WheelClickUpgrader
bin="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/WheelClickUpgrader"

app=".build/app/WheelClick Upgrader.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/WheelClick Upgrader"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key><string>art.ginzburg.WheelClick.Upgrader</string>
	<key>CFBundleName</key><string>WheelClick Upgrader</string>
	<key>CFBundleDisplayName</key><string>WheelClick Upgrader</string>
	<key>CFBundleExecutable</key><string>WheelClick Upgrader</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>13.0</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
echo "$PWD/$app"
