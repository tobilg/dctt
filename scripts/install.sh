#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$HOME/Applications/dctt.app"
test -d dist/dctt.app || { echo 'Run ./scripts/build.sh first.'; exit 1; }
if [ -e "$app" ]; then
    id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
    test "$id" = com.tobilg.dctt || { echo "Refusing to replace unrelated app: $app"; exit 1; }
    if pgrep -f "$app/Contents/MacOS/dctt" >/dev/null; then
        echo 'Quit the installed dctt from its menu before installing this build.'
        exit 1
    fi
fi
mkdir -p "$HOME/Applications"
ditto dist/dctt.app "$app"
codesign --verify --strict "$app"
open "$app" --args "$@"
echo "Installed and launched $app"
