import AppKit
import Carbon
import Darwin
import SpinnetCore
import UniformTypeIdentifiers

protocol SelectedTextCopyClient {
    associatedtype ClipboardSnapshot

    func frontmostProcessIdentifier() -> pid_t?
    func snapshotClipboard() -> ClipboardSnapshot?
    func pasteboardChangeCount() -> Int
    func sendCommandC(to processIdentifier: pid_t) -> Bool
    func copiedPlainText() -> String?
    func restoreClipboard(
        _ snapshot: ClipboardSnapshot,
        onlyIfChangeCountIs expectedChangeCount: Int
    ) -> ClipboardRestoreOutcome
}

enum ClipboardRestoreOutcome: Equatable {
    case restored(changeCount: Int)
    case changedExternally
    case failed(currentChangeCount: Int)
}

enum SelectedTextCopyResult: Equatable {
    case selected(String)
    case noSelection
    case unavailable
}

/// Coordinates short-lived selected-text copies with clipboard-history samples.
/// The collector uses generation checks rather than holding a lock while it
/// reads large pasteboard representations or persists history.
final class ClipboardObservationGate {
    enum SampleDisposition: Equatable {
        case accept
        case discard
        case suppressed
    }

    struct Sample: Equatable {
        fileprivate let generation: UInt64
        fileprivate let operationIsActive: Bool
    }

    private let stateLock = NSLock()
    private let copySerializationSemaphore = DispatchSemaphore(value: 1)
    private var generation: UInt64 = 0
    private var activeCopies = 0
    private var suppressedChangeCount: Int?
    private var pendingLateCopy: (token: UUID, baselineChangeCount: Int)?

    /// Serializes selection-copy transactions and invalidates any collector
    /// sample that overlaps the temporary clipboard contents.
    func beginTransientCopy() -> Bool {
        guard copySerializationSemaphore.wait(timeout: .now() + .milliseconds(100)) == .success else {
            return false
        }
        stateLock.lock()
        generation &+= 1
        activeCopies += 1
        stateLock.unlock()
        return true
    }

    func finishTransientCopy(suppressing changeCount: Int?) {
        stateLock.lock()
        if let changeCount {
            suppressedChangeCount = changeCount
        }
        activeCopies = max(0, activeCopies - 1)
        generation &+= 1
        stateLock.unlock()
        copySerializationSemaphore.signal()
    }

    /// Transfers cleanup to a short-lived watcher so a delayed Command-C can't
    /// escape history suppression after the requesting service has timed out.
    func transferTransientCopyToLateCleanup(after baselineChangeCount: Int) -> UUID {
        let token = UUID()
        stateLock.lock()
        activeCopies = max(0, activeCopies - 1)
        pendingLateCopy = (token, baselineChangeCount)
        generation &+= 1
        stateLock.unlock()
        return token
    }

    func finishLateCopyCleanup(_ token: UUID, suppressing changeCount: Int?) {
        stateLock.lock()
        guard pendingLateCopy?.token == token else {
            stateLock.unlock()
            return
        }
        pendingLateCopy = nil
        suppressedChangeCount = changeCount
        generation &+= 1
        stateLock.unlock()
        copySerializationSemaphore.signal()
    }

    func beginSample() -> Sample {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Sample(generation: generation, operationIsActive: activeCopies > 0)
    }

    func disposition(for sample: Sample, changeCount: Int) -> SampleDisposition {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !sample.operationIsActive,
              activeCopies == 0,
              sample.generation == generation else {
            return .discard
        }
        if let pendingLateCopy,
           changeCount != pendingLateCopy.baselineChangeCount {
            suppressedChangeCount = changeCount
            return .suppressed
        }
        if suppressedChangeCount == changeCount {
            suppressedChangeCount = nil
            return .suppressed
        }
        if suppressedChangeCount != nil {
            // A later clipboard change belongs to the user or another app.
            // Do not hide it behind an older temporary-copy marker.
            suppressedChangeCount = nil
        }
        return .accept
    }
}

struct SelectedTextCopyFallback<Client: SelectedTextCopyClient> {
    static var defaultClipboardWait: TimeInterval { 0.75 }
    static var defaultClipboardStabilityWait: TimeInterval { 0.025 }
    static var defaultLateCopyCleanupWait: TimeInterval { 1 }
    static var defaultPollingInterval: TimeInterval { 0.01 }

    private let client: Client
    private let observationGate: ClipboardObservationGate
    private let clipboardWait: TimeInterval
    private let clipboardStabilityWait: TimeInterval
    private let lateCopyCleanupWait: TimeInterval
    private let pollingInterval: TimeInterval
    private let now: () -> TimeInterval
    private let wait: (TimeInterval) -> Void
    private let scheduleLateCleanup: (@escaping () -> Void) -> Void

    init(
        client: Client,
        observationGate: ClipboardObservationGate,
        clipboardWait: TimeInterval = Self.defaultClipboardWait,
        clipboardStabilityWait: TimeInterval = Self.defaultClipboardStabilityWait,
        lateCopyCleanupWait: TimeInterval = Self.defaultLateCopyCleanupWait,
        pollingInterval: TimeInterval = Self.defaultPollingInterval,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        scheduleLateCleanup: @escaping (@escaping () -> Void) -> Void = { work in
            DispatchQueue.global(qos: .utility).async(execute: work)
        }
    ) {
        self.client = client
        self.observationGate = observationGate
        self.clipboardWait = max(0, clipboardWait)
        self.clipboardStabilityWait = max(0, clipboardStabilityWait)
        self.lateCopyCleanupWait = max(0, lateCopyCleanupWait)
        self.pollingInterval = max(0.001, pollingInterval)
        self.now = now
        self.wait = wait
        self.scheduleLateCleanup = scheduleLateCleanup
    }

    /// Returns text only when a foreground app actually changed the pasteboard
    /// in response to a targeted Command-C. The previous pasteboard contents
    /// are restored only while the copy still owns the board.
    func readSelectedText() throws -> SelectedTextCopyResult {
        guard let processIdentifier = client.frontmostProcessIdentifier(), processIdentifier > 0 else {
            return .unavailable
        }

        guard observationGate.beginTransientCopy() else { return .unavailable }
        var changeCountToSuppress: Int?
        var cleanupTransferred = false
        defer {
            if !cleanupTransferred {
                observationGate.finishTransientCopy(suppressing: changeCountToSuppress)
            }
        }

        let initialChangeCount = client.pasteboardChangeCount()
        guard let snapshot = client.snapshotClipboard(),
              client.pasteboardChangeCount() == initialChangeCount else {
            return .unavailable
        }
        guard client.frontmostProcessIdentifier() == processIdentifier,
              client.sendCommandC(to: processIdentifier) else {
            return .unavailable
        }
        let response = waitForClipboardChange(
            after: initialChangeCount,
            from: processIdentifier
        )
        let copyChangeCount: Int
        switch response {
        case .changed(let count):
            copyChangeCount = count
        case .noChange:
            let currentCount = client.pasteboardChangeCount()
            guard currentCount == initialChangeCount else {
                // A clipboard change raced with the timeout check. Treat it as
                // an ambiguous copy response and keep it out of history.
                changeCountToSuppress = currentCount
                return .unavailable
            }
            transferToLateCleanup(
                snapshot: snapshot,
                baselineChangeCount: initialChangeCount,
                processIdentifier: processIdentifier,
                allowClipboardRestore: true
            )
            cleanupTransferred = true
            return .noSelection
        case .interrupted:
            let currentCount = client.pasteboardChangeCount()
            if currentCount != initialChangeCount {
                changeCountToSuppress = currentCount
            }
            transferToLateCleanup(
                snapshot: snapshot,
                baselineChangeCount: initialChangeCount,
                processIdentifier: processIdentifier,
                allowClipboardRestore: false
            )
            cleanupTransferred = true
            return .unavailable
        }

        // If restoring fails while the selected text is still the current
        // pasteboard contents, keep the collector from retaining that text.
        changeCountToSuppress = copyChangeCount
        guard client.pasteboardChangeCount() == copyChangeCount else { return .unavailable }
        let selectedText = client.copiedPlainText()
        guard client.pasteboardChangeCount() == copyChangeCount else { return .unavailable }

        switch client.restoreClipboard(snapshot, onlyIfChangeCountIs: copyChangeCount) {
        case .restored(let restoredChangeCount):
            changeCountToSuppress = restoredChangeCount
        case .changedExternally:
            // A user or clipboard manager replaced our copy. Keep their newer
            // contents and do not suppress that pasteboard change.
            changeCountToSuppress = nil
        case .failed(let currentChangeCount):
            changeCountToSuppress = currentChangeCount
            throw PluginHostServiceError.failed("The previous clipboard contents could not be restored")
        }

        guard let selectedText, !selectedText.isEmpty else { return .unavailable }
        return .selected(selectedText)
    }

    private func transferToLateCleanup(
        snapshot: Client.ClipboardSnapshot,
        baselineChangeCount: Int,
        processIdentifier: pid_t,
        allowClipboardRestore: Bool
    ) {
        let token = observationGate.transferTransientCopyToLateCleanup(
            after: baselineChangeCount
        )
        scheduleLateCleanup { [client, observationGate, now, wait, pollingInterval,
                               clipboardStabilityWait, lateCopyCleanupWait] in
            Self.cleanupLateCopy(
                client: client,
                observationGate: observationGate,
                token: token,
                snapshot: snapshot,
                baselineChangeCount: baselineChangeCount,
                processIdentifier: processIdentifier,
                allowClipboardRestore: allowClipboardRestore,
                watchDuration: lateCopyCleanupWait,
                stabilityWait: clipboardStabilityWait,
                pollingInterval: pollingInterval,
                now: now,
                wait: wait
            )
        }
    }

    /// NSPasteboard doesn't expose the process that wrote a general-pasteboard
    /// change. Keep the attribution window narrow by requiring the targeted app
    /// to stay frontmost and the first changed count to remain stable briefly.
    private enum ClipboardChangeResponse {
        case changed(Int)
        case noChange
        case interrupted
    }

    private func waitForClipboardChange(
        after initialChangeCount: Int,
        from processIdentifier: pid_t
    ) -> ClipboardChangeResponse {
        let deadline = now() + clipboardWait
        while true {
            guard client.frontmostProcessIdentifier() == processIdentifier else { return .interrupted }
            let currentChangeCount = client.pasteboardChangeCount()
            guard client.frontmostProcessIdentifier() == processIdentifier else { return .interrupted }
            if currentChangeCount != initialChangeCount {
                guard let stableChangeCount = waitForStableClipboardChange(
                    currentChangeCount,
                    from: processIdentifier
                ) else { return .interrupted }
                return .changed(stableChangeCount)
            }

            let remaining = deadline - now()
            guard remaining > 0 else { return .noChange }
            wait(min(pollingInterval, remaining))
        }
    }

    private func waitForStableClipboardChange(_ expectedChangeCount: Int, from processIdentifier: pid_t) -> Int? {
        let deadline = now() + clipboardStabilityWait
        while true {
            guard client.frontmostProcessIdentifier() == processIdentifier,
                  client.pasteboardChangeCount() == expectedChangeCount,
                  client.frontmostProcessIdentifier() == processIdentifier else {
                return nil
            }

            let remaining = deadline - now()
            guard remaining > 0 else { return expectedChangeCount }
            wait(min(pollingInterval, remaining))
        }
    }

    private static func cleanupLateCopy(
        client: Client,
        observationGate: ClipboardObservationGate,
        token: UUID,
        snapshot: Client.ClipboardSnapshot,
        baselineChangeCount: Int,
        processIdentifier: pid_t,
        allowClipboardRestore: Bool,
        watchDuration: TimeInterval,
        stabilityWait: TimeInterval,
        pollingInterval: TimeInterval,
        now: () -> TimeInterval,
        wait: (TimeInterval) -> Void
    ) {
        let deadline = now() + watchDuration
        while true {
            let currentChangeCount = client.pasteboardChangeCount()
            if currentChangeCount != baselineChangeCount {
                var suppressedChangeCount: Int? = currentChangeCount
                if allowClipboardRestore,
                   client.frontmostProcessIdentifier() == processIdentifier,
                   isStable(
                       currentChangeCount,
                       from: processIdentifier,
                       client: client,
                       stabilityWait: stabilityWait,
                       pollingInterval: pollingInterval,
                       now: now,
                       wait: wait
                   ) {
                    switch client.restoreClipboard(snapshot, onlyIfChangeCountIs: currentChangeCount) {
                    case .restored(let restoredChangeCount):
                        suppressedChangeCount = restoredChangeCount
                    case .changedExternally:
                        suppressedChangeCount = nil
                    case .failed(let count):
                        suppressedChangeCount = count
                    }
                }
                observationGate.finishLateCopyCleanup(token, suppressing: suppressedChangeCount)
                return
            }

            let remaining = deadline - now()
            guard remaining > 0 else {
                observationGate.finishLateCopyCleanup(token, suppressing: nil)
                return
            }
            wait(min(pollingInterval, remaining))
        }
    }

    private static func isStable(
        _ expectedChangeCount: Int,
        from processIdentifier: pid_t,
        client: Client,
        stabilityWait: TimeInterval,
        pollingInterval: TimeInterval,
        now: () -> TimeInterval,
        wait: (TimeInterval) -> Void
    ) -> Bool {
        let deadline = now() + stabilityWait
        while true {
            guard client.frontmostProcessIdentifier() == processIdentifier,
                  client.pasteboardChangeCount() == expectedChangeCount,
                  client.frontmostProcessIdentifier() == processIdentifier else {
                return false
            }

            let remaining = deadline - now()
            guard remaining > 0 else { return true }
            wait(min(pollingInterval, remaining))
        }
    }
}

struct AppKitSelectedTextCopyClient: SelectedTextCopyClient {
    struct ClipboardSnapshot {
        let items: [[Representation]]
    }

    struct Representation {
        enum Value {
            case data(Data)
            case propertyList(Any)
        }

        let type: NSPasteboard.PasteboardType
        let value: Value
        let byteCount: Int
    }

    private static let maximumSnapshotItems = 64
    private static let maximumSnapshotRepresentations = 256
    private static let maximumSnapshotBytes = 32 * 1_024 * 1_024

    func frontmostProcessIdentifier() -> pid_t? {
        let application = onMain { NSWorkspace.shared.frontmostApplication }
        guard let application,
              application.processIdentifier != getpid() else {
            return nil
        }
        return application.processIdentifier
    }

    func snapshotClipboard() -> ClipboardSnapshot? {
        onMain {
            let pasteboard = NSPasteboard.general
            let initialChangeCount = pasteboard.changeCount
            let items: [NSPasteboardItem]
            if let pasteboardItems = pasteboard.pasteboardItems {
                items = pasteboardItems
            } else if pasteboard.types?.isEmpty ?? true {
                items = []
            } else {
                return nil
            }
            guard items.count <= Self.maximumSnapshotItems else { return nil }

            var representationCount = 0
            var totalBytes = 0
            var snapshotItems: [[Representation]] = []
            snapshotItems.reserveCapacity(items.count)

            for item in items {
                var representations: [Representation] = []
                for type in item.types {
                    representationCount += 1
                    guard representationCount <= Self.maximumSnapshotRepresentations else { return nil }
                    let representation: Representation
                    if let data = item.data(forType: type) {
                        representation = Representation(type: type, value: .data(data), byteCount: data.count)
                    } else if let value = copiedPropertyList(item.propertyList(forType: type)) {
                        representation = Representation(type: type, value: .propertyList(value.value), byteCount: value.byteCount)
                    } else if isPlainText(type), let string = item.string(forType: type) {
                        representation = Representation(type: type, value: .propertyList(string), byteCount: string.utf8.count)
                    } else {
                        // Promised or unreadable representations make a full
                        // restore impossible, so fail closed before Command-C.
                        return nil
                    }
                    totalBytes += representation.byteCount
                    guard totalBytes <= Self.maximumSnapshotBytes else { return nil }
                    representations.append(representation)
                }
                snapshotItems.append(representations)
            }
            guard pasteboard.changeCount == initialChangeCount else { return nil }
            return ClipboardSnapshot(items: snapshotItems)
        }
    }

    func pasteboardChangeCount() -> Int {
        onMain { NSPasteboard.general.changeCount }
    }

    func sendCommandC(to processIdentifier: pid_t) -> Bool {
        guard let keyDown = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(kVK_ANSI_C),
            keyDown: false
        ) else {
            return false
        }

        let flags = CGEventFlags.maskCommand
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
        return true
    }

    func copiedPlainText() -> String? {
        onMain {
            guard let items = NSPasteboard.general.pasteboardItems else { return nil }
            for item in items {
                for type in item.types where isPlainText(type) {
                    if let text = item.string(forType: type) { return text }
                    if let data = item.data(forType: type),
                       let text = decodeText(data, type: type) {
                        return text
                    }
                }
            }
            return nil
        }
    }

    func restoreClipboard(
        _ snapshot: ClipboardSnapshot,
        onlyIfChangeCountIs expectedChangeCount: Int
    ) -> ClipboardRestoreOutcome {
        onMain {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expectedChangeCount else { return .changedExternally }

            var items: [NSPasteboardItem] = []
            items.reserveCapacity(snapshot.items.count)
            for representationGroup in snapshot.items {
                let item = NSPasteboardItem()
                for representation in representationGroup {
                    let wasSet: Bool
                    switch representation.value {
                    case .data(let data):
                        wasSet = item.setData(data, forType: representation.type)
                    case .propertyList(let value):
                        wasSet = item.setPropertyList(value, forType: representation.type)
                    }
                    guard wasSet else { return .failed(currentChangeCount: pasteboard.changeCount) }
                }
                items.append(item)
            }

            let countBeforeClear = pasteboard.changeCount
            _ = pasteboard.clearContents()
            guard pasteboard.changeCount != countBeforeClear else {
                return .failed(currentChangeCount: pasteboard.changeCount)
            }
            if !items.isEmpty, !pasteboard.writeObjects(items) {
                return .failed(currentChangeCount: pasteboard.changeCount)
            }
            return .restored(changeCount: pasteboard.changeCount)
        }
    }

    private func copiedPropertyList(_ value: Any?) -> (value: Any, byteCount: Int)? {
        guard let value,
              let data = try? PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0),
              let copied = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return nil
        }
        return (copied, data.count)
    }

    private func isPlainText(_ type: NSPasteboard.PasteboardType) -> Bool {
        if type == .string { return true }
        let stringTypeIdentifiers: Set<String> = [
            UTType.plainText.identifier,
            "public.text",
            "public.utf8-plain-text",
            "public.utf16-plain-text",
            "public.utf16-external-plain-text",
            "public.markdown"
        ]
        return stringTypeIdentifiers.contains(type.rawValue)
            || UTType(type.rawValue)?.conforms(to: .plainText) == true
    }

    private func decodeText(_ data: Data, type: NSPasteboard.PasteboardType) -> String? {
        if type.rawValue.contains("utf16") {
            return String(data: data, encoding: .utf16)
                ?? String(data: data, encoding: .utf16LittleEndian)
                ?? String(data: data, encoding: .utf16BigEndian)
        }
        return String(data: data, encoding: .utf8)
    }

    private func onMain<Value>(_ work: () -> Value) -> Value {
        Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work)
    }
}
