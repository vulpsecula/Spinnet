import AppKit
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// Clipboard History driven from Settings, against a real Store: collection
/// lifecycle transitions racing an index write, clear arriving mid-persistence,
/// exclusions reaching the collector, and grants staying independent of
/// collection.
final class ClipboardHistorySettingsIntegrationTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testSettingsPauseResumeDuringIndexWriteInvalidatesTheOldCopy() throws {
        try assertLifecycleTransitionDuringIndexWrite { model in
            model.clipboardHistory.collectionPaused = true
            model.clipboardHistory.collectionPaused = false
        }
    }

    func testSettingsTurnOffReenableDuringIndexWriteInvalidatesTheOldCopy() throws {
        try assertLifecycleTransitionDuringIndexWrite { model in
            model.clipboardHistory.turnOff(deleteEntries: false)
            model.clipboardHistory.collectionEnabled = true
        }
    }

    func testSettingsClearDuringIndexWriteCannotPublishAStaleIndex() throws {
        try assertLifecycleTransitionDuringIndexWrite { $0.clipboardHistory.clear() }
    }

    private func assertLifecycleTransitionDuringIndexWrite(_ transition: (SettingsWindowModel) -> Void) throws {
        let writingIndex = expectation(description: "index write is in flight")
        let sampleCompleted = expectation(description: "old sample finished")
        let controlsCompleted = expectation(description: "latest control is durable")
        let gate = DispatchSemaphore(value: 0)
        let ioLock = NSLock()
        var writesUntilPause = -1
        let h = try RichClipboardHistoryTests.Harness(writeFile: { data, url in
            ioLock.lock()
            if writesUntilPause > 0 { writesUntilPause -= 1 }
            let shouldPause = writesUntilPause == 0
            if shouldPause { writesUntilPause = -1 }
            ioLock.unlock()
            if shouldPause {
                writingIndex.fulfill()
                _ = gate.wait(timeout: .now() + 2)
            }
            try data.write(to: url, options: .atomic)
        })
        let suite = "ClipboardIndexRace." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.clipboardHistory.onWillChange = { try h.collector.resetBaseline() }
        model.clipboardHistory.onChange = { controlsCompleted.fulfill() }
        ioLock.lock(); writesUntilPause = 2; ioLock.unlock() // payload, then staged index
        let bytes = Data(repeating: 0x6A, count: 1_100_000)
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        h.collector.schedulePoll { _ in sampleCompleted.fulfill() }
        wait(for: [writingIndex], timeout: 2)
        let start = Date()
        transition(model)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3)
        XCTAssertTrue(model.clipboardHistory.isSaving)
        gate.signal()
        wait(for: [sampleCompleted, controlsCompleted], timeout: 4)
        XCTAssertFalse(model.clipboardHistory.isSaving)
        let package = try h.package(types: ["binary"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        XCTAssertEqual(try h.query(package).state, .collecting)
        // The next valid large copy must still be retained in full.
        h.board.clearContents(); h.board.setData(bytes, forType: .init("com.example.binary"))
        let newCopy = expectation(description: "new valid large copy persisted")
        h.collector.schedulePoll { result in
            if case .failure(let error) = result { XCTFail("Collection failed: \(error)") }
            newCopy.fulfill()
        }
        wait(for: [newCopy], timeout: 3)
        try h.restart()
        let entry = try XCTUnwrap(h.query(package).entries.first)
        XCTAssertEqual(try h.query(package).entries.count, 1)
        XCTAssertEqual(entry.byteCount, 1_100_000)
        XCTAssertEqual(try h.chunk(package, id: entry.id, offset: 1_000_000).data, Data(repeating: 0x6A, count: 100_000))
    }

    func testSettingsClearRespondsDuringPayloadPersistenceAndPreventsLateCommit() throws {
        let writing = expectation(description: "filesystem is writing a large payload")
        let sampleCompleted = expectation(description: "sample finishes")
        let controlCompleted = expectation(description: "Clear is durable")
        let gate = DispatchSemaphore(value: 0)
        let payload = Data(repeating: 0x63, count: 1_100_000)
        let h = try RichClipboardHistoryTests.Harness(writeFile: { data, url in
            if data == payload {
                writing.fulfill()
                _ = gate.wait(timeout: .now() + 2)
            }
            try data.write(to: url, options: .atomic)
        })
        let suite = "ClipboardSlowDisk." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        model.clipboardHistory.onWillChange = { try h.collector.resetBaseline() }
        model.clipboardHistory.onChange = { controlCompleted.fulfill() }
        h.board.clearContents(); h.board.setData(payload, forType: .init("com.example.binary"))
        h.collector.schedulePoll { _ in sampleCompleted.fulfill() }
        wait(for: [writing], timeout: 2)
        let start = Date()
        XCTAssertTrue(h.store.settings.enabled)
        XCTAssertTrue(h.store.excludedApplications.contains("com.apple.Passwords"))
        model.clipboardHistory.clear()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.3, "Settings snapshots and controls must not wait for a blocked filesystem writer")
        gate.signal()
        wait(for: [sampleCompleted, controlCompleted], timeout: 4)
        let package = try h.package(types: ["binary"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries, [], "No stale index may be published after Clear")
    }

    func testSettingsClearInvalidatesAnInFlightScheduledCopy() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "ClipboardLifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        let reading = expectation(description: "old copy is in flight")
        let completed = expectation(description: "old sample completes")
        let gate = DispatchSemaphore(value: 0)
        var blockRead = true
        let collector = ClipboardCollector(store: h.store, changeCount: { h.board.changeCount }, readContents: {
            let content = ClipboardCollector.readAll(from: h.board)
            if blockRead {
                reading.fulfill()
                _ = gate.wait(timeout: .now() + 5)
            }
            return content
        }, sourceApplication: { h.source })
        model.clipboardHistory.onWillChange = { try collector.resetBaseline() }
        h.board.clearContents(); h.board.setString("before Clear", forType: .string)
        collector.schedulePoll { _ in completed.fulfill() }
        wait(for: [reading], timeout: 2)
        model.clipboardHistory.clear()
        gate.signal()
        wait(for: [completed], timeout: 3)
        let package = try h.package(types: ["text"]); h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [], "Clear must invalidate a sampled copy, not just existing entries")
        blockRead = false
        h.board.clearContents(); h.board.setString("after Clear", forType: .string)
        let next = expectation(description: "new copy persists")
        collector.schedulePoll { _ in next.fulfill() }
        wait(for: [next], timeout: 3)
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["after Clear"])
        try h.restart()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["after Clear"])
    }

    func testSettingsHistoryUpgradeDenialReauthorizationAndRestartUsePersistedScope() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "HistoryUpgrade." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grantsURL = h.directory.appendingPathComponent("grants.json")
        let installedURL = h.directory.appendingPathComponent("Plugins")
        let configuration = try makeEditor().configuration
        func session() throws -> (SettingsWindowModel, PluginRegistry) {
            let grants = h.grants
            let registry = PluginRegistry(grantStore: grants)
            let installer = PluginInstallationStore(directory: installedURL, registry: registry, grants: grants, persistGrants: {
                try JSONEncoder().encode(grants.allGrants).write(to: grantsURL, options: .atomic)
            })
            try installer.restore()
            let model = SettingsWindowModel(editor: HostConfigurationEditor(registry: registry, configuration: configuration),
                metadata: .current, capabilityGrantStore: grants, defaults: defaults, clipboardHistoryStore: h.store,
                accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
            model.menuEditor.installPlugin = { try installer.install(from: $0) }
            model.privacy.onGrantsChanged = { values in
                do { try JSONEncoder().encode(values).write(to: grantsURL, options: .atomic) }
                catch { XCTFail("Grant persistence failed: \(error)") }
            }
            return (model, registry)
        }
        func source(types: [String], version: String) throws -> URL {
            let url = h.directory.appendingPathComponent("v\(version).spinnetplugin")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try JSONEncoder().encode(h.package(types: types, version: version).manifest).write(to: url.appendingPathComponent("manifest.json"))
            try Data("null".utf8).write(to: url.appendingPathComponent("browse.js"))
            return url
        }
        func restart() throws {
            h.grants = PluginCapabilityGrantStore(grants: try JSONDecoder().decode([PluginCapabilityGrant].self, from: Data(contentsOf: grantsURL)))
            try h.restart()
        }
        h.board.clearContents(); h.board.setString("pre-grant text", forType: .string)
        h.board.setData(Data([1, 2, 3]), forType: .png)
        try h.collector.poll()
        let (settings, registry) = try session()
        settings.menuEditor.installPluginPackage(at: try source(types: ["text"], version: "1"))
        XCTAssertTrue(settings.privacy.installationConsentPresented)
        settings.privacy.finishPluginConsent(grant: true)
        XCTAssertEqual(try h.query(XCTUnwrap(registry.package(for: PluginID("reader")))) .entries.map(\.text), ["pre-grant text"])
        settings.menuEditor.installPluginPackage(at: try source(types: ["text", "image"], version: "2"))
        let updated = try XCTUnwrap(registry.package(for: PluginID("reader")))
        XCTAssertTrue(settings.privacy.installationConsentPresented)
        XCTAssertEqual(settings.privacy.pendingCapabilityRequests(for: updated.manifest), [.readClipboardHistory])
        XCTAssertThrowsError(try h.query(updated))
        settings.privacy.finishPluginConsent(grant: false)
        XCTAssertThrowsError(try h.query(updated))
        try restart()
        let (deniedSettings, deniedRegistry) = try session()
        let denied = try XCTUnwrap(deniedRegistry.package(for: PluginID("reader")))
        XCTAssertEqual(denied.manifest.version, "2")
        XCTAssertThrowsError(try h.query(denied))
        deniedSettings.privacy.showPluginSettings(denied.manifest.id)
        deniedSettings.privacy.setCapabilityDecision(.granted, for: denied.manifest.id, pluginVersion: "2", capability: .readClipboardHistory)
        XCTAssertEqual(Set(try h.query(denied).entries.map(\.contentType)), [.text, .image])
        try restart()
        let (restoredSettings, restoredRegistry) = try session()
        let restored = try XCTUnwrap(restoredRegistry.package(for: PluginID("reader")))
        XCTAssertEqual(restoredSettings.privacy.pendingCapabilityRequests(for: restored.manifest), [])
        let image = try XCTUnwrap(h.query(restored).entries.first { $0.contentType == .image })
        XCTAssertEqual(try h.chunk(restored, id: image.id).data, Data([1, 2, 3]))
    }

    func testExcludedApplicationsSettingsPersistAndControlTheCollectorWithoutReplayingCopies() throws {
        let h = try RichClipboardHistoryTests.Harness()
        let suite = "ClipboardExclusions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertTrue(model.clipboardHistory.excludedApplications.contains("com.apple.Passwords"))
        model.clipboardHistory.addExcludedApplication(bundleID: "com.apple.Preview")
        h.board.clearContents(); h.board.setString("excluded", forType: .string)
        try h.collector.poll()
        let package = try h.package(types: ["text"])
        h.grant(package)
        XCTAssertEqual(try h.query(package).entries, [])
        let restoredStore = try ClipboardHistoryStore(fileURL: h.directory.appendingPathComponent("history.json"))
        let restored = SettingsWindowModel(editor: try makeEditor(), metadata: .current, defaults: defaults,
            clipboardHistoryStore: restoredStore, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertTrue(restored.clipboardHistory.excludedApplications.contains("com.apple.Preview"))
        model.clipboardHistory.removeExcludedApplication(bundleID: "com.apple.Preview")
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).entries, [])
        h.board.clearContents(); h.board.setString("allowed", forType: .string)
        try h.collector.poll()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["allowed"])
        XCTAssertTrue(model.clipboardHistory.excludedApplications.contains("com.apple.keychainaccess"))
    }

    func testHistoryManagementShortcutsReuseSettingsWithoutChangingCollectionOrGrants() throws {
        let h = try RichClipboardHistoryTests.Harness()
        h.board.clearContents(); h.board.setString("to clear", forType: .string); try h.collector.poll()
        let package = try h.package(types: ["text"]); h.grant(package)
        let suite = "SpinnetHostTests.HistoryManagement.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let controller = SettingsWindowController(editor: try makeEditor(), capabilityGrantStore: h.grants,
            defaults: defaults, clipboardHistoryStore: h.store)
        controller.onClipboardSettingsWillChange = { try h.collector.resetBaseline() }
        controller.showClipboardIgnoredApplications()
        XCTAssertEqual(controller.currentPage, .privacyAndPermissions)
        XCTAssertNotNil(controller.clipboardExclusionsFocus)
        XCTAssertEqual(try h.query(package).entries.count, 1, "Opening management does not clear or enable collection")
        let cleared = expectation(description: "Host management clear completed")
        controller.clearClipboardHistory { error in
            XCTAssertNil(error)
            cleared.fulfill()
        }
        wait(for: [cleared], timeout: 2)
        XCTAssertEqual(try h.query(package).entries, [])
        XCTAssertTrue(h.store.settings.enabled)
        XCTAssertFalse(h.store.settings.paused)
        XCTAssertTrue(h.store.isApplicationExcluded("com.apple.Passwords"))
        h.board.clearContents(); h.board.setString("after clear", forType: .string); try h.collector.poll()
        XCTAssertEqual(try h.query(package).entries.map(\.text), ["after clear"], "Existing Plugin authorization survives Clear")
        controller.close()
    }

    func testSettingsClearDuringBackgroundClassificationNeverPublishesLegacyTextOrResurrectsPayloads() throws {
        let h = try RichClipboardHistoryTests.Harness()
        h.board.clearContents(); h.board.setString("# Restricted heading", forType: .string); try h.collector.poll()
        let archiveURL = h.directory.appendingPathComponent("history.json")
        var archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archiveURL)) as? [String: Any])
        var entries = try XCTUnwrap(archive["entries"] as? [[String: Any]])
        for index in entries.indices { entries[index]["contentType"] = "text"; entries[index]["format"] = "public.utf8-plain-text" }
        let id = try XCTUnwrap(UUID(uuidString: try XCTUnwrap(entries.first?["id"] as? String)))
        archive["entries"] = entries; archive.removeValue(forKey: "markdownClassificationVersion")
        try JSONSerialization.data(withJSONObject: archive).write(to: archiveURL)
        let writing = expectation(description: "background migration reached durable write")
        let gate = DispatchSemaphore(value: 0)
        var writes = 0
        h.store = try ClipboardHistoryStore(fileURL: archiveURL, writeFile: { data, url in
            writes += 1
            if writes == 1 {
                XCTAssertFalse(Thread.isMainThread)
                writing.fulfill()
                XCTAssertEqual(gate.wait(timeout: .now() + 3), .success)
            }
            try data.write(to: url, options: .atomic)
        })
        defer { gate.signal() }
        wait(for: [writing], timeout: 2)
        // These calls must fail promptly, not queue behind the blocked disk write.
        XCTAssertThrowsError(try h.store.query(dataTypes: ["text"]))
        XCTAssertThrowsError(try h.store.readContent(entryID: id, dataTypes: ["text"], offset: 0, length: 100))
        let suite = "ClipboardMigration." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, capabilityGrantStore: h.grants,
            defaults: defaults, clipboardHistoryStore: h.store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        let cleared = expectation(description: "Settings clear completed after migration")
        model.clipboardHistory.onChange = { cleared.fulfill() }
        model.clipboardHistory.clear()
        XCTAssertTrue(h.store.settings.enabled, "Settings reads do not wait for migration I/O")
        gate.signal(); wait(for: [cleared], timeout: 3)
        let rich = try h.package(types: ["rich_text"]); h.grant(rich)
        XCTAssertEqual(try h.query(rich).entries, [])
        XCTAssertThrowsError(try h.chunk(rich, id: id))
        try h.restart()
        XCTAssertEqual(try h.query(rich).entries, [])
        let payloads = h.directory.appendingPathComponent("clipboard-payloads")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: payloads.path), [])
    }

    func testClipboardPrivacyControlsTheHostStoreAndKeepsGrantIndependent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let suite = "ClipboardSettings." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let grants = PluginCapabilityGrantStore()
        grants.setDecision(.granted, for: PluginID("history"), pluginVersion: "1", capability: .readClipboardHistory)
        let model = SettingsWindowModel(editor: try makeEditor(), metadata: .current, capabilityGrantStore: grants,
            defaults: defaults, clipboardHistoryStore: store, accessibilityPermissionCheck: { true }, mouseInputConflictCheck: { _ in [] })
        XCTAssertFalse(model.clipboardHistory.collectionEnabled)
        model.clipboardHistory.collectionEnabled = true
        try store.observe(changeCount: 1, content: .init(text: "retained", type: .text), sourceName: "Notes", sourceBundleID: "notes")
        model.clipboardHistory.collectionPaused = true
        XCTAssertEqual(try store.query(dataTypes: ["text"]).state, .paused)
        let retentionSaved = expectation(description: "retention is durable")
        model.clipboardHistory.onChange = { retentionSaved.fulfill() }
        model.clipboardHistory.retention = .oneWeek
        wait(for: [retentionSaved], timeout: 2)
        model.clipboardHistory.onChange = nil
        XCTAssertEqual(store.settings.retentionDays, 7)
        model.clipboardHistory.turnOff(deleteEntries: false)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries.count, 1)
        model.clipboardHistory.clear()
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
        XCTAssertEqual(grants.decision(for: PluginID("history"), pluginVersion: "1", capability: .readClipboardHistory), .granted)
    }

}
