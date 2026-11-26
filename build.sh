#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="dist/Mac Proxy Filter.app/Contents"
mkdir -p "$app/MacOS" "$app/Resources" "$app/Helpers"
if [[ "$(uname -m)" != arm64 ]]; then
  echo "Build this Apple silicon release on an arm64 Mac." >&2
  exit 1
fi
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
# The upstream Apple silicon bundle contains the engine and its private runtime.
# Keep the nested signature, relative framework paths and symbolic links intact.
version=12.3.1
archive="$stage/mitmproxy.tar.gz"
curl --fail --location --retry 3 --output "$archive" \
  "https://downloads.mitmproxy.org/$version/mitmproxy-$version-macos-arm64.tar.gz"
echo "9b7f7a8e3fd1b1544089c937c579ef1f0f503f0ea598c25bda9eab077c735b93  $archive" | shasum -a 256 -c -
tar -xzf "$archive" -C "$stage"
engine="$stage/mitmproxy.app"
test -x "$engine/Contents/MacOS/mitmdump"
codesign --verify --deep --strict "$engine"
# Replace the previous staged runtime as a unit on incremental builds.
rm -rf "$app/Helpers/mitmproxy.app"
ditto "$engine" "$app/Helpers/mitmproxy.app"
cp licenses/mitmproxy.txt "$app/Resources/mitmproxy-LICENSE.txt"
curl -fsSL --retry 3 'https://ml-assets.apple.com/coreml/models/Image/ImageSegmentation/DeepLabV3/DeepLabV3FP16.mlmodel' -o "$stage/DeepLabV3FP16.mlmodel"
echo "6c2c8cbe1c2d765f231408458b8c273976039ae04a05b112d748fc21cb3bfe95  $stage/DeepLabV3FP16.mlmodel" | shasum -a 256 -c -
xcrun coremlcompiler compile "$stage/DeepLabV3FP16.mlmodel" "$app/Resources"
export MACOSX_DEPLOYMENT_TARGET=14.0
xcrun swiftc -O Sources/Mask.swift -o "$app/MacOS/MaskWorker"
xcrun swiftc -O -parse-as-library Sources/App.swift Sources/NetworkSetup.swift Sources/Interface.swift Sources/Updates.swift -o "$app/MacOS/MacProxyFilter"
mkdir -p "$stage/Filter.iconset"
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    suffix=""; [[ $scale == 1 ]] || suffix="@2x"
    sips -z "$((size*scale))" "$((size*scale))" artwork/Filter.png --out "$stage/Filter.iconset/icon_${size}x${size}${suffix}.png" >/dev/null
  done
done
iconutil -c icns "$stage/Filter.iconset" -o "$app/Resources/Filter.icns"
cp install-update.sh "$app/Resources/"
cp proxy/*.py "$app/Resources/"
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MacProxyFilter</string>
<key>CFBundleIdentifier</key><string>com.pmeir99.mac-proxy-filter</string>
<key>CFBundleIconFile</key><string>Filter.icns</string>
<key>CFBundleName</key><string>Mac Proxy Filter</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>2</string>
<key>CFBundleShortVersionString</key><string>0.1.6</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Add :FilterRelease string v0.1.6-preview.${RELEASE_NUMBER:-0}" "$app/Info.plist"
codesign --force --sign - "$app/MacOS/MaskWorker"
codesign --force --sign - "${app%/Contents}"
codesign --verify --deep --strict "${app%/Contents}"
