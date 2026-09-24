#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/dist/dctt.app}"
test -d "$app" || { echo 'Build the app first.'; exit 1; }
report_dir="$(mktemp -d "${TMPDIR:-/tmp/}dctt-runtime.XXXXXX")"
trap 'rm -rf "$report_dir"' EXIT
open -n -W --stdout "$report_dir/stdout" --stderr "$report_dir/stderr" "$app" \
    --args --wait-runtime-check "$report_dir/result.json"
python3 - "$report_dir" <<'PY'
import json
import sys
from pathlib import Path
folder = Path(sys.argv[1])
report = folder / "result.json"
if not report.is_file():
    print((folder / "stderr").read_text() if (folder / "stderr").exists() else "No runtime report.")
    raise SystemExit("Packaged app exited without completing the runtime check.")
data = json.loads(report.read_text())
if data != {"waits_completed": True, "cancellation_observed": True}:
    raise SystemExit(f"Runtime check failed: {data}")
print("Packaged release app: asynchronous waits and cancellation passed.")
PY
