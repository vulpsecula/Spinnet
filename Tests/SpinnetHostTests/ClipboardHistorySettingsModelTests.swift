import XCTest
import SpinnetCore
@testable import SpinnetHost

/// Clipboard History settings are reachable with a Store on a temporary file
/// and a UserDefaults suite. Before the split, reaching this behaviour meant
/// building a whole SettingsWindowModel, which also pulls in the configuration
/// editor, an Accessibility probe and a mouse-conflict probe.
final class ClipboardHistorySettingsModelTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")
    private var suiteName = ""
    private var defaults = UserDefaults.standard

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpinnetHostTests.ClipboardSettings.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "SpinnetHostTests.ClipboardSettings.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeStore() throws -> ClipboardHistoryStore {
        try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
    }

    /// Persistence is asynchronous, so a settled model is one whose submission
    /// has come back from the Store.
    private func settle(_ model: ClipboardHistorySettingsModel) {
        let done = expectation(description: "settings settled")
        DispatchQueue.main.async { [weak model] in
            guard let model, model.isSaving else { return done.fulfill() }
            let deadline = Date(timeIntervalSinceNow: 2)
            func poll() {
                if !model.isSaving || Date() > deadline { return done.fulfill() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
            }
            poll()
        }
        wait(for: [done], timeout: 3)
    }

    func testEnablingCollectionReachesTheStore() throws {
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)
        XCTAssertFalse(model.collectionEnabled)

        model.collectionEnabled = true
        settle(model)

        XCTAssertTrue(store.settings.enabled)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isSaving)
    }

    func testRetentionIsSubmittedInDays() throws {
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)
        model.collectionEnabled = true
        settle(model)

        model.retention = .oneMonth
        settle(model)

        XCTAssertEqual(store.settings.retentionDays, 30)
    }

    func testStatusDescribesEachCollectionState() throws {
        let model = ClipboardHistorySettingsModel(store: try makeStore(), defaults: defaults)
        XCTAssertTrue(model.status.hasPrefix("Off"))

        model.collectionEnabled = true
        settle(model)
        XCTAssertTrue(model.status.hasPrefix("On"))

        model.collectionPaused = true
        settle(model)
        XCTAssertTrue(model.status.hasPrefix("Paused"))
    }

    /// The Host resets the collector's pasteboard baseline before a settings
    /// change. If that fails, the change must not reach the Store, otherwise
    /// enabling collection could retroactively capture the current pasteboard.
    func testAVetoFromOnWillChangeBlocksTheSubmission() throws {
        struct Refused: LocalizedError {
            var errorDescription: String? { "Baseline could not be reset" }
        }
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)
        model.onWillChange = { throw Refused() }

        model.collectionEnabled = true

        XCTAssertEqual(model.error, "Baseline could not be reset")
        XCTAssertFalse(store.settings.enabled, "A vetoed change never reaches the Store")
        XCTAssertTrue(model.status.hasPrefix("Clipboard History error:"))
    }

    func testExclusionsKeepTheBuiltInEntriesAndReachTheStore() throws {
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)

        model.addExcludedApplication(bundleID: "  com.example.Vault  ")
        settle(model)

        XCTAssertTrue(model.excludedApplications.contains("com.example.Vault"),
                      "The bundle identifier is trimmed before it is stored")
        for builtIn in ClipboardHistoryStore.defaultExcludedApplications {
            XCTAssertTrue(model.excludedApplications.contains(builtIn),
                          "\(builtIn) stays excluded and cannot be removed by editing the list")
        }
        XCTAssertTrue(store.isApplicationExcluded("com.example.Vault"))

        model.removeExcludedApplication(bundleID: "com.example.Vault")
        settle(model)
        XCTAssertFalse(store.isApplicationExcluded("com.example.Vault"))
    }

    func testTurningOffShowsTheSwitchImmediatelyAndClearsOnRequest() throws {
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)
        model.collectionEnabled = true
        settle(model)

        model.turnOff(deleteEntries: true)
        XCTAssertFalse(model.collectionEnabled, "The switch moves before persistence finishes")
        settle(model)

        XCTAssertFalse(store.settings.enabled)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
    }

    func testTheModelReportsWhatTheStoreCommittedRatherThanWhatWasRequested() throws {
        let store = try makeStore()
        let model = ClipboardHistorySettingsModel(store: store, defaults: defaults)
        var changes = 0
        model.onChange = { changes += 1 }

        model.collectionEnabled = true
        settle(model)

        XCTAssertEqual(model.collectionEnabled, store.settings.enabled)
        XCTAssertEqual(model.retention.hours / 24, store.settings.retentionDays)
        XCTAssertGreaterThan(changes, 0)
    }

    func testWithoutAStoreTheSettingsStillPersistLocally() {
        let model = ClipboardHistorySettingsModel(store: nil, defaults: defaults)
        model.collectionEnabled = true
        model.retention = .oneWeek

        let reopened = ClipboardHistorySettingsModel(store: nil, defaults: defaults)
        XCTAssertTrue(reopened.collectionEnabled)
        XCTAssertEqual(reopened.retention, .oneWeek)
        XCTAssertFalse(model.isSaving, "There is nothing to wait for without a Store")
    }
}
