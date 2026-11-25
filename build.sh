#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="dist/Mac Proxy Filter.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun swiftc -O Sources/Mask.swift -o "$app/MacOS/MaskWorker"
xcrun swiftc -O -parse-as-library Sources/App.swift -o "$app/MacOS/MacProxyFilter"
cp proxy/*.py "$app/Resources/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacProxyFilter</string>
<key>CFBundleIdentifier</key><string>com.pmeir99.mac-proxy-filter</string>
<key>CFBundleName</key><string>Mac Proxy Filter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
codesign --force --sign - "$app/MacOS/MaskWorker"
codesign --force --sign - "${app%/Contents}"
codesign --verify --deep --strict "${app%/Contents}"
