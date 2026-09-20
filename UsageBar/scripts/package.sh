#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product UsageBar
BIN_DIR=$(swift build -c release --show-bin-path)
APP="$PWD/dist/Usage Bar.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/UsageBar" "$APP/Contents/MacOS/UsageBar"
cp ../LICENSE "$APP/Contents/Resources/CodexBar-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Usage Bar</string>
<key>CFBundleDisplayName</key><string>Usage Bar</string>
<key>CFBundleIdentifier</key><string>com.btuckerc.UsageBar</string>
<key>CFBundleExecutable</key><string>UsageBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHumanReadableCopyright</key><string>Based on CodexBar by Peter Steinberger. MIT License.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
