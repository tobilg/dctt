# Validation

Run from the repository root on an Apple Silicon Mac running macOS 26 or later.
Keep machine information, measurements, diagnostics and screenshots in ignored
local report directories. This document describes procedures, not results for
a particular machine or executable.

## Automated checks

```sh
python3 scripts/public-source.py check
python3 -m unittest discover -s scripts/tests -v
./scripts/test.sh
./scripts/build.sh
./scripts/runtime-smoke.sh
```

The Swift suite exercises session state, cancellation, stale/duplicate results,
terminal control stripping, delivery guards, clipboard restoration and history
ownership. The packaged-runtime check exercises asynchronous waits and
cancellation in the actual app executable. It needs no model or privacy grants.
Source tooling tests use temporary repositories and synthetic data.

## Native checks

Install the build, explicitly prepare Parakeet, grant Accessibility, then run:

```sh
python3 scripts/make-fixtures.py
./scripts/native-smoke.sh textedit
./scripts/native-smoke.sh terminal
./scripts/native-smoke.sh iterm2
python3 scripts/browser-smoke.py
```

These checks create dedicated windows, move focus and leave test windows open.
They transcribe synthesized speech locally; they do not capture the microphone.
Browser cases cover an input, textarea, contenteditable, repeated paste, password
blocking and switching fields before delivery. Positive cases check one paste
event and expected contents. Terminal checks leave literal text unsubmitted.
Reports go to ignored `.build/reports/`. A failure is not evidence of acceptance.

For the live path, grant Microphone as well, select a working system input and
focus an empty TextEdit document. Hold the shortcut, wait for Listening, speak
a short phrase and release all keys. Confirm that text appears exactly once.
Production reports only a paste request; acceptance requires this observation.

## Offline inference measurements

After explicitly preparing the desired models:

```sh
./scripts/benchmark.sh whisper-small-en
./scripts/benchmark.sh parakeet-v2
```

The benchmark process denies networking and uses synthetic audio. Local reports
include model revision, inference timings, memory counters and fixture accuracy.
They are private by default. Synthetic accuracy does not establish human-speech
accuracy; process memory excludes separately managed Core ML services; cached
load timings are not reboot-cold measurements. Measure microphone startup and
complete release-to-paste latency separately.

## Limits and manual coverage

Validate the actual hardware, microphone, keyboard layout and destination apps
you intend to use. In particular, exercise permission revocation, device loss,
sleep/wake, lock, early key release, the recording limit, and history folder
selection/export/deletion. Native browser fixtures do not establish compatibility
with custom editors, extensions, iframes or navigation races. Terminal TUIs and
terminals embedded in other applications need separate validation.

Cross-process focus checks and event posting cannot be atomic. Clipboard
restoration can race a slow destination. Both limitations are documented in the
[usage instructions](../README.md). Never interpret a passing unit suite as
proof of native destination acceptance.

## Interface checks

Run the packaged developer UI check after building:

```sh
mkdir -p .build/reports/ui
open -n -W dist/dctt.app --args --ui-smoke "$PWD/.build/reports/ui"
```

It renders synthetic Settings, menu and recording states in native windows,
checks that the floating panel cannot take key-window status, and saves images
and a result file in the ignored directory. Cached view images can omit native
lists and composited glass; they are partial snapshots, not proof of appearance.
This is an interface check, not a
microphone, recognition, or destination-acceptance test. It uses a temporary
preferences domain and never loads user history. The ordinary native smoke
checks also verify that displaying the recording panel preserves the captured
destination before real inference and delivery.

Manually inspect light/dark appearance, Reduce Transparency, Increase Contrast,
Reduce Motion, VoiceOver, keyboard navigation, and minimum-size windows. Check
that granted permission buttons disable, pending permissions refresh, model
progress shows actual bytes, and a changed destination retains Copy recovery.
Test history search, deletion and folder changes with disposable records.

Download tests include a loopback-only Python HTTP fixture to exercise actual
URLSession byte progress, plus deterministic cancellation, corrupted assets,
cache reuse, low-space and failure cases. They do not fetch speech models.
