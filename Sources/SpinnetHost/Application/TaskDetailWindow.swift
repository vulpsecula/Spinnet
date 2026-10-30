import AppKit
import SpinnetCore
import SwiftUI

/// Windows read the Host's own Activity snapshots and do not open a Plugin.
final class TaskDetailWindows {
    private let activities: HostActivities
    private var windows: [String: TaskDetailWindow] = [:]

    init(activities: HostActivities) { self.activities = activities }

    func show(_ id: String) {
        guard let activity = activities.list().first(where: { $0.id == id && $0.kind == "task" }) else { return }
        if let window = windows[id] { window.present(); return }
        let window = TaskDetailWindow(activity: activity, activities: activities)
        window.onClose = { [weak self] in self?.windows[id] = nil }
        windows[id] = window
        window.present()
    }
}

private final class TaskDetailWindow: NSWindowController, NSWindowDelegate {
    var onClose: () -> Void = {}
    private let model: TaskDetailModel

    init(activity: HostActivity, activities: HostActivities) {
        model = TaskDetailModel(activity: activity, activities: activities)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 580),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = activity.localizedName
        window.setAccessibilityLabel(localized("Task details for \(activity.localizedName)"))
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 440, height: 360)
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.delegate = self
        window.contentView = NSHostingView(rootView: TaskDetailContent(model: model))
        model.onRemoval = { [weak self] in self?.close() }
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("Not supported") }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) { onClose() }
}

private final class TaskDetailModel: ObservableObject {
    @Published private(set) var activity: HostActivity
    var onRemoval: () -> Void = {}
    private let activities: HostActivities
    private var observation: UUID?

    init(activity: HostActivity, activities: HostActivities) {
        self.activity = activity
        self.activities = activities
        observation = activities.observeChanges { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard let current = activities.list().first(where: { $0.id == activity.id && $0.kind == "task" }) else {
            onRemoval(); return
        }
        if current != activity { activity = current }
    }

    func stop() { activities.stop(activity.id) }
    deinit { if let observation { activities.removeChangeObserver(observation) } }
}

private struct TaskDetailContent: View {
    @ObservedObject var model: TaskDetailModel

    var body: some View {
        let activity = model.activity
        let detail = activity.detail
        let stage = detail?.value(atPointer: "/stage")?.taskText ?? ""
        let output: String = {
            if let text = detail?.value(atPointer: "/output")?.taskText, !text.isEmpty { return text }
            guard case .array(let lines)? = detail?.value(atPointer: "/log") else { return "" }
            return lines.compactMap(\.taskText).joined(separator: "\n")
        }()
        VStack(alignment: .leading, spacing: 12) {
            TaskDetailSummary(name: activity.localizedName, plugin: activity.pluginName,
                              status: activity.localizedStatus, stage: stage)
            TaskDetailOutput(text: output, truncated: detail?.value(atPointer: "/output_truncated") == .bool(true))
            HStack {
                Spacer()
                TaskStopButton(name: activity.localizedName, enabled: activity.canStop) { model.stop() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private extension JSONValue {
    var taskText: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }
}

private struct TaskDetailSummary: View {
    let name: String
    let plugin: String
    let status: String
    let stage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.title2)
            HStack { Text(localized("Plugin")); Text(plugin) }
            HStack { Text(localized("Status")); Text(status) }
            HStack { Text(localized("Stage")); Text(stage) }
        }
        .textSelection(.enabled)
    }
}

private struct TaskDetailOutput: View {
    let text: String
    let truncated: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("Task output")).font(.headline)
            if truncated { Text(localized("Earlier output was truncated.")).foregroundStyle(.secondary) }
            PluginCommandOutputView(text: text).frame(minHeight: 160, maxHeight: .infinity)
        }
    }
}

/// The native Stop control is reachable through the macOS accessibility
/// action as well as a mouse or keyboard click.
private struct TaskStopButton: NSViewRepresentable {
    let name: String
    let enabled: Bool
    let stop: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(stop: stop) }
    func makeNSView(context: Context) -> NSButton {
        NSButton(title: localized("Stop"), target: context.coordinator, action: #selector(Coordinator.press(_:)))
    }
    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.stop = stop
        button.isEnabled = enabled
        button.setAccessibilityLabel(localized("Stop \(name)"))
        button.setAccessibilityHelp(localized("Stop this Host-owned activity."))
    }

    final class Coordinator: NSObject {
        var stop: () -> Void
        init(stop: @escaping () -> Void) { self.stop = stop }
        @objc func press(_ sender: Any?) { stop() }
    }
}
