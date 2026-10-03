import Foundation

/// The pages Safari and Chrome open, one per field kind, served by the
/// probe's own `ObservationServer` on 127.0.0.1. Each focuses its one field
/// on load (autofocus, and a script for engines that skip autofocus on a
/// contenteditable), and its title carries the run's marker so the probe can
/// tell its window from the user's. Each page also reports its field's value,
/// as the DOM holds it, to the probe: on load, on every `input` event and
/// whenever a 200 ms poll sees the value or the focus change. That report is
/// the insertion's check independent of Accessibility.
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

    static func html(_ kind: WebFieldKind, marker: String, row: String) -> String {
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
        let rowLiteral = String(data: try! JSONEncoder().encode(row), encoding: .utf8)!
        let script = kind == .addressBar ? "" : """
            <script>
            (function () {
              var row = \(rowLiteral);
              var target = document.getElementById('probe-target');
              var seq = 0, events = [], lastValue = null, lastFocus = null;
              function value() { return target.isContentEditable ? target.innerText : target.value; }
              function focused() { return document.activeElement === target && document.hasFocus(); }
              function report(reason) {
                seq += 1;
                lastValue = value();
                lastFocus = focused();
                var body = JSON.stringify({ seq: seq, reason: reason, value: lastValue,
                  activeIsTarget: document.activeElement === target, hasFocus: document.hasFocus(),
                  events: events.slice(-20) });
                try {
                  fetch('/observe?row=' + encodeURIComponent(row),
                        { method: 'POST', body: body, keepalive: true, headers: { 'Content-Type': 'text/plain' } });
                } catch (error) {}
              }
              ['keydown', 'beforeinput', 'input', 'compositionstart', 'compositionend', 'paste'].forEach(function (type) {
                target.addEventListener(type, function (event) {
                  events.push(type + (event.inputType ? ':' + event.inputType : ''));
                  if (events.length > 40) { events.shift(); }
                }, true);
              });
              target.addEventListener('input', function () { report('input'); });
              target.addEventListener('focus', function () { report('focus'); });
              window.addEventListener('load', function () {
                if (document.activeElement !== target) { target.focus(); }
                report('load');
              });
              setInterval(function () {
                if (value() !== lastValue || focused() !== lastFocus) { report('poll'); }
              }, 200);
            })();
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
            \(script)
            </body>
            </html>
            """
    }
}
