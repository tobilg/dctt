# Pinned dependencies and model assets

Runtime source is pinned by exact version and immutable commit in
`Package.resolved`. Dependencies are downloaded at build time, not at dictation
time. No service credentials are needed; scripts disable SwiftPM Keychain/netrc
lookup for public downloads.

| Runtime | Version / revision | Minimum upstream requirements | License |
| --- | --- | --- | --- |
| [WhisperKit / Argmax](https://github.com/argmaxinc/argmax-oss-swift/tree/1e2a163736dfa5a198e637ae44c114e1c6d5cc2d) | 1.1.0 / `1e2a163736dfa5a198e637ae44c114e1c6d5cc2d` | Swift 5.10, macOS 13 | MIT plus bundled notices |
| [FluidAudio](https://github.com/FluidInference/FluidAudio/tree/b811a61569aa02691c99b808d08ee989b630c133) | 0.16.1 / `b811a61569aa02691c99b808d08ee989b630c133` | Swift 6.0; 6.2 trait manifest, macOS 14 | Apache-2.0 plus bundled third-party notices |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts/tree/772133d9dbe800fdac0473226822994c5c162c58) | 3.1.0 / `772133d9dbe800fdac0473226822994c5c162c58` | Swift 6.2, macOS 10.15 | MIT |
| [swift-argument-parser](https://github.com/apple/swift-argument-parser/tree/6a52f3251125d74daf04fcbd5e6f08a75d074382) | 1.8.2 / `6a52f3251125d74daf04fcbd5e6f08a75d074382` | Transitive package tooling; no app product linked | Apache-2.0 |

The app's minimum remains **macOS 26.0**, arm64. The project's Apache-2.0 license,
dependency license texts, and notices are copied into `Contents/Resources/Licenses`
in the built app.

FluidAudio includes code beyond the recognition API used by dctt. Preserve its
third-party notices even when those features are not exposed by the app:

| Included code | Notice copied unchanged from the pinned FluidAudio revision |
| --- | --- |
| fastcluster / FastClusterWrapper | [BSD-2-Clause](licenses/FluidAudio-fastcluster-BSD-2-Clause.txt) |
| VBx clustering | [Apache-2.0](licenses/FluidAudio-VBx-Apache-2.0.txt) |
| Japanese text frontend and its upstream attributions | [Combined MIT, Apache-2.0 and BSD notices](licenses/FluidAudio-JapaneseG2P-NOTICES.md) |

These files originate in FluidAudio's
[`ThirdPartyLicenses`](https://github.com/FluidInference/FluidAudio/tree/b811a61569aa02691c99b808d08ee989b630c133/ThirdPartyLicenses)
directory. Upstream copyright names, addresses, and source references in license
notices must be retained. The optional NeMo binary is not linked or packaged.

## App-local patches

`scripts/harden-dependencies.py` verifies the source revisions and applies small,
idempotent changes in ignored SwiftPM checkouts. No upstream repository is changed.

- WhisperKit: its local tokenizer failure previously fell through to a network
  download even with `WhisperKitConfig.download = false`. The fallback now throws
  `tokenizerUnavailable`. Local assets are checksum-validated before loading.
- FluidAudio: disable `AppLogger`'s output in all configurations, including debug.
  The runtime has no global logger-off API. Dictation calls the in-memory array
  transcription overload and `AsrModels.loadLocal`; convenience cache/load APIs
  may download and are deliberately not called.
- KeyboardShortcuts: omit file-suffix Xcode `#Preview` declarations and replace
  `@Entry` with its ordinary `EnvironmentKey` equivalent. Those macro plugins do
  are not required for Command Line Tools builds. Global registered shortcuts
  still use the upstream Carbon implementation, without Input Monitoring.
- Resolve SwiftPM resource bundles inside `Contents/Resources` for a signed Mac
  app, retaining the normal SwiftPM lookup for command-line tools/tests.
- FluidAudio's optional NeMo text-normalization trait is disabled. SwiftPM still
  resolves its 87 MB binary artifact, but it is not linked into the app. No NeMo
  normalization or rewriting is used.

Apple's Core ML runtime can emit system-level compiler warnings independently of
the disabled recognition SDK logging. Treat locally collected logs as private.

## Selected model assets

The complete file list, exact URL, byte count, and SHA-256 (LFS) or Git blob SHA-1
(small files) are in `Sources/DcttCore/Resources/models.json`. Preparation verifies
every downloaded file; cache loading verifies every file again. Interrupted
preparation keeps verified assets for retry.

| Assets | Immutable revision | Download bytes | Model/tokenizer license |
| --- | --- | ---: | --- |
| [Argmax Whisper Small English, `openai_whisper-small.en_217MB`](https://huggingface.co/argmaxinc/whisperkit-coreml/tree/0f63a7800b00dd0226abd051b906c246e1907482/openai_whisper-small.en_217MB) | `0f63a7800b00dd0226abd051b906c246e1907482` | 221,628,466 including tokenizer | Core ML repository: MIT |
| [OpenAI Whisper Small English tokenizer/configuration](https://huggingface.co/openai/whisper-small.en/tree/e8727524f962ee844a7319d92be39ac1bd25655a) | `e8727524f962ee844a7319d92be39ac1bd25655a` | Included above | Model card metadata: Apache-2.0 |
| [FluidInference NVIDIA Parakeet TDT 0.6B v2 Core ML](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml/tree/ee09c569f73759e6d44c9bd16766f477b2b36d39) | `ee09c569f73759e6d44c9bd16766f477b2b36d39` | 464,413,247 | CC-BY-4.0, attribution: NVIDIA original model; FluidInference Core ML conversion |

Both selected variants are English-only batch recognition with model-provided
punctuation, accepting 16 kHz mono float PCM. Whisper is configured for English
transcription; Parakeet v2 is inherently English-only and does not report a
detected language. Neither adapter exposes live streaming or translation.

Model weights are downloaded directly from their pinned upstream repositories;
they are not included in the source export or app bundle. The model licenses
are separate from dctt's source license. Parakeet's
[CC-BY-4.0 license](https://creativecommons.org/licenses/by/4.0/) credits NVIDIA
for the original model and FluidInference for the Core ML conversion; dctt does
not modify the downloaded model files.
