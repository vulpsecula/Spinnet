import Foundation

/// The local pages Safari and Chrome open, one per field kind. Each focuses
/// its one field on load (autofocus, and a script for engines that skip
/// autofocus on a contenteditable), and its title carries the run's marker so
/// the probe can tell its window from the user's.
enum WebFieldKind: String, CaseIterable, Codable {
    case input
    case textarea
    case contenteditable
    /// A page with nothing focused; the probe focuses the address bar.
    case addressBar = "address-bar"

    var control: String {
        switch self {
        case .input: return "<input type=text>"
        case .textarea: return "<textarea>"
        case .contenteditable: return "contenteditable <div>"
        case .addressBar: return "address bar"
        }
    }
}

enum Pages {
    static func title(_ kind: WebFieldKind, marker: String) -> String { "AX probe \(kind.rawValue) \(marker)" }

    static func html(_ kind: WebFieldKind, marker: String) -> String {
        let field: String
        switch kind {
        case .input:
            field = #"<input id="probe-target" type="text" autofocus value="" style="width:28em">"#
        case .textarea:
            field = #"<textarea id="probe-target" autofocus rows="6" cols="60"></textarea>"#
        case .contenteditable:
            field = #"<div id="probe-target" contenteditable="true" autofocus style="border:1px solid #888;min-height:6em;padding:4px"></div>"#
        case .addressBar:
            field = "<p>The probe focuses the address bar of this window.</p>"
        }
        let focusScript = kind == .addressBar ? "" : """
            <script>
            window.addEventListener('load', function () {
              var target = document.getElementById('probe-target');
              if (document.activeElement !== target) { target.focus(); }
            });
            </script>
            """
        return """
            <!doctype html>
            <html lang="en">
            <head><meta charset="utf-8"><title>\(title(kind, marker: marker))</title></head>
            <body>
            <h1>Spinnet AX insertion probe</h1>
            <p>Field kind: \(kind.rawValue). This page belongs to the probe and is closed without saving.</p>
            \(field)
            \(focusScript)
            </body>
            </html>
            """
    }

    /// Writes every page into `directory` and returns their URLs.
    @discardableResult
    static func write(marker: String, into directory: URL) throws -> [WebFieldKind: URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [WebFieldKind: URL] = [:]
        for kind in WebFieldKind.allCases {
            let url = directory.appendingPathComponent("ax-probe-\(kind.rawValue)-\(marker).html")
            try Data(html(kind, marker: marker).utf8).write(to: url, options: .atomic)
            urls[kind] = url
        }
        return urls
    }
}
