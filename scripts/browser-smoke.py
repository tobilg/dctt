#!/usr/bin/env python3
"""Run the native browser matrix; keep failures and repeat-paste results visible."""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[1]
browsers = sys.argv[1:] or ["safari", "chrome", "firefox"]
if any(browser not in {"safari", "chrome", "firefox"} for browser in browsers):
    raise SystemExit("Use safari, chrome, and/or firefox, or no arguments for all three.")
results = []
report_dir = root / ".build/reports/browser-matrix"
report_dir.mkdir(parents=True, exist_ok=True)
for browser in browsers:
    for number, field in enumerate(["input", "textarea", "editable", "textarea", "password", "switch"], 1):
        target = f"{browser}-{field}"
        report = root / f".build/reports/native-{target}.json"
        # Only this runner's generated report; prevent stale data after a crash.
        report.unlink(missing_ok=True)
        run = subprocess.run([str(root / "scripts/native-smoke.sh"), target], cwd=root,
                             capture_output=True, text=True)
        data = json.loads(report.read_text()) if report.exists() else {"error": "No fresh native report"}
        data["runner_exit_code"] = run.returncode
        data["matrix_sequence"] = number
        (report_dir / f"{browser}-{number}-{field}.json").write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
        passed = run.returncode == 0 and data.get("check_passed") is True
        results.append({"target": target, "sequence": number, "passed": passed})
        print(f"{target} ({number}/6): {'PASS' if passed else 'FAIL'} "
              f"{data.get('block_reason', '')} {data.get('error', '')}", flush=True)
        if "Accessibility permission is required" in data.get("error", ""):
            raise SystemExit("Grant Accessibility to the installed build before running the matrix.")
(report_dir / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
raise SystemExit(0 if all(item["passed"] for item in results) else 1)
