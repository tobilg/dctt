"""Regression tests for privacy boundaries using disposable synthetic repositories."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "public-source.py"
spec = importlib.util.spec_from_file_location("public_source", SCRIPT)
public = importlib.util.module_from_spec(spec)
spec.loader.exec_module(public)
HANDLE = "example-contributor"
SAFE_EMAIL = HANDLE + "@users.noreply.github.com"
PRIVATE_EMAIL = "private-person" + "@" + "personal.invalid"


class PrivacyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="dctt-public-test-")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.root = self.base / "source"
        self.root.mkdir()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
        self.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME=HANDLE, GIT_AUTHOR_EMAIL=SAFE_EMAIL,
                        GIT_COMMITTER_NAME=HANDLE, GIT_COMMITTER_EMAIL=SAFE_EMAIL,
                        GIT_AUTHOR_DATE=public.EXPORT_DATE, GIT_COMMITTER_DATE=public.EXPORT_DATE,
                        TZ="UTC")
        self.git("init", "--quiet", "--initial-branch=main", "--template=")
        self.write(".gitignore", ".private/\ndist/\nreports/\n")
        self.write("README.md", "# Example source\n")
        self.write("scripts/public-source.py", SCRIPT.read_text())
        self.write(".githooks/pre-commit", '#!/bin/sh\nexec python3 scripts/public-source.py check --staged\n')
        (self.root / ".githooks/pre-commit").chmod(0o755)
        self.write(".public-source.json", json.dumps({
            "files": [".gitignore", ".public-source.json", ".githooks/pre-commit", "README.md"],
            "trees": {"scripts": [".py"], "Sources": [".swift"], "docs/licenses": [".txt"]},
            "required": ["README.md", ".public-source.json"],
        }))

    def git(self, *args, env=None):
        return public.git(self.root, *args, env=env or self.env)

    def write(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value)
        return path

    def commit(self):
        self.git("add", "--all")
        self.git("-c", "core.hooksPath=/dev/null", "commit", "--quiet", "-m", "Synthetic private history")

    def test_private_data_is_rejected_without_echoing_it(self):
        token = "ghp_" + "A" * 36
        home = "/" + "Users" + "/synthetic-person/file"
        private_key = "-----BEGIN " + "PRIVATE KEY-----"
        for payload in (token, home, private_key, PRIVATE_EMAIL):
            issues = public.inspect_bytes("README.md", payload.encode())
            self.assertTrue(issues)
            self.assertNotIn(payload, "\n".join(issues))
        self.assertTrue(public.inspect_bytes("README.md", ("Mac" + " mini").encode()))
        self.assertTrue(public.inspect_bytes("README.md", ("workstation" + ".local").encode()))
        self.assertFalse(public.inspect_bytes("README.md", b".env.local"))

    def test_dependency_hashes_requirements_and_upstream_attributions_are_kept(self):
        ordinary = "Apple Silicon M1+, macOS 26.0, ~/Applications/dctt.app\n" + "a" * 64
        self.assertFalse(public.inspect_bytes("README.md", ordinary.encode()))
        self.assertFalse(public.inspect_bytes("docs/licenses/upstream.txt", PRIVATE_EMAIL.encode()))
        self.assertTrue(public.inspect_bytes("docs/licenses/upstream.txt", ("ghp_" + "B" * 36).encode()))

    def test_ignored_private_reports_stay_out_but_tracked_reports_fail(self):
        self.write(".private/notes.md", PRIVATE_EMAIL)
        self.write("reports/local.json", "{}")
        names, issues = public.inspect_worktree(self.root)
        self.assertFalse(issues)
        self.assertNotIn(".private/notes.md", names)
        self.git("add", "-f", "reports/local.json")
        self.assertTrue(public.inspect_worktree(self.root)[1])

    def test_symlink_and_binary_files_are_rejected(self):
        (self.root / "Sources").mkdir()
        target = self.base / "private.txt"
        target.write_text("Private prose")
        (self.root / "Sources/Leak.swift").symlink_to(target)
        issues = public.inspect_worktree(self.root)[1]
        self.assertTrue(any("symlink" in issue for issue in issues))
        self.assertTrue(public.inspect_bytes("Sources/Blob.swift", b"text\0binary"))

    def test_required_source_cannot_be_silently_omitted(self):
        (self.root / "README.md").unlink()
        self.assertTrue(any("required" in issue for issue in public.inspect_worktree(self.root)[1]))

    def test_history_detects_deleted_private_content(self):
        self.write("README.md", PRIVATE_EMAIL)
        self.commit()
        self.write("README.md", "# Clean working tree\n")
        self.commit()
        self.assertFalse(public.inspect_worktree(self.root)[1])
        self.assertTrue(any("personal email" in issue for issue in public.inspect_history(self.root)))

    def test_identity_requires_public_handle_noreply_and_utc(self):
        self.assertFalse(public.inspect_identity(f"{HANDLE} <{SAFE_EMAIL}> 1000 +0000"))
        self.assertTrue(public.inspect_identity(f"{HANDLE} <{PRIVATE_EMAIL}> 1000 +0000"))
        self.assertTrue(public.inspect_identity(f"Private Name <{SAFE_EMAIL}> 1000 +0000"))
        self.assertTrue(public.inspect_identity(f"{HANDLE} <{SAFE_EMAIL}> 1000 +0100"))

    def test_export_has_only_fresh_history_and_never_overwrites(self):
        self.write("README.md", PRIVATE_EMAIL)
        self.commit()
        self.git("remote", "add", "origin", "https://example.org/private-source.git")
        self.git("tag", "private-tag")
        self.write("README.md", "# Public source\n")
        self.write(".private/notes.md", PRIVATE_EMAIL)
        self.write("dist/local-output.txt", "Private build output")
        before = self.git("rev-parse", "HEAD")
        target = self.base / "public"
        public.export_source(self.root, target, HANDLE, SAFE_EMAIL)
        self.assertEqual(public.git(target, "rev-list", "--count", "--all").strip(), b"1")
        self.assertFalse(public.git(target, "remote").strip())
        self.assertFalse(public.git(target, "tag").strip())
        self.assertFalse(public.inspect_history(target))
        self.assertFalse((target / ".private").exists())
        self.assertFalse((target / "dist").exists())
        self.assertEqual(public.git(target, "config", "core.hooksPath").strip(), b".githooks")
        self.assertTrue(os.access(target / ".githooks/pre-commit", os.X_OK))
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.assertEqual(self.git("tag").strip(), b"private-tag")
        with self.assertRaisesRegex(ValueError, "already exists"):
            public.export_source(self.root, target, HANDLE, SAFE_EMAIL)

    def test_hook_checks_index_even_when_worktree_was_cleaned(self):
        self.write("README.md", PRIVATE_EMAIL)
        self.git("add", "--all")
        self.write("README.md", "# Clean working tree\n")
        run = subprocess.run(["python3", "scripts/public-source.py", "check", "--staged"],
                             cwd=self.root, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(run.returncode, 0)
        self.assertIn("personal email", run.stdout)
        self.assertNotIn(PRIVATE_EMAIL, run.stdout + run.stderr)

    def test_gitignore_covers_local_credentials_recordings_and_reports(self):
        shutil.copyfile(SCRIPT.parents[1] / ".gitignore", self.root / ".gitignore")
        for name in (".private/report.md", "docs/browser-checks/run.json", "docs/benchmarks/run.json",
                     "docs/native-checks/run.json", "reports/run.json", "diagnostics/status.json",
                     ".env", ".env.local", "recording.wav", "credential.pem", "dctt-history-v1.jsonl"):
            self.assertTrue(self.git("check-ignore", "--no-index", name).strip(), name)


class PackagingTests(unittest.TestCase):
    def test_installer_and_history_use_current_app_identity(self):
        root = SCRIPT.parents[1]
        identity = plistlib.loads((root / "packaging/Info.plist").read_bytes())["CFBundleIdentifier"]
        self.assertEqual(identity, "com.tobilg.dctt")
        self.assertIn('test "$id" = ' + identity, (root / "scripts/install.sh").read_text())
        self.assertIn(identity, (root / "Sources/DcttCore/History.swift").read_text())


if __name__ == "__main__":
    unittest.main()
