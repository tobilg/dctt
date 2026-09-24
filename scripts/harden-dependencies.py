#!/usr/bin/env python3
"""Idempotent, fail-closed patches against Package.resolved's exact sources.

WhisperKit's download:false does not disable tokenizer network fallback.
FluidAudio's logging has no global off switch. Disable its logger before any
model or transcript is processed, in release AND debug builds.
"""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1] / '.build/checkouts'
project = Path(__file__).resolve().parents[1]
for package, revision in {
    'argmax-oss-swift': '1e2a163736dfa5a198e637ae44c114e1c6d5cc2d',
    'FluidAudio': 'b811a61569aa02691c99b808d08ee989b630c133',
    'KeyboardShortcuts': '772133d9dbe800fdac0473226822994c5c162c58',
}.items():
    actual = subprocess.check_output(['git', '-C', str(root / package), 'rev-parse', 'HEAD'], text=True).strip()
    assert actual == revision, f'{package}: refusing patches for unreviewed revision {actual}'

# Keep notices synchronized with the same immutable sources being compiled.
for upstream, bundled in [
    ('argmax-oss-swift/LICENSE', 'WhisperKit-MIT.txt'),
    ('argmax-oss-swift/NOTICES', 'WhisperKit-NOTICES.txt'),
    ('FluidAudio/LICENSE', 'FluidAudio-Apache-2.0.txt'),
    ('FluidAudio/ThirdPartyLicenses/fastcluster-LICENSE.md', 'FluidAudio-fastcluster-BSD-2-Clause.txt'),
    ('FluidAudio/ThirdPartyLicenses/JapaneseG2P-LICENSE.md', 'FluidAudio-JapaneseG2P-NOTICES.md'),
    ('FluidAudio/ThirdPartyLicenses/vbx-LICENSE.md', 'FluidAudio-VBx-Apache-2.0.txt'),
    ('swift-argument-parser/LICENSE.txt', 'swift-argument-parser-Apache-2.0.txt'),
]:
    notice = project / 'docs/licenses' / bundled
    if not notice.is_file() or notice.read_bytes() != (root / upstream).read_bytes():
        raise SystemExit(f'Missing or changed upstream license notice: {bundled}')

def update(path, text):
    if not path.exists() or path.read_text() != text:
        if path.exists(): path.chmod(0o644)
        path.write_text(text)
path = root / 'argmax-oss-swift/Sources/WhisperKit/Utilities/ModelUtilities.swift'
text = path.read_text()
start = text.index('        // Fallback to downloading from the Hub')
end = text.index('\n    }', start)
replacement = '''        // Fallback to downloading from the Hub is forbidden by dctt.
        throw WhisperError.tokenizerUnavailable()'''
text = text[:start] + replacement + text[end:]
update(path, text)

path = root / 'FluidAudio/Sources/FluidAudio/Shared/AppLogger.swift'
text = path.read_text()
start = text.index('    private func log(_ level: Level, _ message: String) {')
end = text.index('\n    private func logToConsole(', start)
text = text[:start] + '''    private func log(_ level: Level, _ message: String) {
        // dctt: no SDK diagnostics may persist recognized text or tokens.
    }
''' + text[end:]
update(path, text)
print('Applied offline-tokenizer and transcript-privacy patches.')

# Command Line Tools ships SwiftUI but not Xcode's design-time preview macro.
for path in (root / 'KeyboardShortcuts/Sources').rglob('*.swift'):
    repo = root / 'KeyboardShortcuts'
    text = subprocess.check_output(['git', '-C', str(repo), 'show', 'HEAD:' + str(path.relative_to(repo))], text=True)
    if '\n#Preview' not in text:
        continue
    # All pinned preview declarations are file-suffix UI-only samples.
    start = text.index('\n#Preview')
    text = text[:start] + '\n// dctt: Xcode-only previews omitted for CLT builds.\n#endif\n'
    update(path, text)

path = root / 'KeyboardShortcuts/Sources/KeyboardShortcuts/ConflictPolicy.swift'
text = path.read_text()
old = '@Entry'
if old in text:
    import re
    text, count = re.subn(r'@Entry\s+var keyboardShortcutsConflictPolicy = KeyboardShortcuts.ConflictPolicy.default', '''var keyboardShortcutsConflictPolicy: KeyboardShortcuts.ConflictPolicy {
        get { self[DcttConflictPolicyKey.self] }
        set { self[DcttConflictPolicyKey.self] = newValue }
    }''', text)
    assert count == 1, 'Pinned @Entry declaration changed; inspect before patching.'
    text += '''\nprivate struct DcttConflictPolicyKey: EnvironmentKey {
    static let defaultValue = KeyboardShortcuts.ConflictPolicy.default
}\n'''
    update(path, text)

# SwiftPM's generated Bundle.module assumes bundles at the app root; signed
# macOS applications must keep them under Contents/Resources instead.
for package, source, bundle in [
    ('KeyboardShortcuts', 'Sources/KeyboardShortcuts/Utilities.swift', 'KeyboardShortcuts_KeyboardShortcuts'),
    ('FluidAudio', 'Sources/FluidAudio/TTS/LuxTts/G2p/LuxTtsG2p.swift', 'FluidAudio_FluidAudio'),
]:
    path = root / package / source
    text = path.read_text()
    if 'private extension Bundle' not in text:
        text = text.replace('Bundle.module', 'Bundle.dcttResources').replace('bundle: .module', 'bundle: .dcttResources')
        text += f'''\nprivate extension Bundle {{
    static var dcttResources: Bundle {{
        Bundle.main.resourceURL.flatMap {{ Bundle(url: $0.appendingPathComponent("{bundle}.bundle")) }} ?? .module
    }}
}}\n'''
        update(path, text)
