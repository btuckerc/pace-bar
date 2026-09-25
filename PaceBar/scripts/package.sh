#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$SCRIPT_DIR/.."

MODE=development
IDENTITY=
VERSION=0.4.0
BUILD_NUMBER=10
APP="$PWD/dist/Pace Bar.app"

if [[ $# -gt 0 ]]; then
  if [[ "$1" != "--release" || $# -ne 9 || "$2" != "--identity" || "$4" != "--version" || "$6" != "--build-number" || "$8" != "--output" ]]; then
    printf 'usage: %s [--release --identity ID --version X.Y.Z --build-number N --output /absolute/path/Pace Bar.app]\n' "$0" >&2
    exit 2
  fi
  MODE=release
  IDENTITY=$3
  VERSION=$5
  BUILD_NUMBER=$7
  APP=$9
  [[ "$APP" = /* && "$APP" == *.app ]] || { echo 'release output must be an absolute .app path' >&2; exit 2; }
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'release version must be numeric X.Y.Z' >&2; exit 2; }
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo 'release build number must be a positive integer' >&2; exit 2; }
  [[ -n "$IDENTITY" ]] || { echo 'release identity is required' >&2; exit 2; }
  [[ ! -e "$APP" && ! -L "$APP" ]] || { echo "release output already exists: $APP" >&2; exit 2; }

  IDENTITY_LINES=$(security find-identity -v -p codesigning)
  MATCHES=0
  SELECTED_IDENTITY=
  while IFS= read -r line; do
    [[ "$line" == *'"Developer ID Application:'* ]] || continue
    hash=${line#*) }
    hash=${hash%% *}
    cert_name=${line#*\"}
    cert_name=${cert_name%\"*}
    if [[ "$hash" == "$IDENTITY" || "$cert_name" == "$IDENTITY" ]]; then
      MATCHES=$((MATCHES + 1))
      SELECTED_IDENTITY=$hash
    fi
  done <<< "$IDENTITY_LINES"
  if [[ "$MATCHES" -ne 1 ]]; then
    echo "identity must select exactly one valid Developer ID Application certificate: $IDENTITY" >&2
    exit 2
  fi
  IDENTITY=$SELECTED_IDENTITY
fi
swift build -c release --product PaceBar
BIN_DIR=$(swift build -c release --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/PaceBar" "$APP/Contents/MacOS/PaceBar"
cp ../LICENSE "$APP/Contents/Resources/CodexBar-LICENSE.txt"
ICONSET="$PWD/.build/PaceBar.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/PaceBar.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Pace Bar</string>
<key>CFBundleDisplayName</key><string>Pace Bar</string>
<key>CFBundleIdentifier</key><string>com.btuckerc.PaceBar</string>
<key>CFBundleExecutable</key><string>PaceBar</string>
<key>CFBundleIconFile</key><string>PaceBar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.0</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
<key>NSHumanReadableCopyright</key><string>Based on CodexBar by Peter Steinberger. MIT License.</string>
</dict></plist>
PLIST

if [[ "$MODE" == release ]]; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
  plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP/Contents/MacOS/PaceBar"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  codesign --verify --deep --strict "$APP"
else
  codesign --force --sign - "$APP"
  codesign --verify --strict "$APP"
fi
printf '%s\n' "$APP"
