import Foundation
import XCTest
@testable import SpinnetCore

/// A Plugin declaring Candidate Contract `namespaces` names the Host Service
/// a Command runs by its catalogue ID in `host_command`. Reviewing,
/// installing and registering it hold each such Command to the catalogue:
/// a Level 1 Host Command name is refused with the ID to use instead
/// (decision N5), and an ID reserved or not offered as a Command is refused
/// (decision N8), while the scriptless Commands equivalent to Level 1's stay.
final class NamespacesCommandInstallationTests: XCTestCase {
    private var directory: URL!
    private let grants = PluginCapabilityGrantStore()

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(_ contracts: PluginInterfaceContracts = NamespacesProbeFixture.host)
        -> (registry: PluginRegistry, store: PluginInstallationStore) {
        let registry = PluginRegistry(contracts: contracts, grantStore: grants)
        return (registry, PluginInstallationStore(directory: directory.appendingPathComponent("Plugins"),
                                                  registry: registry, grants: grants, persistGrants: {},
                                                  storage: PluginStorage(directory: directory.appendingPathComponent("Storage"))))
    }

    private func assertRefused(_ change: @escaping (inout [String: JSONValue]) -> Void, with message: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let source = try NamespacesProbeFixture.write(change)
        let host = store()
        XCTAssertThrowsError(try host.store.review(source), file: file, line: line) {
            XCTAssertEqual($0.localizedDescription, message, file: file, line: line)
        }
        XCTAssertThrowsError(try host.store.install(from: source), file: file, line: line)
        XCTAssertNil(host.registry.package(for: NamespacesProbeFixture.pluginID), file: file, line: line)
    }

    func testTheProbeAndItsScriptlessCommandInstall() throws {
        let host = store()

        try host.store.install(from: NamespacesProbeFixture.package)

        let manifest = try XCTUnwrap(host.registry.package(for: NamespacesProbeFixture.pluginID)?.manifest)
        let command = try XCTUnwrap(manifest.commands.first { $0.id == CommandID("probe.copy_greeting") })
        XCTAssertNil(command.hostCommand, "A catalogue ID is not a Level 1 Host Command")
        XCTAssertEqual(command.hostServiceID, "clipboard.write")
        XCTAssertEqual(command.fixedInput, .object(["text": .string("Hello from a Host Command")]))
        XCTAssertEqual(manifest.requiredCapabilities(for: command), [.writeClipboard])
    }

    /// The probe's Commands are the shape the candidate's schema publishes,
    /// and the stable manifest schema refuses the catalogue ID.
    func testTheProbesCommandsFollowTheCandidateSchema() throws {
        let schema = HostServiceCatalogueTests.published.appendingPathComponent("namespaces.schema.json")
        let command = try JSONSchemaSubsetValidator(definition: "command", inSchemaAt: schema)
        guard case .object(let manifest) = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: NamespacesProbeFixture.package.appendingPathComponent("manifest.json"))
        ), case .array(let commands)? = manifest["commands"] else { return XCTFail("The probe has no Commands") }
        for declared in commands {
            XCTAssertEqual(command.errors(for: declared), [])
        }
        let stable = try JSONSchemaSubsetValidator(definition: "command", inSchemaAt: HostServiceCatalogueTests.published
            .appendingPathComponent("../../../schemas/manifest.schema.json").standardizedFileURL)
        XCTAssertFalse(stable.errors(for: commands[1]).isEmpty, "Level 1 refuses a catalogue ID")
        XCTAssertFalse(command.errors(for: .object(["id": .string("x"), "title": .string("X"), "execution": .string("host"),
                                                    "host_command": .string("url.open")])).isEmpty,
                       "The candidate refuses a Level 1 name")
    }

    /// Decision N5: a Plugin declaring the candidate names operations by ID
    /// only, and the refusal names the ID to use.
    func testALevelOneHostCommandNameIsRefusedWithTheIDToUseInstead() throws {
        try assertRefused(NamespacesProbeFixture.naming("url.open"), with:
            "Command probe.copy_greeting of Namespaces Probe names url.open, a Plugin API Level 1 Host Command; "
                + "a Plugin declaring the namespaces Candidate Contract names it open.url.")
        try assertRefused(NamespacesProbeFixture.naming("clipboard.copy"), with:
            "Command probe.copy_greeting of Namespaces Probe names clipboard.copy, a Plugin API Level 1 Host Command; "
                + "a Plugin declaring the namespaces Candidate Contract names it selection.copy or clipboard.write.")
    }

    /// Decision N8 and the catalogue's reservations: an ID kept for a later
    /// revision or ticket cannot run as a Command yet.
    func testAnIDReservedAsACommandIsRefused() throws {
        for id in ["selection.replace", "apps.quit", "open.reveal", "system.keepAwake"] {
            try assertRefused(NamespacesProbeFixture.naming(id), with:
                "Command probe.copy_greeting of Namespaces Probe names \(id), which is reserved: no revision of the "
                    + "namespaces Candidate Contract runs it as a Command yet.")
        }
    }

    func testAnIDNotOfferedAsACommandOrNotInTheCatalogueIsRefused() throws {
        try assertRefused(NamespacesProbeFixture.naming("selection.readText"), with:
            "Command probe.copy_greeting of Namespaces Probe names selection.readText, which cannot run as a Command.")
        try assertRefused(NamespacesProbeFixture.naming("clipboard.copyAll"), with:
            "Command probe.copy_greeting of Namespaces Probe names clipboard.copyAll, which is not a Host Service of "
                + "the Plugin API catalogue.")
    }

    /// The Commands equivalent to Level 1's keep running with the user's
    /// configured input, and need no Capability where Level 1's needed none
    /// (decisions N7 and N8).
    func testTheScriptlessCommandsEquivalentToLevelOnesRemain() throws {
        let host = store()
        try host.store.install(from: NamespacesProbeFixture.write { manifest in
            NamespacesProbeFixture.hostCommand { command in
                command["host_command"] = .string("selection.paste")
                command["input"] = nil
            }(&manifest)
            guard case .array(var commands)? = manifest["commands"] else { return }
            for (id, name, field) in [("probe.press", "keyboard.press", "keyboard_shortcut"),
                                      ("probe.shortcut", "system.runShortcut", "shortcut"),
                                      ("probe.service", "system.runService", "text"),
                                      ("probe.open", "open.url", "url")] {
                commands.append(.object(["id": .string(id), "title": .string(id), "execution": .string("host"),
                                         "host_command": .string(name),
                                         "configuration_field": .object(["kind": .string(field)])]))
            }
            manifest["commands"] = .array(commands)
        })

        let manifest = try XCTUnwrap(host.registry.package(for: NamespacesProbeFixture.pluginID)?.manifest)
        for command in manifest.commands where command.execution == .host {
            XCTAssertEqual(manifest.requiredCapabilities(for: command), [], command.id.rawValue)
        }
        XCTAssertEqual(manifest.requiredSystemPermissions(for: manifest.commands[1]), [.accessibility])
        let disclosure = PluginPermissionDisclosure(manifest: manifest)
        XCTAssertTrue(disclosure.details(for: .controls).contains("Copy Greeting: selection.paste (target configured per Menu Item)"))
        XCTAssertTrue(disclosure.details(for: .systemAccess).contains("Accessibility — Shout, Copy Greeting, probe.press"))
    }

    /// A Level 1 Plugin keeps Level 1's Host Commands, and a catalogue ID is
    /// outside what it declares, as for any member of an undeclared candidate.
    func testALevelOnePluginCannotNameACatalogueID() throws {
        try assertRefused(NamespacesProbeFixture.levelOne, with:
            "Command probe.copy_greeting of Namespaces Probe names clipboard.write, which is not part of Plugin API "
                + "Level 1 or a Candidate Contract Namespaces Probe declares.")
    }

    /// A Command fixes members of its operation's input and configures the
    /// rest, never one member both ways, and needs the Capability its
    /// operation needs.
    func testACommandsInputBelongsToItsOperation() throws {
        try assertRefused(NamespacesProbeFixture.hostCommand { $0["input"] = .object(["message": .string("Hi")]) }, with:
            "Command probe.copy_greeting of Namespaces Probe: clipboard.write takes no input member message.")
        try assertRefused({ manifest in
            manifest["preset"] = .object(["readiness": .string("setup_required"), "is_configurable": .bool(true),
                                          "default_primary_command_id": .string("probe.shout")])
            NamespacesProbeFixture.hostCommand { command in
                command["is_configurable"] = .bool(true)
                command["configuration_field"] = .object(["kind": .string("text")])
            }(&manifest)
        }, with: "Command probe.copy_greeting of Namespaces Probe: clipboard.write's text is both fixed and configured.")
        try assertRefused(NamespacesProbeFixture.naming("screen.capture"), with:
            "Command probe.copy_greeting of Namespaces Probe: screen.capture needs source in the Command's input.")
        try assertRefused({ $0["capabilities"] = .array([.string("read_selected_text")]) }, with:
            "Command probe.copy_greeting of Namespaces Probe: clipboard.write needs Capability write_clipboard.")
    }
}
