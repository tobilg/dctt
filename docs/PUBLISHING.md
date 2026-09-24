# Preparing public source

Public source contains generic requirements and reproducible validation commands.
Keep local reports, microphone observations, machine details and build logs in
ignored `.build/`, `reports/`, `diagnostics/` or `.private/` directories.
Keep `plans/` private. Do not copy the whole workspace into a release archive.

## Check proposed files

```sh
python3 scripts/public-source.py check
python3 -m unittest discover -s scripts/tests -v
```

The allowlist in `.public-source.json` limits the export to source, tests, scripts,
packaging, generic documentation and licenses. Review additions to that list.
Checks reject common credential patterns, personal paths/emails, selected machine
metadata, binary files, symlinks and unexpected files. They report rules and
locations without printing matched values. These heuristics do not replace a
manual review; arbitrary private prose may not match a pattern.

Upstream copyright and attribution details in `docs/licenses/` are intentionally
preserved. Public model revisions, hashes, dependency versions, bundle identifiers
and generic home-relative installation paths are necessary project information.

## Export without private history

Deleting a file does not remove earlier commits. Keep the development repository
private and create a separate public source repository from the checked working
tree. The command includes current edits and new allowlisted files; review them
first. Use your public GitHub handle and the noreply address from your GitHub
email settings:

```sh
python3 scripts/public-source.py export \
  --output dist/public-source/dctt \
  --author YOUR_GITHUB_HANDLE \
  --email YOUR_GITHUB_NOREPLY_EMAIL
```

The destination must not exist. The exporter copies only checked source files,
creates one initial commit, sets a synthetic UTC commit date, and verifies the
new history. It does not copy the old Git directory, remotes, hooks, tags, Git
configuration, logs, archives or build outputs. It does not push or change remote
visibility. Author and committer use the supplied public identity. The synthetic
date is export metadata, not a claim about when development occurred.

Check the export itself before using it:

```sh
cd dist/public-source/dctt
python3 scripts/public-source.py check --history
git log --all --format=fuller
git remote -v
```

Only this fresh repository is intended for public use. The original private
repository retains its history; do not make it public or merge its old branches
into the export. Keep any private backups outside the public source set.
