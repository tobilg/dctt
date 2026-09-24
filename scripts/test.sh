#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=26.0
swift package --disable-keychain --disable-netrc resolve
python3 scripts/harden-dependencies.py
frameworks="$(xcode-select -p)/Library/Developer/Frameworks"
swift test --disable-keychain --disable-netrc -c release --arch arm64 --jobs 4 \
    --disable-xctest --enable-swift-testing \
    -Xswiftc -F -Xswiftc "$frameworks" \
    -Xlinker -F -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$frameworks" \
    -Xlinker -rpath -Xlinker "$(xcode-select -p)/Library/Developer/usr/lib"
