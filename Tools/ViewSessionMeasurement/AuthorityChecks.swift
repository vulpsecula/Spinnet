import Foundation
import SpinnetCore

/// The Host's own decisions about a Plugin's access, checked over the real
/// helper without drawing anything (#69, PROOF.md "On the running Host").
/// Everything here is Host code from SpinnetCore: the installation store and
/// its review, the permission disclosure the install sheet shows, the
/// broker's authorization of a Plugin View's standard actions, the failure
/// and repair route the view shows, and the grant store's revocation, wired
/// to the View Session and the helper as the Host wires them. Only the
/// effects are recorded instead of performed: nothing is copied to the
/// clipboard or inserted anywhere.
struct AuthorityCheck: Encodable {
    let check: String
    let package: String
    let expected: String
    let actual: String
    let passed: Bool
}

final class AuthorityChecks {
    private let helperURL: URL
    private let packageURL: URL
    private let updateURL: URL?
    private(set) var results: [AuthorityCheck] = []

    init(helperURL: URL, packageURL: URL, updateURL: URL?) {
        self.helperURL = helperURL
        self.packageURL = packageURL
        self.updateURL = updateURL
    }

    func run(progress: (String) -> Void) throws {
        progress("Installation and update through the installation store")
        try checkInstallation()
        for package in [packageURL] + (updateURL.map { [$0] } ?? []) {
            progress("Standard actions and revocation in a View Session of \(package.lastPathComponent)")
            try checkSession(package)
        }
    }

    private func record(_ check: String, _ package: String, expected: String, actual: String, passed: Bool) {
        results.append(AuthorityCheck(check: check, package: package, expected: expected, actual: actual, passed: passed))
    }

    // MARK: Installation

    private func checkInstallation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("spinnet-authority-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = PluginRegistry()
        let grants = PluginCapabilityGrantStore()
        let store = PluginInstallationStore(directory: directory, registry: registry, grants: grants, persistGrants: {})

        let review = try store.review(packageURL)
        let manifest = review.manifest
        let label = "\(manifest.name) \(manifest.version)"
        let requested = review.requestedAccess.map(\.rawValue)
        record("Install: access the install sheet asks for", label,
               expected: "write_clipboard, insert_into_focused_app",
               actual: requested.isEmpty ? "nothing" : requested.joined(separator: ", "),
               passed: Set(requested) == ["write_clipboard", "insert_into_focused_app"])
        let disclosure = PluginPermissionDisclosure(manifest: manifest)
        let text = PluginConsentGroup.allCases
            .map { "\($0.rawValue): \(disclosure.details(for: $0))" }
            .joined(separator: "\n")
        // A Capability without a declared scope is disclosed by what it
        // does ("Replace current clipboard text") rather than by its title.
        let namesClipboard = text.contains(PluginCapability.writeClipboard.title)
            || text.contains("Replace current clipboard text")
        record("Install: the sheet's disclosure text", label,
               expected: "names clipboard writing and \(PluginCapability.insertIntoFocusedApp.title), both optional",
               actual: text,
               passed: namesClipboard && text.contains(PluginCapability.insertIntoFocusedApp.title)
                   && text.components(separatedBy: "Optional for").count == 3)

        let installed = try store.install(from: packageURL)
        for capability in installed.capabilities {
            grants.setDecision(.granted, for: installed.id, pluginVersion: installed.version, capability: capability,
                               scope: installed.scope(for: capability))
        }
        guard let updateURL else { return }
        guard let command = installed.commands.first(where: { $0.execution == .javascript }) else {
            throw MeasurementError("\(label) declares no scripted Command")
        }
        // A Menu Item made from the first version, as the Library would.
        let menuItemAction = try ActionConfiguration(id: ActionID("menu-item"), pluginID: installed.id,
                                                     command: command, input: .null)

        let update = try store.review(updateURL)
        let updateLabel = "\(installed.version) → \(update.manifest.version)"
        record("Update: access the update asks for", updateLabel, expected: "nothing",
               actual: update.requestedAccess.isEmpty ? "nothing" : update.requestedAccess.map(\.rawValue).joined(separator: ", "),
               passed: update.requestedAccess.isEmpty)
        let updated = try store.install(from: updateURL)
        let decisions = updated.capabilities.map { capability in
            "\(capability.rawValue) \(grants.decision(for: updated.id, pluginVersion: updated.version, capability: capability, scope: updated.scope(for: capability)).title)"
        }
        record("Update: grants carried to the new version", updateLabel,
               expected: "both Allowed (the decisions made for \(installed.version))",
               actual: decisions.joined(separator: ", "),
               passed: updated.capabilities.allSatisfy {
                   grants.decision(for: updated.id, pluginVersion: updated.version, capability: $0,
                                   scope: updated.scope(for: $0)) == .granted
               })
        let availability = registry.availability(for: menuItemAction)
        record("Update: the existing Menu Item keeps working", updateLabel, expected: "available",
               actual: availability.isAvailable ? "available" : "unavailable: \(availability)",
               passed: availability.isAvailable)
    }

    // MARK: View Session

    private func checkSession(_ packageURL: URL) throws {
        let manifest = try PluginManifestLoader.load(packageAt: packageURL).manifest
        let label = "\(manifest.name) \(manifest.version)"
        let grants = PluginCapabilityGrantStore()
        func decide(_ decision: PluginCapabilityGrantDecision, _ capability: PluginCapability) {
            grants.setDecision(decision, for: manifest.id, pluginVersion: manifest.version, capability: capability,
                               scope: manifest.scope(for: capability))
        }
        // Denied in Privacy & Permissions before the view opens.
        decide(.granted, .writeClipboard)
        decide(.denied, .insertIntoFocusedApp)

        let accessibility = Locked(true)
        let copied = Locked<[String]>([])
        let inserted = Locked<[String]>([])
        let broker = CapabilityCheckedHostServiceBroker(
            grantStore: grants,
            systemPermissionCheck: { _ in accessibility.value },
            selectedTextProvider: { _ in throw PluginHostServiceError.unavailable("not used by Emoji") },
            clipboardWriter: { copied.value.append($0) }
        )
        let rig = try ViewSessionRig(helperURL: helperURL, fixtureURL: packageURL, grantStore: grants)
        defer { rig.shutdown() }
        let package = rig.package
        let hostActions = PluginViewHostActions(
            authorize: { service, action in try broker.authorize(service, for: package, action: action) },
            manifest: { _ in manifest },
            copyText: { copied.value.append($0) },
            openURL: { _ in },
            insertText: { text, _, finished in
                inserted.value.append(text)
                finished(nil)
            },
            openPluginSettings: { _ in },
            readSettings: { _ in [:] },
            writeSettings: { _, _ in }
        )
        let origin = PluginViewOrigin(processIdentifier: 1, name: "the origin App")

        if let failure = try rig.openView().failure { throw MeasurementError("\(label) did not open: \(failure)") }
        if let failure = try type("tada", into: rig).failure { throw MeasurementError("Typing failed: \(failure)") }
        guard let session = rig.session else { throw MeasurementError("\(label) has no open view") }
        let view = try PluginViewDescription(parsing: session.view, settingsFields: manifest.settingsFields)
        let standards = view.actions.compactMap { action -> PluginViewStandardAction? in
            if case .standard(let standard, _) = action.kind { return standard }
            return nil
        }
        guard let insert = standards.first(where: { if case .insertText = $0 { return true } else { return false } }),
              let copy = standards.first(where: { if case .copyText = $0 { return true } else { return false } }),
              case .insertText(let emoji) = insert else {
            throw MeasurementError("\(label) offered no Insert and Copy actions for \"tada\"")
        }

        func perform(_ standard: PluginViewStandardAction) -> String {
            do {
                try hostActions.perform(standard, for: rig.action, origin: origin)
                return "performed"
            } catch {
                let failure = hostActions.failure(error, for: rig.action)
                let repair = PluginViewRepairRoute(failure).map { " | repair: \($0.title) (\($0.guidance))" } ?? ""
                return "refused: \(failure.message)\(repair)"
            }
        }

        let deniedInsert = perform(insert)
        let copyBeside = perform(copy)
        record("Insert denied in Privacy & Permissions: Insert", label,
               expected: "refused: Capability insert_into_focused_app is not granted | repair: Open Plugin Settings",
               actual: deniedInsert + (inserted.value.isEmpty ? "; nothing inserted" : "; inserted \(inserted.value)"),
               passed: deniedInsert.hasPrefix("refused: Capability insert_into_focused_app is not granted | repair: Open Plugin Settings")
                   && inserted.value.isEmpty)
        record("Insert denied in Privacy & Permissions: Copy still works", label,
               expected: "performed; the clipboard gets exactly \(emoji)",
               actual: "\(copyBeside); copied \(copied.value)",
               passed: copyBeside == "performed" && copied.value == [emoji])

        decide(.granted, .insertIntoFocusedApp)
        accessibility.value = false
        let noAccessibility = perform(insert)
        record("Accessibility off: Insert", label,
               expected: "refused: System Permission accessibility is not granted | repair: Open Privacy & Permissions",
               actual: noAccessibility + (inserted.value.isEmpty ? "; nothing inserted" : "; inserted \(inserted.value)"),
               passed: noAccessibility.hasPrefix("refused: System Permission accessibility is not granted | repair: Open Privacy & Permissions")
                   && inserted.value.isEmpty)
        accessibility.value = true
        let granted = perform(insert)
        record("Both granted: Insert reaches the Host's insertion", label,
               expected: "performed with exactly \(emoji) (the AX insertion itself is script/ax_insertion_matrix.sh's)",
               actual: "\(granted); handed \(inserted.value)",
               passed: granted == "performed" && inserted.value == [emoji])

        // Revoking with the view open: keep the helper busy-warm first.
        if let failure = try type("cat", into: rig).failure { throw MeasurementError("Typing failed: \(failure)") }
        guard let helper = rig.runningHelper() else { throw MeasurementError("No helper ran for \(label)") }
        let revoked = Clock.now()
        decide(.denied, .writeClipboard)
        var helperGoneMs: Double?
        while Clock.milliseconds(from: revoked, to: Clock.now()) < 3000 {
            if !helper.isRunning {
                helperGoneMs = Clock.milliseconds(from: revoked, to: Clock.now())
                break
            }
            Clock.sleep(milliseconds: 2)
        }
        var ended = rig.lastEnd
        while ended == nil, Clock.milliseconds(from: revoked, to: Clock.now()) < 3000 {
            Clock.sleep(milliseconds: 10)
            ended = rig.lastEnd
        }
        record("Revoke a grant while the view is open", label,
               expected: "the View Session ends (capabilityRevoked) and the helper exits at once",
               actual: "session ended: \(ended.map { "\($0)" } ?? "no"); helper "
                   + (helperGoneMs.map { String(format: "exited after %.1f ms", $0) } ?? "still running after 3 s"),
               passed: ended == .capabilityRevoked && helperGoneMs != nil)
    }

    private func type(_ query: String, into rig: ViewSessionRig) throws -> Interaction {
        var text = ""
        let keystrokes = query.enumerated().map { offset, character -> (offset: Int, event: PluginViewEvent) in
            text.append(character)
            return (offset * 50, .fieldChanged(field: "query", values: .object(["query": .string(text)])))
        }
        return try rig.interact(keystrokes)
    }

    var text: String {
        var lines = ["Authority checks over the real helper (\(results.filter(\.passed).count) of \(results.count) as expected)", ""]
        for result in results {
            lines.append("[\(result.passed ? "pass" : "FAIL")] \(result.check) — \(result.package)")
            lines.append("  expected: \(result.expected)")
            lines.append("  actual:   \(result.actual.replacingOccurrences(of: "\n", with: "\n            "))")
        }
        return lines.joined(separator: "\n")
    }
}

private final class Locked<Value> {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

func runAuthority(_ options: MeasurementOptions) throws {
    guard let helperURL = options.helperURL ?? defaultHelperURL(),
          FileManager.default.isExecutableFile(atPath: helperURL.path) else {
        throw MeasurementError("SpinnetPluginHelper was not found; build it and pass --helper")
    }
    guard let packageURL = options.fixtureURL else {
        throw MeasurementError("authority needs --fixture, the Plugin package to check")
    }
    let output = try ResultsDirectory(options.outputURL ?? ResultsDirectory.defaultURL(named: "authority"))
    let checks = AuthorityChecks(helperURL: helperURL, packageURL: packageURL, updateURL: options.updateURL)
    try checks.run { print("- \($0)") }
    struct Summary: Encodable {
        let gitRevision: String
        let helper: String
        let package: String
        let update: String?
        let checks: [AuthorityCheck]
    }
    try output.writeJSON("authority.json", Summary(gitRevision: options.gitRevision, helper: helperURL.path,
                                                   package: packageURL.path, update: options.updateURL?.path,
                                                   checks: checks.results))
    try output.writeText("authority.txt", checks.text)
    print("")
    print(checks.text)
    print("Results: \(output.url.path)")
    if checks.results.contains(where: { !$0.passed }) { throw MeasurementError("Some authority checks did not hold") }
}
