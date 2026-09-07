#if DEBUG
import AppKit
import SpinnetCore

/// Opt-in desktop fixture; exercises the production invocation and feedback path.
final class LifecycleTestWindow: NSObject {
    private let window: NSWindow
    private let root: URL
    private let actions: [ActionConfiguration]
    private let invoke: (ActionConfiguration) -> Void

    init(registry: PluginRegistry, invoke: @escaping (ActionConfiguration) -> Void) throws {
        self.invoke = invoke
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpinnetLifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let scripts = [
            ("slow", "Slow success (3 seconds)", "const end = Date.now() + 3000; while (Date.now() < end) {} ; 'done'"),
            ("hang", "Hang until timeout", "while (true) {}")
        ]
        let pluginID = PluginID("com.spinnet.lifecycle-test")
        let commands = scripts.map { id, title, _ in
            CommandDeclaration(id: CommandID(id), title: title, execution: .javascript, script: id + ".js")
        }
        for (id, _, source) in scripts {
            try source.write(to: root.appendingPathComponent(id + ".js"), atomically: true, encoding: .utf8)
        }
        try registry.register(PluginPackage(rootURL: root, manifest: PluginManifest(
            id: pluginID, name: "Lifecycle Test", version: "1.0.0", commands: commands
        )))
        actions = try commands.map {
            try ActionConfiguration(id: ActionID($0.id.rawValue), pluginID: pluginID, command: $0, input: .null)
        }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 160),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Spinnet Lifecycle Test"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.spacing = 14
        for (index, action) in actions.enumerated() {
            let button = NSButton(title: action.title, target: self, action: #selector(run(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            stack.addArrangedSubview(button)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: window.contentView!.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor)
        ])
    }

    func hide() { window.orderOut(nil) }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func run(_ sender: NSButton) {
        invoke(actions[sender.tag])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
#endif
