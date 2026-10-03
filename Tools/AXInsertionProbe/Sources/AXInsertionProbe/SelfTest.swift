import AppKit
import SpinnetCore

/// Checks the probe's own logic without driving any App: the mapping from
/// the Host's errors to steps, the read-back, the pages, and the report's
/// JSON and Markdown from a fake run. Needs no Accessibility grant.
enum SelfTest {
    private static var failures: [String] = []

    private static func check(_ condition: Bool, _ message: String) {
        if !condition { failures.append(message) }
    }

    static func run(writingSampleTo output: URL?) -> Bool {
        failures = []
        checkSteps()
        checkReadBack()
        checkPages()
        checkHostCallIsLinked()
        let report = fakeReport()
        checkReport(report)
        if let output {
            do {
                try ReportWriter.write(report, to: output)
                print("sample results: \(output.path)")
            } catch {
                failures.append("could not write the sample: \(error)")
            }
        }
        if failures.isEmpty {
            print("selftest passed")
            return true
        }
        failures.forEach { print("FAIL: \($0)") }
        return false
    }

    private static func checkSteps() {
        let cases: [(PluginHostServiceError, InsertionStep, String)] = [
            (.systemPermissionDenied(.accessibility), .accessibilityNotGranted,
             "System Permission accessibility is not granted"),
            (.unavailable("No focused text field"), .noFocusedElement,
             "Host Service is unavailable: No focused text field"),
            (.unavailable("The focused App does not accept inserted text"), .selectedTextNotSettable,
             "Host Service is unavailable: The focused App does not accept inserted text"),
            (.failed("The focused App did not accept the text"), .setSelectedTextError,
             "Host Service failed: The focused App did not accept the text"),
            (.unavailable("Something else"), .otherError, "Host Service is unavailable: Something else")
        ]
        for (error, step, shown) in cases {
            check(HostA2Insertion.step(for: error) == step, "\(error) should map to \(step)")
            check(error.description == shown, "the Host shows \"\(error.description)\", expected \"\(shown)\"")
        }
    }

    private static func checkReadBack() {
        let text = InsertionText(marker: "axp123456")
        let hit = HostA2Insertion.evaluate("before \(text.text) after", for: text, source: "test")
        check(hit.containsInsertedText && hit.containsMarker && hit.containsEmoji, "a full insertion is found")
        check(HostA2Insertion.step(afterSuccess: hit) == .inserted, "found means inserted")
        let mangled = HostA2Insertion.evaluate("before ?? axp123456", for: text, source: "test")
        check(!mangled.containsInsertedText && mangled.containsMarker && !mangled.containsEmoji,
              "a marker without its emoji is told apart")
        check(HostA2Insertion.step(afterSuccess: mangled) == .setOKTextNotFound, "a mangled insertion is not inserted")
        let unreadable = ReadBack(source: "test", readable: false, axError: "kAXErrorNoValue", valueLength: nil,
                                  containsInsertedText: false, containsMarker: false, containsEmoji: false, excerpt: nil)
        check(HostA2Insertion.step(afterSuccess: unreadable) == .setOKUnverified, "unreadable is unverified")
        check(text.replacement.text.contains(text.marker), "the replacement extends the marker")
        let long = String(repeating: "x", count: 200) + text.text + String(repeating: "y", count: 200)
        let excerpt = HostA2Insertion.evaluate(long, for: text, source: "test").excerpt ?? ""
        check(excerpt.count <= text.marker.count + 80, "the excerpt is bounded")
    }

    /// The pages and their reports, through a real server on 127.0.0.1:
    /// the page is served with its title, field and script, and a report
    /// posted the way the page posts it is kept for its row.
    private static func checkPages() {
        for kind in WebFieldKind.allCases {
            let html = Pages.html(kind, marker: "axp123456", row: "safari.\(kind.rawValue)")
            check(html.contains("<title>\(Pages.title(kind, marker: "axp123456"))</title>"), "\(kind) page has its title")
            check(kind == .addressBar || html.contains("id=\"probe-target\""), "\(kind) page has its field")
            check(kind == .addressBar || html.contains("autofocus"), "\(kind) page autofocuses")
            check(kind == .addressBar || html.contains("fetch('/observe?row='"), "\(kind) page reports its field")
            check(kind == .addressBar || html.contains("\"safari.\(kind.rawValue)\""), "\(kind) page names its row")
        }
        let server = ObservationServer(marker: "axp123456")
        do {
            try server.start()
        } catch {
            failures.append("the page server did not start: \(error.localizedDescription)")
            return
        }
        let row = "selftest.input"
        let url = server.pageURL(.input, row: row)
        check(url.absoluteString.hasPrefix("http://127.0.0.1:"), "pages are served from 127.0.0.1")
        let page = fetch(URLRequest(url: url))
        check(page.status == 200 && String(data: page.body, encoding: .utf8)?.contains(Pages.title(.input, marker: "axp123456")) == true,
              "the server serves the page (status \(page.status))")
        let text = InsertionText(marker: "axp123456")
        var post = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/observe?row=\(row)")!)
        post.httpMethod = "POST"
        post.httpBody = Data(#"{"seq":1,"reason":"input","value":"x\#(text.text)y","activeIsTarget":true,"hasFocus":true,"events":["beforeinput:insertText","input:insertText"]}"#.utf8)
        check(fetch(post).status == 204, "the server takes a report")
        let observation = server.latest(row: row)
        check(observation?.value == "x\(text.text)y" && observation?.events.count == 2, "the report is kept for its row")
        check(server.latest(row: "another.row") == nil, "a report belongs to its row only")
        let verify = IndependentChecks.page(server, row: row, timeout: 0.2)
        let seen = verify(text)
        check(seen.observed && seen.containsInsertedText && seen.targetFocusedBefore == true, "the page check finds the text")
        check(!verify(InsertionText(marker: "axp999999")).containsMarker, "the page check misses another text")
        check(fetch(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/elsewhere")!)).status == 404,
              "the server serves nothing else")
    }

    private static func fetch(_ request: URLRequest) -> (status: Int, body: Data) {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<(Int, Data)>((0, Data()))
        URLSession.shared.dataTask(with: request) { data, response, _ in
            box.value = ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data())
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        return box.value
    }

    /// Calls the Host's own insertion into a process that does not exist, so
    /// nothing anywhere receives text: without the grant it must refuse for
    /// Accessibility, with it it must find no focused element.
    private static func checkHostCallIsLinked() {
        let insertion = HostA2Insertion()
        let attempt = insertion.attempt(InsertionText(marker: "axpselftest"), into: 999_999, settle: 0)
        let expected: InsertionStep = AXIsProcessTrusted() ? .noFocusedElement : .accessibilityNotGranted
        check(attempt.step == expected, "the Host call into no process gave \(attempt.step), expected \(expected)")
    }

    static func fakeReport() -> ProbeReport {
        let text = InsertionText(marker: "axp00000001")
        let element = ElementInfo(present: true, role: "AXTextField", subrole: nil, windowTitle: "AX probe input axp00000",
                                  selectedTextSettable: "yes", selectedTextRangeSettable: "yes", valueLength: 0)
        var inserted = ProbeRow(id: "fake.inserted", app: "Fake App", bundleID: "dev.fake.app", appVersion: "1.0",
                                toolkit: "AppKit", control: "NSTextField", variant: Variant.asIs.label, expected: "insert",
                                status: "ran")
        inserted.focusedBefore = element
        inserted.attempt = Attempt(step: .inserted, hostError: nil,
                                   readBack: HostA2Insertion.evaluate(text.text, for: text, source: "kAXValue of the focused element"),
                                   elapsedMilliseconds: 3.2)
        inserted.selection = SelectionResult(result: "replaced_selection", hostError: nil, detail: nil)
        inserted.fixtureValue = text.text
        inserted.cleanup = "closed"

        var noFocus = ProbeRow(id: "fake.chromium.as-is", app: "Fake Browser", bundleID: "dev.fake.browser",
                               appVersion: "2.0", toolkit: "Chromium", control: "<input type=text>",
                               variant: Variant.asIs.label, expected: "insert", status: "ran")
        let error = PluginHostServiceError.unavailable("No focused text field")
        noFocus.attempt = Attempt(step: HostA2Insertion.step(for: error), hostError: error.description, readBack: nil,
                                  elapsedMilliseconds: 1)
        noFocus.retry = Attempt(step: .inserted, hostError: nil,
                                readBack: HostA2Insertion.evaluate(text.text, for: text, source: "kAXValue of the focused element"),
                                elapsedMilliseconds: 2)
        noFocus.focusedAfter = element
        noFocus.cleanup = "separate instance quit; its profile deleted"

        var experiment = noFocus
        experiment.id = "fake.chromium.experiment"
        experiment.variant = Variant.experiment(attribute: "AXEnhancedUserInterface").label
        experiment.retry = nil
        experiment.attempt = Attempt(step: .inserted, hostError: nil,
                                     readBack: HostA2Insertion.evaluate(text.text, for: text, source: "kAXValue of the focused element"),
                                     elapsedMilliseconds: 2)
        experiment.experiment = ExperimentInfo(attribute: "AXEnhancedUserInterface", setResult: "success", valueAfter: "true")

        var refused = inserted
        refused.id = "fake.secure"
        refused.control = "NSSecureTextField"
        refused.expected = "refuse"
        refused.selection = nil
        let notSettable = PluginHostServiceError.unavailable("The focused App does not accept inserted text")
        refused.attempt = Attempt(step: .selectedTextNotSettable, hostError: notSettable.description, readBack: nil,
                                  elapsedMilliseconds: 1)
        refused.retry = Attempt(step: .selectedTextNotSettable, hostError: notSettable.description, readBack: nil,
                                elapsedMilliseconds: 1)
        refused.fixtureValue = ""

        var web = ProbeRow(id: "fake.web.as-is", app: "Fake Browser", bundleID: "dev.fake.browser", appVersion: "2.0",
                           toolkit: "Chromium", control: "<textarea>", variant: Variant.asIs.label, expected: "insert",
                           status: "ran")
        web.attempt = Attempt(step: .setOKTextNotFound, hostError: nil,
                              readBack: HostA2Insertion.evaluate("", for: text, source: "kAXValue of the focused element"),
                              elapsedMilliseconds: 2)
        var pageCheck = IndependentCheck(label: "page", source: "test", value: "", text: text)
        pageCheck.targetFocusedBefore = true
        web.independentCheck = pageCheck

        var typed = web
        typed.id = "fake.web.keystrokes"
        typed.variant = Variant.keystrokes.label
        typed.attempt = nil
        let typedCheck = IndependentCheck(label: "page", source: "test", value: text.text, text: text)
        typed.independentCheck = typedCheck
        typed.keystrokes = KeystrokeExperiment(channels: [
            KeystrokeChannel(channel: "pid", eventsPosted: 26, received: true, check: typedCheck)
        ])

        var skipped = ProbeRow(id: "fake.skipped", app: "Fake Chat", bundleID: "dev.fake.chat", appVersion: nil,
                               toolkit: "Electron", control: "Message box", variant: Variant.asIs.label,
                               expected: "n/a", status: "skipped")
        skipped.skipReason = "skipped: needs account content"

        let planned = ProbeRow(id: "fake.planned", app: "Fake Editor", bundleID: "dev.fake.editor", appVersion: "3.0",
                               toolkit: "AppKit", control: "Document", variant: Variant.asIs.label, expected: "insert",
                               status: "planned")

        return ProbeReport(
            mode: "selftest (fake runner)",
            hostBuild: HostBuild(commit: HostA2Provenance.commit, spinnetCoreTree: HostA2Provenance.spinnetCoreTree,
                                 files: HostA2Provenance.files, headIdentical: HostA2Provenance.headIdentical),
            startedAt: "2026-10-02T00:00:00Z", finishedAt: "2026-10-02T00:00:01Z", machine: "fake machine",
            accessibilityTrusted: false, insertedTextPattern: "\(InsertionText.emoji)axp000000NN",
            rows: [inserted, noFocus, experiment, refused, web, typed, skipped, planned],
            notes: ["This sample comes from a fake runner; no App was driven."]
        )
    }

    private static func checkReport(_ report: ProbeReport) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(report),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = object["rows"] as? [[String: Any]] else {
            failures.append("the report does not encode to a JSON object with rows")
            return
        }
        for key in ["hostBuild", "hostCall", "machine", "accessibilityTrusted", "insertedTextPattern", "rows", "notes"] {
            check(object[key] != nil, "the report has \(key)")
        }
        check(rows.count == report.rows.count, "every row is encoded")
        for key in ["id", "app", "bundleID", "toolkit", "control", "variant", "expected", "status"] {
            check(rows.allSatisfy { $0[key] != nil }, "every row has \(key)")
        }
        let ran = rows.filter { $0["status"] as? String == "ran" }
        check(ran.allSatisfy { ($0["attempt"] as? [String: Any])?["step"] != nil || $0["keystrokes"] != nil },
              "every run row has its Host step or its keystroke result")
        check(ran.contains { ($0["attempt"] as? [String: Any])?["hostError"] as? String == "Host Service is unavailable: No focused text field" },
              "the Host's error text is kept exactly")
        check((try? JSONDecoder().decode(ProbeReport.self, from: data)) != nil, "the report decodes again")
        let markdown = ReportWriter.markdown(report)
        let tableRows = markdown.split(separator: "\n").filter { $0.hasPrefix("| ") && !$0.hasPrefix("| App") && !$0.hasPrefix("| Item") && !$0.hasPrefix("| ---") }
        // The header table has five rows; the matrix one per probe row.
        check(tableRows.count == report.rows.count + 5, "the Markdown has one matrix row per probe row")
        check(markdown.contains("`Host Service is unavailable: No focused text field`"), "the Markdown shows the Host's error")
        check(markdown.contains("AXEnhancedUserInterface set: success"), "the Markdown names the experiment")
        check(markdown.contains("| set OK, text not found | page: text absent (0 chars) |"),
              "the Markdown shows the AX read-back beside the page's own check")
        check(markdown.contains("| keystrokes received (pid) | page: text present |"), "the Markdown shows the keystroke experiment")
    }
}
