import AppKit
import SwiftUI
import SpinnetCore

/// Host-rendered browsing state. Refreshes call the same public broker as the
/// Plugin invocation; the window never holds a store or a helper connection.
final class ClipboardHistoryWindowModel: ObservableObject {
    @Published private(set) var snapshot: ClipboardHistorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var accessDenied = false
    private(set) var offset = 0
    private var expiration: DispatchWorkItem?
    private let query: (Int) throws -> ClipboardHistorySnapshot

    init(query: @escaping (Int) throws -> ClipboardHistorySnapshot) { self.query = query }

    func refresh(offset: Int = 0) {
        discardSnapshot()
        error = nil
        accessDenied = false
        self.offset = offset
        do {
            let result = try query(offset)
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
        expiration?.cancel()
        expiration = nil
        snapshot = nil
    }
    deinit { expiration?.cancel() }
}

private struct ClipboardHistoryView: View {
    @ObservedObject var model: ClipboardHistoryWindowModel
    let openPrivacy: () -> Void
    let openPluginSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Clipboard History").font(.title2)
                Spacer()
                Button("Refresh") { model.refresh() }.keyboardShortcut("r", modifiers: .command)
                Button("Plugin Settings…", action: openPluginSettings)
            }
            if let error = model.error {
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
                         ? "No retained entries. Copy text or a URL, then refresh."
                         : "No retained entries. Enable or resume collection in Privacy Settings to collect new copies.")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(snapshot.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.text).textSelection(.enabled)
                            HStack {
                                Text(entry.contentType.rawValue.uppercased())
                                Text(entry.sourceApplicationName)
                                Text(entry.sourceBundleIdentifier)
                                Spacer()
                                Text(entry.copiedAt, style: .date)
                                Text(entry.copiedAt, style: .time)
                            }.font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 6)
                    }
                    HStack {
                        Button("Newest") { model.refresh() }.disabled(model.offset == 0)
                        Spacer()
                        if let next = snapshot.nextOffset {
                            Button("Older Entries") { model.refresh(offset: next) }
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
         openPrivacy: @escaping () -> Void, openPluginSettings: @escaping () -> Void) {
        self.grants = grants
        model = ClipboardHistoryWindowModel(query: query)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 560),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Clipboard History"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClipboardHistoryView(model: model, openPrivacy: openPrivacy, openPluginSettings: openPluginSettings))
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
