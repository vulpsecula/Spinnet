import AppKit
import SwiftUI
import SpinnetCore

/// Host-rendered browsing state. Refreshes call the same public broker as the
/// Plugin invocation; the window never holds a store or a helper connection.
final class ClipboardHistoryWindowModel: ObservableObject {
    @Published private(set) var snapshot: ClipboardHistorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var accessDenied = false
    @Published private(set) var isLoading = false
    private let queryQueue = DispatchQueue(label: "com.spinnet.clipboard-history-query", qos: .userInitiated)
    private var queryRevision = UUID()
    private var queuedQuery: (id: UUID, offset: Int)?
    private var querying = false
    private(set) var offset = 0
    private var expiration: DispatchWorkItem?
    private let query: (Int) throws -> ClipboardHistorySnapshot

    init(query: @escaping (Int) throws -> ClipboardHistorySnapshot) { self.query = query }

    func refresh(offset: Int = 0) {
        discardSnapshot()
        error = nil
        accessDenied = false
        self.offset = offset
        isLoading = true
        queuedQuery = (queryRevision, offset)
        runNextQuery()
    }

    /// The broker can wait behind disk writes. Never do that on the main thread;
    /// coalesce refreshes and reject responses invalidated by close/revocation.
    private func runNextQuery() {
        guard !querying, let request = queuedQuery else { return }
        queuedQuery = nil
        querying = true
        queryQueue.async { [self] in
            let result = Result { try query(request.offset) }
            DispatchQueue.main.async { [self] in
                querying = false
                if queryRevision == request.id { apply(result) }
                runNextQuery()
            }
        }
    }

    private func apply(_ response: Result<ClipboardHistorySnapshot, Error>) {
        isLoading = false
        do {
            let result = try response.get()
            if let expiry = result.expiresAt {
                guard expiry > Date() else { error = "Entries expired. Refresh to see retained history."; return }
                let task = DispatchWorkItem { [weak self] in
                    self?.discardSnapshot()
                    self?.error = "Entries expired. Refresh to see retained history."
                }
                expiration = task
                DispatchQueue.main.asyncAfter(deadline: .now() + expiry.timeIntervalSinceNow, execute: task)
            }
            snapshot = result
        }
        catch {
            accessDenied = (error as? PluginHostServiceError) == .capabilityDenied(.readClipboardHistory)
            self.error = accessDenied ? "Clipboard History access is not granted to this Plugin." : error.localizedDescription
        }
    }

    func discardSnapshot() {
        queryRevision = UUID()
        queuedQuery = nil
        isLoading = false
        expiration?.cancel()
        expiration = nil
        snapshot = nil
    }
    deinit { expiration?.cancel() }
}

struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryWindowModel
    let openPrivacy: () -> Void
    let openPluginSettings: () -> Void
    let openIgnoredApplications: () -> Void
    let clearHistory: (@escaping (String?) -> Void) -> Void
    @State private var clearing = false
    @State private var managementError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard History").font(.title2)
                Spacer()
                Button("Refresh") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Plugin Settings…", action: openPluginSettings)
            }
            HStack {
                ClipboardHistoryClearButton {
                    clearing = true
                    managementError = nil
                    clearHistory { error in
                        clearing = false
                        managementError = error
                        model.refresh()
                    }
                }.disabled(clearing)
                Button("Ignored Applications…", action: openIgnoredApplications)
                if clearing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if let managementError { Text(managementError).foregroundStyle(.red) }
            if model.isLoading {
                ProgressView("Loading Clipboard History…")
            } else if let error = model.error {
                Text(error).foregroundStyle(.secondary)
                if model.accessDenied { Button("Manage Access in Library…", action: openPluginSettings) }
            } else if let snapshot = model.snapshot {
                if snapshot.state != .collecting {
                    HStack {
                        Text(snapshot.state == .off
                             ? "Collection is off. Retained entries remain readable until they expire."
                             : "Collection is paused. No new entries are collected.").foregroundStyle(.secondary)
                        Button("Open Privacy Settings…", action: openPrivacy)
                    }
                }
                if snapshot.entries.isEmpty {
                    Text(snapshot.state == .collecting
                         ? "No retained entries. Copy text, an image, rich text, a file, or other content, then refresh."
                         : "No retained entries. Enable or resume collection in Privacy Settings to collect new copies.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(snapshot.copies) { copy in
                        ClipboardHistoryCopyRow(copy: copy)
                    }
                    HStack {
                        Button("Newest") { model.refresh() }.disabled(model.offset == 0)
                        Spacer()
                        if let next = snapshot.nextOffset {
                            Button(snapshot.continuingCopyID == nil ? "Older Entries" : "More Representations") { model.refresh(offset: next) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }.padding(20).frame(minWidth: 680, minHeight: 420)
    }
}

final class ClipboardHistoryWindow: NSWindowController, NSWindowDelegate {
    let model: ClipboardHistoryWindowModel
    private let grants: PluginCapabilityGrantStore
    private var observer: UUID?

    init(grants: PluginCapabilityGrantStore, query: @escaping (Int) throws -> ClipboardHistorySnapshot,
         openPrivacy: @escaping () -> Void, openPluginSettings: @escaping () -> Void,
         openIgnoredApplications: @escaping () -> Void,
         clearHistory: @escaping (@escaping (String?) -> Void) -> Void) {
        self.grants = grants
        model = ClipboardHistoryWindowModel(query: query)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Clipboard History"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClipboardHistoryView(model: model, openPrivacy: openPrivacy,
            openPluginSettings: openPluginSettings, openIgnoredApplications: openIgnoredApplications, clearHistory: clearHistory))
        window.center()
        observer = grants.observeChanges { [weak self] in
            if Thread.isMainThread { self?.refreshIfVisible() }
            else { DispatchQueue.main.async { [weak self] in self?.refreshIfVisible() } }
        }
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }
    deinit { if let observer { grants.removeChangeObserver(observer) } }
    func refreshIfVisible() {
        model.discardSnapshot()
        if window?.isVisible == true { model.refresh() }
    }
    func windowWillClose(_ notification: Notification) { model.discardSnapshot() }
    func present() {
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }
}
