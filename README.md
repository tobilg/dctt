# dctt - **d**i**ct**a**t**e

Native, local dictation for **Apple Silicon Macs running macOS 26 or later**.

Hold **Control–Option–Space**, speak, and release to transcribe on your Mac and
request one paste into the focused application. dctt lives in the menu bar and
is built with Swift, SwiftUI, AppKit, and Core ML.

- Configurable hold-to-talk shortcut and English recognition.
- Two local model families: **Parakeet** by default, with **Whisper** selectable.
- Native text insertion, including browser editors, Terminal, and iTerm2.
- Cancellation, destination checks, and Copy recovery when insertion is blocked.
- Optional transcript history in a folder you choose; no raw audio storage.

Prepared recognition works offline, without an account or hosted transcription
service. The app is intended for local personal use.

## Requirements

| Requirement | Details |
| --- | --- |
| Hardware | Apple Silicon, M1 or newer |
| Operating system | macOS 26.0 or later |
| Apple toolchain | Swift 6.2 or newer with a macOS 26 SDK |
| Build utilities | Git and Python 3 available as `git` and `python3` |
| Storage | Budget roughly 3 GB for dependencies, build products, both models, and additional Core ML caches; actual use varies |
| Network | Needed to fetch source dependencies and explicitly prepare models |

Full Xcode and a paid Apple Developer membership are not required. Python is
used by build and validation scripts; the installed app has
no Python runtime dependency. Intel and older macOS versions are unsupported.

## Build locally

### 1. Install and check the developer tools

If Apple's Command Line Tools are not installed, run:

```sh
xcode-select --install
```

Finish the macOS installation dialog, then check the available tools:

```sh
uname -m
sw_vers -productVersion
xcode-select -p
swift --version
xcrun --sdk macosx --show-sdk-version
git --version
python3 --version
```

The architecture must be `arm64`, macOS and the SDK must be 26 or newer, and
Swift must be at least 6.2. Update the developer tools if necessary. Install
Python 3 if the `python3` command is unavailable.

### 2. Get the source

```sh
git clone https://github.com/tobilg/dctt.git
cd dctt
```

If you already have a checkout, open a terminal in its root directory instead.
Run the remaining commands from that directory.

### 3. Build and validate

```sh
./scripts/build.sh
./scripts/test.sh
./scripts/runtime-smoke.sh
```

The build script resolves pinned dependencies, applies the reviewed offline,
privacy, and toolchain compatibility patches, builds an **arm64 release** with a
**macOS 26.0 deployment target**, and packages and locally signs:

```text
dist/dctt.app
```

Use the build script so the dependency patches and packaged resources are
included. Dependencies are pinned in [Package.swift](Package.swift) and
[Package.resolved](Package.resolved).

The test script runs the release test suite. The runtime smoke check briefly
launches the packaged app to verify asynchronous waits and cancellation with
its actual linked dependencies. Neither check requires models or privacy grants.

## Install locally

If dctt is already running, choose **Quit dctt** from its menu first. Then run:

```sh
./scripts/install.sh
```

The installer copies the build to **`~/Applications/dctt.app`**, verifies its
signature, and launches it. It refuses to replace an unrelated app at that path.
The app identifier and preferences domain are `com.tobilg.dctt`. For an earlier
build with a different identifier, follow the upgrade instructions below.
Look for the microphone icon in the macOS menu bar.

To launch it again later:

```sh
open ~/Applications/dctt.app
```

## First-time setup

The setup checklist opens on the first launch when access or a model is missing.
You can skip it and reopen it from **Settings → General → Open setup checklist**.

1. Click **Allow Microphone** and accept the macOS prompt.
2. Click **Allow Accessibility**. In **System Settings → Privacy & Security →
   Accessibility**, add and enable `~/Applications/dctt.app`. Use Command–Shift–G
   in the file picker to enter that path. macOS requires your approval.
3. Open **Settings → Models** and click **Download** on the recommended Parakeet
   card, or choose Whisper. Wait until the card shows **Active**.
4. Select a working microphone in **System Settings → Sound → Input**. dctt uses
   the system-default input, including an iPhone microphone when available there.
5. Focus an empty TextEdit document. Hold **Control–Option–Space**, wait for
   **Listening**, say a short phrase, and release all keys.
6. If the text appears exactly once, return to the checklist and click
   **Text appeared once**. This is your confirmation of destination acceptance.

Allowed permissions show a checkmark and disabled buttons. dctt refreshes access
when Settings opens, when the app becomes active, and for up to three minutes
after requesting a grant. **Settings → Advanced → Refresh permissions** checks
again manually.

## Settings and the menu

The menu bar popover shows readiness, your shortcut and model, and **Copy latest**.
Transcript text stays hidden until you open **Show latest transcript**; the
preview closes when the popover closes. **Clear** removes the latest result from
memory. Saved history is managed separately.

The resizable Settings window has four pages:

- **General:** hold-to-talk shortcut, basic cleanup, single-line output and setup.
- **Models:** local model downloads, activation and repair.
- **Privacy & History:** permission status, optional saving and folder selection.
- **Advanced:** clipboard restoration, performance timings and troubleshooting.

The recording panel uses native Liquid Glass and stays above your destination
without taking keyboard focus. It shows real audio levels, elapsed time and
Cancel. Its phases are **Starting microphone**, **Listening**, **Transcribing**,
and **Paste requested**; it also indicates a wait for held shortcut modifiers.
A paste request dismisses after two seconds. When delivery is blocked, the panel
keeps **Copy text** and Dismiss available. Starting another recording replaces it;
there is no automatic paste retry. System appearance, contrast, transparency and
motion preferences are respected.

## Model downloads

Speech models are downloaded separately from the app. Building or installing
dctt does not download them. In **Settings → Models**, click **Download** on a
model card to download, verify and activate it explicitly. **Use model** verifies
and activates files already on disk without downloading. **Repair** or **Retry
download** explicitly fetches missing or damaged files.

| Model | Default | Approximate download |
| --- | --- | ---: |
| Parakeet v2 English | Yes | 464 MB |
| Whisper Small English | No | 222 MB |

Whisper files come from the Hugging Face repository
`argmaxinc/whisperkit-coreml`; Parakeet files come from
`FluidInference/parakeet-tdt-0.6b-v2-coreml`. The bundled
[model catalog](Sources/DcttCore/Resources/models.json) pins exact revisions,
download URLs, expected file sizes, and checksums. dctt does not automatically
follow newer upstream model releases.

During preparation, the app:

1. Checks existing files and reuses those with the expected size and checksum.
2. Downloads missing or damaged files one at a time into temporary storage.
3. Verifies each downloaded file before moving it into the selected model's
   folder. A failed download or integrity check stops preparation with an error.
4. Validates the complete model and loads it locally. Wait for loading to finish
   before dictating; Core ML may create additional caches on the first load.

Progress separates **Checking files**, **Downloading**, **Verifying**, and
**Preparing model**. During downloads, the byte counter and progress bar show
actual received bytes against the total needed for missing or damaged files;
verified cached files are excluded. Verification and model loading use an
indeterminate indicator, not an estimated percentage or time remaining.

Use **Cancel** to stop preparation. Verified files remain available for retry;
interrupted files restart from the beginning. There is no persistent partial-file
resume or application-level automatic retry loop. Core ML loading may need to
finish before cancellation completes; a cancelled load is never marked Active.
Other model operations remain disabled until the current operation finishes.

Models are stored under:

```text
~/Library/Application Support/dctt/Models/
├── parakeet-v2/
└── whisper-small-en/
```

Only models you prepare occupy these folders. Allow room for temporary downloads
and Core ML caches in addition to the sizes above. If preparation reports a
network, integrity, or disk-space error, resolve it and use Repair or Retry download
again.

Launching dctt or selecting a model checks its local files without downloading.
Missing or damaged assets require explicit repair. After preparation, loading
and recognition work offline; audio and transcripts are not sent to Hugging Face
or a transcription service. One model is kept ready at a time, and both included
variants support English.

### Prepare models from the command line

After building, quit dctt before using the development helper. To prepare the
default Parakeet model:

```sh
.build/arm64-apple-macosx/release/dctt-check prepare parakeet-v2
```

For Whisper instead, run:

```sh
.build/arm64-apple-macosx/release/dctt-check prepare whisper-small-en
```

These commands download or repair, validate, and load the chosen model using the
same default storage as the app. Relaunch dctt and click **Use model** on its card in
Settings → Models.

## Using dctt

Change the shortcut in Settings → General. Recording stops when you release it, select
**Stop and transcribe**, or reach the 120-second limit. **Cancel** stops the
session and prevents its late result from being inserted. Cancellation cannot
undo a paste that has already been requested.

The app reports **Paste requested** because sending Command–V does not prove that
the destination accepted the text. **Copy latest** keeps the latest
completed result available in memory even when history is disabled.

Changing apps, windows, or fields can block insertion. Safari, Chrome, and Firefox
require a recognizable focused text field and window. Inaccessible browser
editors fall back to Copy; other apps use their available Accessibility identities.
Password fields and Secure Keyboard Entry are unsupported. Moving the caret
within the same field changes the insertion point.

Terminal and iTerm2 receive literal single-line text with embedded newlines and
control characters removed or replaced. dctt never presses Enter or executes
recognized text. Review dictated commands before submitting them yourself.

Conservative cleanup preserves wording, punctuation, case, and numbers. Optional
single-line mode also applies to ordinary editors. Clipboard restoration is off
by default. When enabled, it restores after one second only while dctt still owns
the clipboard; slow destinations may miss that interval. Clipboard snapshots
larger than 8 MB are not restored.

## History and privacy

History is **off by default**. Enable it in Settings → Privacy & History and choose a folder to store
completed transcripts with minimal time, model, destination-app, and delivery
metadata. The History window groups transcripts by date and shows the selected
record in a detail pane with Copy, Export, and Delete. Search matches transcript
text and destination app names within the loaded recent records, up to 200 from
the final 4 MiB of the file; it does not search the entire archive. Delete all
requires confirmation. Changing the folder leaves existing history in its
previous location.

| Data | Default location |
| --- | --- |
| Prepared models | `~/Library/Application Support/dctt/Models/` |
| Optional history | `~/Library/Application Support/dctt/History/` |
| Preferences | macOS defaults domain `com.tobilg.dctt` |

Runtime audio stays in memory. dctt does not save raw recordings, surrounding
document text, window titles, or clipboard snapshots. Transcript logging in the
recognition SDKs is disabled. History uses `dctt-history-v1.jsonl`, with bounded
recent reads. An unavailable history folder leaves the latest transcript
available to Copy. Clipboard managers and folders you choose to sync have their
own storage behavior.

## Updating and troubleshooting

To replace the installed app, quit dctt and repeat the build, validation, and
installation commands above. The app uses an ad hoc local signature: a changed
executable can invalidate its macOS grants even when old Settings toggles remain
enabled. Permission resets are separate recovery steps, not part of the scripts.

### Upgrading from a build with a different app identifier

The installer only replaces an app whose identifier is `com.tobilg.dctt`.
If it refuses an earlier dctt build, export any history you want through that
build first, quit it, and move its app bundle out of `~/Applications/dctt.app`
to a backup location. Then run the installer and complete first-time setup.

Preferences, the shortcut, and macOS permission grants do not transfer from a
different app identity. Prepared models remain reusable in the same model
folder. Older history files are preserved but are not automatically imported:
keep the old folder and choose a new empty folder before enabling history in
this build. The app refuses to overwrite history with a different ownership
header.

### Accessibility is enabled but dctt still reports it missing

Quit dctt. Remove its old Accessibility row with **−**, then use **+** to add and
enable **`~/Applications/dctt.app`**. Relaunch the installed app.

If the stale entry persists, quit the app and reset only its Accessibility grant:

```sh
tccutil reset Accessibility com.tobilg.dctt
```

Then add and enable the installed app again. This clears approval; only you can
grant it through macOS.

### Microphone permission or input is unavailable

Use **Settings → Allow Microphone**. After quitting dctt, you can also open the
same permission flow directly:

```sh
open ~/Applications/dctt.app --args --request-microphone
```

If a stale microphone grant persists after rebuilding, quit dctt, run
`tccutil reset Microphone com.tobilg.dctt`, and request access again. A denied
request opens Microphone settings for you to approve it.

If access is allowed but no audio arrives, check the device and input level in
macOS Sound settings. Input devices can take time to start; wait for **Listening**
before speaking.

### Recognition finished but nothing was inserted

Use **Copy latest**. Keep the intended field focused and release all
shortcut modifiers. Holding modifiers for over 1.5 seconds after recognition
falls back to Copy. Some custom controls reject simulated paste or do not expose
enough Accessibility information for safe automatic insertion.

## Validation and development

The automated suite covers session cancellation, duplicate insertion prevention,
terminal text handling, clipboard ownership, and transcript history. Native
checks exercise local inference and destination acceptance separately. Run them
on the build and applications you intend to use; the public source contains no
machine-specific validation reports or benchmark results.

To run native checks after preparing Parakeet and granting Accessibility:

```sh
python3 scripts/make-fixtures.py
./scripts/native-smoke.sh textedit
python3 scripts/browser-smoke.py
```

These checks create disposable documents and browser pages, move focus, and leave
test windows open for inspection. They use synthesized audio with real model
inference and do not record the microphone. Other targets include `terminal`,
`iterm2`, and individual browser scenarios such as `firefox-textarea`.

For offline benchmarks, prepare the corresponding models and generate fixtures
as above, then run:

```sh
./scripts/benchmark.sh whisper-small-en
./scripts/benchmark.sh parakeet-v2
```

Development fixtures live in ignored `.build/fixtures/`; runtime dictation does
not write audio there. Optional permission and timing diagnostics can be enabled
after quitting the app with
`open ~/Applications/dctt.app --args --diagnostics-file /tmp/dctt-status.json`.
Diagnostics contain no transcript text. Relaunch normally to stop them.

- [Validation instructions and limitations](docs/VALIDATION.md)
- [Pinned dependencies, models, and licenses](docs/DEPENDENCIES.md)
- [Preparing a public source copy](docs/PUBLISHING.md)

Hardware configurations, microphones, custom website editors, and terminal TUIs
need their own native testing. Live preview,
model-based rewriting, spoken commands, multilingual variants, and launch at
login are deferred. App Store distribution is outside the project's scope.

## License

dctt source is licensed under [Apache-2.0](LICENSE). Dependencies and separately
downloaded models retain their own licenses; see [the license inventory](docs/DEPENDENCIES.md).
