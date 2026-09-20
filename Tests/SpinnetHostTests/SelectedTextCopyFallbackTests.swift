import XCTest
import SpinnetCore
@testable import SpinnetHost

final class SelectedTextCopyFallbackTests: XCTestCase {
    func testSimulatedCopyReadsSelectionRestoresClipboardAndSkipsHistoryCapture() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "previous clipboard"
        client.changeCount = 10
        client.selectionText = "selected Telegram text"
        let observationGate = ClipboardObservationGate()
        var reads = 0
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        let collector = ClipboardCollector(
            store: store,
            changeCount: { client.changeCount },
            readContent: {
                reads += 1
                return client.clipboardText.map { ClipboardContent(text: $0, type: .text) }
            },
            sourceApplication: { ("Telegram", "ru.keepcoder.Telegram") },
            observationGate: observationGate
        )
        try collector.resetBaseline()

        let fallback = SelectedTextCopyFallback(
            client: client,
            observationGate: observationGate,
            now: { client.clock },
            wait: { client.advanceClock(by: $0) },
            scheduleLateCleanup: { $0() }
        )
        let selectedText = try fallback.readSelectedText()

        XCTAssertEqual(selectedText, .selected("selected Telegram text"))
        XCTAssertEqual(client.commandCopyTargets, [4242])
        XCTAssertEqual(client.clipboardText, "previous clipboard")
        XCTAssertEqual(client.changeCount, 12)

        try collector.poll()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
    }

    func testDoesNotSendCopyWhenClipboardCannotBeSnapshotted() throws {
        let client = FakeSelectedTextCopyClient()
        client.snapshotAvailable = false
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .unavailable)
        XCTAssertTrue(client.commandCopyTargets.isEmpty)
        XCTAssertNil(client.clipboardText)
    }

    func testDoesNotSendCopyOrRestoreAnOlderSnapshotWhenClipboardChangesDuringSnapshot() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.changeCount = 10
        client.clipboardTextAfterSnapshot = "new user clipboard"
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .unavailable)
        XCTAssertTrue(client.commandCopyTargets.isEmpty)
        XCTAssertEqual(client.clipboardText, "new user clipboard")
        XCTAssertEqual(client.changeCount, 11)
    }

    func testDoesNotReadOrRestoreClipboardWhenTargetLosesFocusDuringCopy() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.clipboardTextAfterCommand = "new clipboard contents"
        client.processIdentifierAfterCommand = 777
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .unavailable)
        XCTAssertEqual(client.clipboardText, "new clipboard contents")
        XCTAssertEqual(client.changeCount, 1)
    }

    func testReadsAndRestoresASelectionWhenCopyResponseTakesLongerThanTheOldWait() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.changeCount = 10
        client.selectionText = "delayed selected text"
        client.copyDelay = 0.5
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .selected("delayed selected text"))
        XCTAssertEqual(client.clipboardText, "before")
        XCTAssertEqual(client.changeCount, 12)
    }

    func testRejectsSelectionIfClipboardChangesAgainBeforeTheCopyResponseStabilizes() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.selectionText = "selected text"
        client.scheduleClipboardWrite(after: 0.01, text: "new clipboard contents")
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .unavailable)
        XCTAssertEqual(client.clipboardText, "new clipboard contents")
        XCTAssertEqual(client.changeCount, 2)
    }

    func testLateCopyAfterTimeoutIsRestoredAndExcludedFromHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.changeCount = 10
        client.selectionText = "late selected text"
        client.copyDelay = 0.8
        let observationGate = ClipboardObservationGate()
        var reads = 0
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        let collector = ClipboardCollector(
            store: store,
            changeCount: { client.changeCount },
            readContent: {
                reads += 1
                return client.clipboardText.map { ClipboardContent(text: $0, type: .text) }
            },
            sourceApplication: { ("Telegram", "ru.keepcoder.Telegram") },
            observationGate: observationGate
        )
        try collector.resetBaseline()

        var lateCleanup: (() -> Void)?
        let fallback = SelectedTextCopyFallback(
            client: client,
            observationGate: observationGate,
            now: { client.clock },
            wait: { client.advanceClock(by: $0) },
            scheduleLateCleanup: { lateCleanup = $0 }
        )

        XCTAssertEqual(try fallback.readSelectedText(), .noSelection)
        XCTAssertEqual(client.clock, SelectedTextCopyFallback<FakeSelectedTextCopyClient>.defaultClipboardWait, accuracy: 0.001)
        XCTAssertNotNil(lateCleanup)

        client.advanceClock(by: 0.05)
        XCTAssertEqual(client.clipboardText, "late selected text")
        try collector.poll()
        XCTAssertEqual(reads, 0)

        lateCleanup?()
        XCTAssertEqual(client.clipboardText, "before")
        try collector.poll()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
    }

    func testLeavesClipboardAloneWhenItChangesAfterSelectionWasRead() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "before"
        client.selectionText = "the selection"
        client.externalClipboardTextAfterRead = "new user clipboard"
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .selected("the selection"))
        XCTAssertEqual(client.clipboardText, "new user clipboard")
        XCTAssertEqual(client.changeCount, 2)
    }

    func testRestoreFailureIsReportedAndSelectionCountIsStillSuppressed() throws {
        let client = FakeSelectedTextCopyClient()
        client.selectionText = "selection"
        client.restoreFails = true
        let observationGate = ClipboardObservationGate()
        let fallback = makeFallback(client, observationGate: observationGate)

        XCTAssertThrowsError(try fallback.readSelectedText())

        let sample = observationGate.beginSample()
        XCTAssertEqual(
            observationGate.disposition(for: sample, changeCount: client.changeCount),
            .suppressed
        )
    }

    func testDoesNotReturnClipboardTextWhenCopyDoesNotChangePasteboard() throws {
        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "clipboard contents"
        client.copiesOnCommand = false
        let fallback = makeFallback(client)

        XCTAssertEqual(try fallback.readSelectedText(), .noSelection)
        XCTAssertEqual(client.clipboardText, "clipboard contents")
        XCTAssertEqual(client.changeCount, 0)
    }

    func testCopyFollowedByFocusLossDuringStabilizationDoesNotEnterHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let client = FakeSelectedTextCopyClient()
        client.clipboardText = "previous clipboard"
        client.changeCount = 10
        client.selectionText = "selected Telegram text"
        client.processIdentifierChangeAt = 0.01
        client.processIdentifierAfterDelay = 777
        let observationGate = ClipboardObservationGate()
        var reads = 0
        let store = try ClipboardHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        try store.applyControl(.configure(enabled: true, paused: false, retentionDays: 1))
        let collector = ClipboardCollector(
            store: store,
            changeCount: { client.changeCount },
            readContent: {
                reads += 1
                return client.clipboardText.map { ClipboardContent(text: $0, type: .text) }
            },
            sourceApplication: { ("Telegram", "ru.keepcoder.Telegram") },
            observationGate: observationGate
        )
        try collector.resetBaseline()
        let fallback = makeFallback(client, observationGate: observationGate)

        XCTAssertEqual(try fallback.readSelectedText(), .unavailable)
        XCTAssertEqual(client.processIdentifier, 777)
        XCTAssertEqual(client.clipboardText, "selected Telegram text")

        try collector.poll()
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try store.query(dataTypes: ["text"]).entries, [])
    }

    private func makeFallback(
        _ client: FakeSelectedTextCopyClient,
        observationGate: ClipboardObservationGate = ClipboardObservationGate()
    ) -> SelectedTextCopyFallback<FakeSelectedTextCopyClient> {
        SelectedTextCopyFallback(
            client: client,
            observationGate: observationGate,
            now: { client.clock },
            wait: { client.advanceClock(by: $0) },
            scheduleLateCleanup: { $0() }
        )
    }
}

private final class FakeSelectedTextCopyClient: SelectedTextCopyClient {
    struct ClipboardSnapshot {
        let text: String?
    }

    var processIdentifier: pid_t? = 4242
    var clipboardText: String?
    var changeCount = 0
    var selectionText = "copied selection"
    var snapshotAvailable = true
    var copiesOnCommand = true
    var restoreFails = false
    var externalClipboardTextAfterRead: String?
    var clipboardTextAfterSnapshot: String?
    var clipboardTextAfterCommand: String?
    var processIdentifierAfterCommand: pid_t?
    var processIdentifierChangeAt: TimeInterval?
    var processIdentifierAfterDelay: pid_t?
    var copyDelay: TimeInterval = 0
    var clock: TimeInterval = 0
    private var pendingCopyAt: TimeInterval?
    private var pendingClipboardWrite: (time: TimeInterval, text: String)?
    private(set) var commandCopyTargets: [pid_t] = []

    func frontmostProcessIdentifier() -> pid_t? { processIdentifier }

    func snapshotClipboard() -> ClipboardSnapshot? {
        guard snapshotAvailable else { return nil }
        let snapshot = ClipboardSnapshot(text: clipboardText)
        if let clipboardTextAfterSnapshot {
            self.clipboardTextAfterSnapshot = nil
            self.clipboardText = clipboardTextAfterSnapshot
            changeCount += 1
        }
        return snapshot
    }

    func pasteboardChangeCount() -> Int {
        applyPendingClipboardWritesIfDue()
        return changeCount
    }

    func sendCommandC(to processIdentifier: pid_t) -> Bool {
        commandCopyTargets.append(processIdentifier)
        if let clipboardTextAfterCommand {
            self.clipboardTextAfterCommand = nil
            clipboardText = clipboardTextAfterCommand
            changeCount += 1
            if let processIdentifierAfterCommand {
                self.processIdentifier = processIdentifierAfterCommand
            }
            return true
        }
        guard copiesOnCommand else { return true }
        if copyDelay > 0 {
            pendingCopyAt = clock + copyDelay
        } else {
            writeSelectionToClipboard()
        }
        return true
    }

    func copiedPlainText() -> String? {
        applyPendingClipboardWritesIfDue()
        return clipboardText
    }

    func restoreClipboard(
        _ snapshot: ClipboardSnapshot,
        onlyIfChangeCountIs expectedChangeCount: Int
    ) -> ClipboardRestoreOutcome {
        applyPendingClipboardWritesIfDue()
        if let externalClipboardTextAfterRead {
            self.externalClipboardTextAfterRead = nil
            clipboardText = externalClipboardTextAfterRead
            changeCount += 1
            return .changedExternally
        }
        guard changeCount == expectedChangeCount else { return .changedExternally }
        if restoreFails { return .failed(currentChangeCount: changeCount) }
        clipboardText = snapshot.text
        changeCount += 1
        return .restored(changeCount: changeCount)
    }

    func advanceClock(by interval: TimeInterval) {
        clock += interval
        if let processIdentifierChangeAt,
           clock >= processIdentifierChangeAt,
           let processIdentifierAfterDelay {
            processIdentifier = processIdentifierAfterDelay
            self.processIdentifierChangeAt = nil
            self.processIdentifierAfterDelay = nil
        }
        applyPendingClipboardWritesIfDue()
    }

    func scheduleClipboardWrite(after delay: TimeInterval, text: String) {
        pendingClipboardWrite = (clock + delay, text)
    }

    private func writeSelectionToClipboard() {
        clipboardText = selectionText
        changeCount += 1
    }

    private func applyPendingClipboardWritesIfDue() {
        if let pendingCopyAt, clock >= pendingCopyAt {
            self.pendingCopyAt = nil
            writeSelectionToClipboard()
        }
        if let pendingClipboardWrite, clock >= pendingClipboardWrite.time {
            self.pendingClipboardWrite = nil
            clipboardText = pendingClipboardWrite.text
            changeCount += 1
        }
    }
}
