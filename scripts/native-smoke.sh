#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
target="${1:-textedit}"
case "$target" in
    textedit|browser-input|browser-editable|terminal|iterm2) ;;
    safari-input|safari-textarea|safari-editable|safari-password|safari-switch) ;;
    chrome-input|chrome-textarea|chrome-editable|chrome-password|chrome-switch) ;;
    firefox-input|firefox-textarea|firefox-editable|firefox-password|firefox-switch) ;;
    *) echo 'Use textedit, terminal, iterm2, or {safari,chrome,firefox}-{input,textarea,editable,password,switch}.'; exit 1 ;;
esac
app="${2:-$HOME/Applications/dctt.app}"
fixture="$PWD/.build/fixtures/short.wav"
test -f "$fixture" || { echo 'Run python3 scripts/make-fixtures.py first.'; exit 1; }
test -d "$app" || { echo 'Build and install the app first.'; exit 1; }
report_dir="$(mktemp -d "${TMPDIR:-/tmp/}dctt-native-report.XXXXXX")"
trap 'rm -rf "$report_dir"' EXIT
open -n -W --stdout "$report_dir/stdout" --stderr "$report_dir/stderr" "$app" \
    --args --native-smoke "$target" "$fixture" "$report_dir/result.json"
python3 - "$report_dir" "$target" <<'PY'
import json
import sys
from pathlib import Path
folder, target = Path(sys.argv[1]), sys.argv[2]
report = folder / "result.json"
if not report.is_file():
    print((folder / "stderr").read_text() if (folder / "stderr").exists() else "No native report.")
    raise SystemExit("App exited without completing the native check; no old report was used.")
data = json.loads(report.read_text())
output = Path(".build/reports") / f"native-{target}.json"
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
print(output.read_text())
if "error" in data:
    raise SystemExit(1)
if not data.get("check_passed", False):
    raise SystemExit("The expected insertion or safety block was not verified; inspect the report.")
PY
