#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
model="${1:-whisper-small-en}"
model_root="${2:-$HOME/Library/Application Support/dctt/Models}"
test -f .build/fixtures/maximum.wav || python3 scripts/make-fixtures.py
mkdir -p .build/reports
bin="$PWD/.build/arm64-apple-macosx/release/dctt-check"
# Deny networking only for this child process, without changing the Mac's Wi-Fi.
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    "$bin" benchmark "$model" "$model_root" "$PWD/.build/fixtures" "$PWD/.build/reports/$model.json"
echo "Offline benchmark report: .build/reports/$model.json"
