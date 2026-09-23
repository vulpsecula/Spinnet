import AppKit
import SwiftUI
import SpinnetCore

/// Host-rendered browsing state. Refreshes call the same public broker as the
/// Plugin invocation; the window never holds a store or a helper connection.
/// Later pages are appended, so sorting and filtering see every loaded copy.
final class ClipboardHistoryWindowModel: ObservableObject {
    /// Stops a filter from paging an unbounded history into memory.
    static let maximumLoadedCopies = 1_000

    @Published private(set) var snapshot: ClipboardHistorySnapshot?
    @Published private(set) var error: String?
    @Published private(set) var accessDenied = false
    @Published private(set) var isLoading = false
    @Published private(set) var isLoadingMore = false
    private let queryQueue = DispatchQueue(label: "com.spinnet.clipboard-history-query", qos: .userInitiated)
    private var queryRevision = UUID()
    private var queuedQuery: (id: UUID, offset: Int, append: Bool)?
    private var querying = false
    private var loadingEveryPage = false
    private var expiration: DispatchWorkItem?
    private let query: (Int) throws -> ClipboardHistorySnapshot

    init(query: @escaping (Int) throws -> ClipboardHistorySnapshot) { self.query = query }

    var canLoadMore: Bool {
        snapshot?.nextOffset != nil && (snapshot?.copies.count ?? 0) < Self.maximumLoadedCopies
    }

    func refresh() {
        discardSnapshot()
        error = nil
        accessDenied = false
        isLoading = true
        queuedQuery = (queryRevision, 0, false)
        runNextQuery()
    }

    func loadMore() {
        guard !isLoading, !isLoadingMore, canLoadMore, let next = snapshot?.nextOffset else { return }
        isLoadingMore = true
        queuedQuery = (queryRevision, next, true)
        runNextQuery()
    }

    /// Keeps appending pages until the history or the loading bound runs out.
    func loadEveryPage() {
        loadingEveryPage = true
        loadMore()
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
                if queryRevision == request.id { apply(result, append: request.append) }
                runNextQuery()
            }
        }
    }

    private func apply(_ response: Result<ClipboardHistorySnapshot, Error>, append: Bool) {
        isLoading = false
        isLoadingMore = false
        do {
            var result = try response.get()
            if append, let snapshot { result = snapshot.appending(result) }
            if let expiry = result.expiresAt {
                guard expiry > Date() else {
                    discardSnapshot()
                    error = "Entries expired. Refresh to see retained history."
                    return
                }
                expiration?.cancel()
                let task = DispatchWorkItem { [weak self] in
                    self?.discardSnapshot()
                    self?.error = "Entries expired. Refresh to see retained history."
                }
                expiration = task
                DispatchQueue.main.asyncAfter(deadline: .now() + expiry.timeIntervalSinceNow, execute: task)
            }
            snapshot = result
            if loadingEveryPage { canLoadMore ? loadMore() : (loadingEveryPage = false) }
        }
        catch {
            loadingEveryPage = false
            accessDenied = (error as? PluginHostServiceError) == .capabilityDenied(.readClipboardHistory)
            self.error = accessDenied ? "Clipboard History access is not granted to this Plugin." : error.localizedDescription
        }
    }

    func discardSnapshot() {
        queryRevision = UUID()
        queuedQuery = nil
        isLoading = false
        isLoadingMore = false
        loadingEveryPage = false
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
    /// Restores a copy to the clipboard; `true` also pastes it into the previous app.
    var restore: (UUID, _ paste: Bool) -> Void = { _, _ in }
    var deleteCopies: (Set<UUID>, @escaping (String?) -> Void) -> Void = { $1(nil) }
    @State private var busy = false
    @State private var managementError: String?
    @State private var selection = Set<UUID>()
    /// After a delete, the row that took the first deleted row's place.
    @State private var selectionIndexAfterDelete: Int?
    @State private var browsing = ClipboardHistoryBrowsing()
    @FocusState private var listFocused: Bool

    private var copies: [ClipboardHistoryCopy] { model.snapshot?.copies ?? [] }
    private var shown: [ClipboardHistoryCopy] { browsing.apply(to: copies) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
            Divider()
            if let managementError {
                Label(managementError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            content
        }
        .frame(minWidth: 560, minHeight: 420)
        .onChange(of: browsing) { _ in
            if browsing.needsEveryPage { model.loadEveryPage() }
            reconcileSelection()
        }
        .onChange(of: model.snapshot) { _ in
            if browsing.needsEveryPage { model.loadEveryPage() }
            reconcileSelection()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search", text: $browsing.text)
                        .textFieldStyle(.plain)
                        .onSubmit { pasteSelection() }
                    if !browsing.text.isEmpty {
                        Button { browsing.text = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear Search")
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                if busy { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh")
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("Clear History…") {
                        run { clearHistory($0) }
                    }.disabled(busy)
                    Button("Ignored Applications…", action: openIgnoredApplications)
                    Divider()
                    Button("Plugin Settings…", action: openPluginSettings)
                    Button("Privacy Settings…", action: openPrivacy)
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("More")
            }
            HStack(spacing: 12) {
                Picker("Type", selection: $browsing.kind) {
                    ForEach(ClipboardHistoryBrowsing.Kind.allCases) { Text($0.title).tag($0) }
                }
                Picker("App", selection: $browsing.application) {
                    Text("All Applications").tag(String?.none)
                    let applications = ClipboardHistoryBrowsing.applications(in: copies)
                    if !applications.isEmpty { Divider() }
                    ForEach(applications, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                Picker("Sort", selection: $browsing.sort) {
                    ForEach(ClipboardHistoryBrowsing.Sort.allCases) { Text($0.title).tag($0) }
                }
                Spacer(minLength: 0)
                if browsing != ClipboardHistoryBrowsing() {
                    Button("Reset") { browsing = ClipboardHistoryBrowsing() }.buttonStyle(.link)
                }
            }
            .pickerStyle(.menu).fixedSize().controlSize(.small)
        }
    }

    @ViewBuilder private var content: some View {
        if model.isLoading {
            ProgressView("Loading Clipboard History…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.error {
            VStack(spacing: 10) {
                Text(error).foregroundStyle(.secondary)
                if model.accessDenied { Button("Manage Access in Library…", action: openPluginSettings) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let snapshot = model.snapshot {
            if snapshot.state != .collecting {
                HStack {
                    Label(snapshot.state == .off
                          ? "Collection is off. Retained entries remain readable until they expire."
                          : "Collection is paused. No new entries are collected.", systemImage: "pause.circle")
                    Spacer()
                    Button("Open Privacy Settings…", action: openPrivacy)
                }.font(.callout).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            if snapshot.entries.isEmpty {
                Text(snapshot.state == .collecting
                     ? "No retained entries. Copy text, an image, rich text, a file, or other content, then refresh."
                     : "No retained entries. Enable or resume collection in Privacy Settings to collect new copies.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
                Divider()
                footer(snapshot)
            }
        } else {
            Spacer()
        }
    }

    private var list: some View {
        let shown = shown
        return List(selection: $selection) {
            ForEach(shown) { copy in
                ClipboardHistoryCopyRow(copy: copy)
            }
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
            } else if model.canLoadMore, !browsing.needsEveryPage {
                // Reaching the end of what is loaded pages in the next copies.
                Color.clear.frame(height: 1).onAppear { model.loadMore() }
            }
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if ids.count == 1, let id = ids.first {
                Button("Paste") { restore(id, true) }
                Button("Copy to Clipboard") { restore(id, false) }
                Divider()
            }
            if !ids.isEmpty {
                Button(ids.count == 1 ? "Delete" : "Delete \(ids.count) Entries") { delete(ids) }
            }
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first { restore(id, true) }
        }
        .onDeleteCommand { delete(selection) }
        .focused($listFocused)
        .overlay {
            if shown.isEmpty, !model.isLoadingMore { Text("No entries match.").foregroundStyle(.secondary) }
        }
        .onAppear { reconcileSelection() }
    }

    private func footer(_ snapshot: ClipboardHistorySnapshot) -> some View {
        HStack(spacing: 10) {
            Text(summary).foregroundStyle(.secondary)
            Spacer()
            if selection.count > 0 {
                Button(role: .destructive) { delete(selection) } label: {
                    Label(selection.count == 1 ? "Delete" : "Delete \(selection.count)", systemImage: "trash")
                }.disabled(busy)
            }
            if selection.count == 1 { Button("Paste") { pasteSelection() } }
        }
        .font(.caption).controlSize(.small)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var summary: String {
        var parts = [browsing.isFiltering ? "\(shown.count) of \(copies.count) entries" : "\(copies.count) entries"]
        if model.canLoadMore { parts[0] += " loaded" }
        if selection.count > 1 { parts.append("\(selection.count) selected") }
        parts.append("Double-click or Return to paste · Delete to remove")
        return parts.joined(separator: " · ")
    }

    private func pasteSelection() {
        if selection.count == 1, let id = selection.first { restore(id, true) }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty, !busy else { return }
        selectionIndexAfterDelete = shown.firstIndex { ids.contains($0.id) }
        run { deleteCopies(ids, $0) }
    }

    private func run(_ operation: (@escaping (String?) -> Void) -> Void) {
        busy = true
        managementError = nil
        operation { error in
            busy = false
            managementError = error
            model.refresh()
        }
    }

    /// Keeps the selection on rows that are still shown; with none left, selects
    /// the row where the user was working so the keyboard keeps a target.
    private func reconcileSelection() {
        // While a refresh is in flight there is nothing to reconcile against.
        guard model.snapshot != nil else { return }
        let shown = shown
        let visible = Set(shown.map(\.id))
        selection.formIntersection(visible)
        guard selection.isEmpty, !shown.isEmpty else { return }
        let index = min(selectionIndexAfterDelete ?? 0, shown.count - 1)
        selectionIndexAfterDelete = nil
        selection = [shown[index].id]
        listFocused = true
    }
}

final class ClipboardHistoryWindow: NSWindowController, NSWindowDelegate {
    let model: ClipboardHistoryWindowModel
    private let grants: PluginCapabilityGrantStore
    private var observer: UUID?
    private let restoration: (UUID) throws -> [ClipboardHistoryRestoredItem]
    private let notify: (String) -> Void
    private let paster: ClipboardHistoryPaster
    private let restoreQueue = DispatchQueue(label: "com.spinnet.clipboard-history-restore", qos: .userInitiated)
    /// The app a paste goes to: whichever other app was active most recently.
    private(set) var previousApplication: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    init(grants: PluginCapabilityGrantStore, query: @escaping (Int) throws -> ClipboardHistorySnapshot,
         restoration: @escaping (UUID) throws -> [ClipboardHistoryRestoredItem],
         openPrivacy: @escaping () -> Void, openPluginSettings: @escaping () -> Void,
         openIgnoredApplications: @escaping () -> Void,
         clearHistory: @escaping (@escaping (String?) -> Void) -> Void,
         deleteCopies: @escaping (Set<UUID>, @escaping (String?) -> Void) -> Void,
         notify: @escaping (String) -> Void,
         paster: ClipboardHistoryPaster = ClipboardHistoryPaster()) {
        self.grants = grants
        self.restoration = restoration
        self.notify = notify
        self.paster = paster
        model = ClipboardHistoryWindowModel(query: query)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Clipboard History"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClipboardHistoryView(model: model, openPrivacy: openPrivacy,
            openPluginSettings: openPluginSettings, openIgnoredApplications: openIgnoredApplications, clearHistory: clearHistory,
            restore: { [weak self] id, paste in self?.restore(id, paste: paste) }, deleteCopies: deleteCopies))
        window.center()
        observer = grants.observeChanges { [weak self] in
            if Thread.isMainThread { self?.refreshIfVisible() }
            else { DispatchQueue.main.async { [weak self] in self?.refreshIfVisible() } }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            self?.previousApplication = app
        }
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }
    deinit {
        if let observer { grants.removeChangeObserver(observer) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
    func refreshIfVisible() {
        model.discardSnapshot()
        if window?.isVisible == true { model.refresh() }
    }
    func windowWillClose(_ notification: Notification) { model.discardSnapshot() }
    func present() {
        if let front = NSWorkspace.shared.frontmostApplication,
           front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = front
        }
        model.refresh()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowDidBecomeKey(_ notification: Notification) { model.refresh() }

    /// Payload reads can wait behind Store writes, so they stay off main.
    private func restore(_ copyID: UUID, paste: Bool) {
        restoreQueue.async { [weak self] in
            guard let self else { return }
            let result = Result { try self.restoration(copyID) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.notify(error.localizedDescription)
                case .success(let items) where !paste:
                    self.notify(self.paster.write(items) ? "Copied to the clipboard" : "The clipboard could not be updated")
                case .success(let items):
                    self.close()
                    self.paster.paste(items, into: self.previousApplication) { message in
                        if let message { self.notify(message) }
                    }
                }
            }
        }
    }
}
