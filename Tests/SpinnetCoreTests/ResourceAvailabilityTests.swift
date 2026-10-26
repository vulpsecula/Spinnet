import Foundation
import XCTest
@testable import SpinnetCore

final class ResourceAvailabilityTests: XCTestCase {
    private func temporaryResources() throws -> (root: URL, file: URL, folder: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("folder")
        let file = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: file)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, file, folder)
    }

    private func action(_ command: CommandDeclaration, input: JSONValue = .null) throws -> ActionConfiguration {
        try ActionConfiguration(id: ActionID("configured"), pluginID: PluginID("example.resource"), command: command, input: input)
    }

    func testGenericCataloguePathAcceptsEitherExistingKindAndRefusesMissingTarget() throws {
        let resources = try temporaryResources()
        let command = CommandDeclaration(id: CommandID("open"), title: "Open", hostServiceID: "open.path")
        for path in [resources.file, resources.folder] {
            XCTAssertNil(ActionResourceAvailability.missingReason(for: try action(command, input: .string(path.path))))
        }
        XCTAssertEqual(ActionResourceAvailability.missingReason(for: try action(command,
            input: .object(["path": .string(resources.root.appendingPathComponent("gone").path)]))), .resourceMissing)
    }

    func testRegisteredPickerKindIsUsedWhenCheckingCataloguePath() throws {
        let resources = try temporaryResources()
        for kind in [CommandConfigurationFieldKind.file, .folder] {
            let command = CommandDeclaration(id: CommandID("open"), title: "Open", isConfigurable: true,
                configurationField: .init(kind: kind), hostServiceID: "open.path")
            let manifest = try PluginManifest(id: PluginID("example.resource"), name: "Resource", version: "1", commands: [command])
            let registry = PluginRegistry()
            try registry.register(.init(rootURL: resources.root, manifest: manifest))
            let correct = kind == .file ? resources.file : resources.folder
            let wrong = kind == .file ? resources.folder : resources.file
            XCTAssertEqual(registry.availability(for: try action(command, input: .string(correct.path)),
                resourceAvailability: { ActionResourceAvailability.missingReason(for: $0) }), .available)
            XCTAssertEqual(registry.availability(for: try action(command, input: .string(wrong.path)),
                resourceAvailability: { ActionResourceAvailability.missingReason(for: $0) }), .unavailable(.resourceMissing))
        }
    }

    func testFixedCatalogueTargetReachesHostResolverWithoutChangingSavedInput() throws {
        let command = CommandDeclaration(id: CommandID("open"), title: "Open", hostServiceID: "open.application",
            fixedInput: .object(["application": .string("com.example.editor")]))
        let manifest = try PluginManifest(id: PluginID("example.resource"), name: "Resource", version: "1", commands: [command])
        let registry = PluginRegistry()
        try registry.register(.init(rootURL: URL(fileURLWithPath: "/tmp/resource.spinnetplugin"), manifest: manifest))
        let saved = try action(command)
        var resolvedBundleIDs: [String] = []
        let availability = registry.availability(for: saved, resourceAvailability: {
            ActionResourceAvailability.missingReason(for: $0, applicationExists: {
                resolvedBundleIDs.append($0)
                return false
            })
        })
        XCTAssertEqual(availability, .unavailable(.resourceMissing))
        XCTAssertEqual(resolvedBundleIDs, ["com.example.editor"])
        XCTAssertEqual(saved.input, .null)
    }

    func testCatalogueSetupValidationKeepsNativeGrammarAndAllowsEmptyClipboardText() throws {
        for (id, kind) in [("open.url", CommandConfigurationFieldKind.url), ("open.path", .file),
                           ("open.path", .folder), ("open.application", .application)] {
            let command = CommandDeclaration(id: CommandID("open"), title: "Open", isConfigurable: true,
                configurationField: .init(kind: kind), hostServiceID: id)
            let operation = try XCTUnwrap(HostServiceCatalogue.operation(id))
            XCTAssertFalse(operation.acceptsConfiguredInput(.null, for: command), id)
            XCTAssertFalse(operation.acceptsConfiguredInput(.string(""), for: command), id)
        }
        let clipboard = CommandDeclaration(id: CommandID("copy"), title: "Copy", isConfigurable: true,
            configurationField: .init(kind: .text), hostServiceID: "clipboard.write")
        XCTAssertTrue(try XCTUnwrap(HostServiceCatalogue.operation("clipboard.write"))
            .acceptsConfiguredInput(.string(""), for: clipboard), "Copying empty text deliberately clears the clipboard")
    }
}
