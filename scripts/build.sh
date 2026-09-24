#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=26.0
test "$(uname -m)" = arm64 || { echo 'Apple Silicon is required.'; exit 1; }
swift package --disable-keychain --disable-netrc resolve
python3 scripts/harden-dependencies.py
swift build --disable-keychain --disable-netrc -c release --arch arm64 --jobs 4
bin="$(swift build -c release --arch arm64 --show-bin-path)"
app="$PWD/dist/dctt.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
chmod -R u+w "$app"
cp "$bin/dctt" "$app/Contents/MacOS/dctt"
cp packaging/Info.plist "$app/Contents/Info.plist"
mkdir -p "$app/Contents/Resources/Licenses"
cp docs/licenses/* "$app/Contents/Resources/Licenses/"
cp LICENSE "$app/Contents/Resources/Licenses/dctt-Apache-2.0.txt"
cp docs/DEPENDENCIES.md "$app/Contents/Resources/Licenses/DEPENDENCIES.md"
for bundle in "$bin"/*.bundle; do
    test -d "$bundle" && cp -R "$bundle" "$app/Contents/Resources/"
done
codesign --force --sign - --options runtime --entitlements packaging/dctt.entitlements "$app"
codesign --verify --strict "$app"
file "$app/Contents/MacOS/dctt"
echo "Built $app"
