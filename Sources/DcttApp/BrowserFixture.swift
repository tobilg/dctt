import Foundation

/// Test-only local page. Exposes focus, paste count, and a digest in its title;
/// never places a transcript or unrelated page content into diagnostics.
struct BrowserFixture {
    enum Field: String { case input, textarea, editable, password, switchField = "switch" }
    let bundleID: String
    let field: Field
    let marker = "dctt-check-\(UUID().uuidString)|"

    init?(target: String) {
        let parts: [String]
        switch target {
        case "browser-input": parts = ["safari", "textarea"] // Legacy alias.
        case "browser-editable": parts = ["safari", "editable"]
        default: parts = target.split(separator: "-").map(String.init)
        }
        guard parts.count == 2, let field = Field(rawValue: parts[1]) else { return nil }
        switch parts[0] {
        case "safari": bundleID = "com.apple.Safari"
        case "chrome": bundleID = "com.google.Chrome"
        case "firefox": bundleID = "org.mozilla.firefox"
        default: return nil
        }
        self.field = field
    }

    struct State {
        let focus: Int // 1 = original input, 2 = second input, 0 = neither.
        let pasteCount: Int
        let digest: String
    }
    func state(title: String?) -> State? {
        guard let title, title.hasPrefix(marker) else { return nil }
        let parts = title.dropFirst(marker.count).split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let focus = Int(parts[0]), let pastes = Int(parts[1]) else { return nil }
        // Some browsers append their app name to the native window title.
        return State(focus: focus, pasteCount: pastes, digest: String(parts[2].prefix(64)))
    }

    var html: String {
        let element: String
        switch field {
        case .input: element = "<input id='dctt-input' type='text' autocomplete='off'>"
        case .password: element = "<input id='dctt-input' type='password' autocomplete='new-password'>"
        case .textarea, .switchField: element = "<textarea id='dctt-input' rows='10'></textarea>"
        case .editable: element = "<div id='dctt-input' contenteditable='true' role='textbox' aria-multiline='true'></div>"
        }
        return #"""
        <!doctype html><meta charset="utf-8"><title>\#(marker)0|0|-</title>
        <style>body{font:18px system-ui;margin:40px;max-width:800px}input,textarea,[contenteditable]{display:block;box-sizing:border-box;width:100%;padding:16px;border:1px solid #888;font:inherit}[contenteditable]{min-height:180px}label{display:block;margin:20px 0 8px}</style>
        <h1>dctt disposable browser check</h1>
        <p>This local test uses synthesized speech. No form is submitted.</p>
        <label for="dctt-input">Test input</label>\#(element)
        <label for="dctt-other">Second input for the focus-change check</label>
        <input id="dctt-other" autocomplete="off">
        <script>
        const marker = '\#(marker)';
        const field = document.getElementById('dctt-input');
        const other = document.getElementById('dctt-other');
        let pastes = 0, revision = 0;
        async function refresh() {
          const version = ++revision;
          const value = field.isContentEditable ? field.textContent : field.value;
          let digest = 'unavailable';
          try {
            const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
            digest = Array.from(new Uint8Array(bytes), b => b.toString(16).padStart(2, '0')).join('');
          } catch (_) {}
          if (version !== revision) return;
          const focus = !document.hasFocus() ? 0 : document.activeElement === field ? 1 : document.activeElement === other ? 2 : 0;
          document.title = marker + focus + '|' + pastes + '|' + digest;
        }
        document.addEventListener('paste', () => { pastes++; setTimeout(refresh, 0); });
        document.addEventListener('input', refresh);
        document.addEventListener('focusin', refresh);
        document.addEventListener('focusout', refresh);
        window.addEventListener('focus', refresh);
        window.addEventListener('blur', refresh);
        window.addEventListener('load', () => {
          field.focus(); refresh();
          if (\#(field == .switchField ? "true" : "false")) setTimeout(() => {
            if (document.hasFocus() && document.activeElement === field) { other.focus(); refresh(); }
          }, 5000);
        });
        </script>
        """#
    }
}
