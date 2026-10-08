import AppKit
import SpinnetCore
import SwiftUI

/// A running application as the Host reads and ends it: `NSRunningApplication`
/// on the desktop, a fake in tests.
protocol RunningApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var launchDate: Date? { get }
    var localizedName: String? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
    func terminate() -> Bool
    func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningApplication {}

/// The Apps running on this Mac, for `apps.frontmost` and `apps.quit`
/// (#83): the App in front, never a list of Apps, and an exit performed on
/// exactly the App the Host resolved, checked by process
/// ID, bundle identifier and launch date so a reused process ID never
/// matches.
///
/// The main thread keeps which App is in front current from the desktop's
/// activation notifications, so a Host Service reads it from any thread
/// without waiting on the main thread. Each App that quits is told to the
/// observers of terminations.
final class DesktopRunningApps: RunningApps {
    struct Environment {
        /// The App in front, read on the main thread.
        var frontmost: () -> RunningApplication?
        var application: (pid_t) -> RunningApplication?
        var ownProcessIdentifier: pid_t
        /// Calls `activated` on the main thread whenever another App comes to
        /// the front, and `terminated` with each application that quits,
        /// until the returned token is released.
        var observe: (_ activated: @escaping () -> Void,
                      _ terminated: @escaping (RunningApplication) -> Void) -> AnyObject
    }

    private let environment: Environment
    private let lock = NSLock()
    private var front: RunningApplication?
    private var terminationObservers: [(RunningAppIdentity) -> Void] = []
    private var observation: AnyObject?

    /// Made on the main thread.
    init(environment: Environment = .live) {
        self.environment = environment
        front = environment.frontmost()
        observation = environment.observe({ [weak self] in self?.refreshFront() },
                                          { [weak self] in self?.terminated($0) })
    }

    var ownProcessIdentifier: Int32 { environment.ownProcessIdentifier }

    func frontmost() -> RunningAppFacts? {
        lock.lock()
        let front = front
        lock.unlock()
        return front.flatMap(Self.facts)
    }

    func facts(of app: RunningAppIdentity) -> RunningAppFacts? {
        running(app).flatMap(Self.facts)
    }

    func perform(_ exit: AppExit, on app: RunningAppIdentity) -> Bool {
        guard let running = running(app) else { return false }
        switch exit {
        case .quit: return running.terminate()
        case .forceQuit: return running.forceTerminate()
        }
    }

    func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void) {
        lock.lock()
        terminationObservers.append(terminated)
        lock.unlock()
    }

    private func refreshFront() {
        let now = environment.frontmost()
        lock.lock()
        front = now
        lock.unlock()
    }

    private func terminated(_ application: RunningApplication) {
        refreshFront()
        lock.lock()
        let observers = terminationObservers
        lock.unlock()
        let identity = Self.identity(of: application)
        observers.forEach { $0(identity) }
    }

    /// The application running as `app` now, or nil when it quit or its
    /// process ID belongs to another application.
    private func running(_ app: RunningAppIdentity) -> RunningApplication? {
        guard let running = environment.application(app.processIdentifier), !running.isTerminated,
              Self.identity(of: running).isSameApp(as: app) else { return nil }
        return running
    }

    private static func facts(_ running: RunningApplication) -> RunningAppFacts? {
        guard !running.isTerminated else { return nil }
        return RunningAppFacts(identity: identity(of: running), isRegular: running.activationPolicy == .regular)
    }

    static func identity(of running: RunningApplication) -> RunningAppIdentity {
        RunningAppIdentity(processIdentifier: running.processIdentifier, bundleIdentifier: running.bundleIdentifier,
                           launchDate: running.launchDate,
                           name: running.localizedName ?? running.bundleIdentifier ?? "the App in front")
    }
}

extension DesktopRunningApps.Environment {
    static var live: DesktopRunningApps.Environment {
        DesktopRunningApps.Environment(
            frontmost: { NSWorkspace.shared.frontmostApplication },
            application: { NSRunningApplication(processIdentifier: $0) },
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            observe: { activated, terminated in
                let center = NSWorkspace.shared.notificationCenter
                let tokens = [
                    center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                       queue: .main) { _ in activated() },
                    center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                       queue: .main) { notification in
                        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication else { return }
                        terminated(application)
                    }
                ]
                return ObservationTokens(center: center, tokens: tokens)
            }
        )
    }
}

// MARK: - Host Confirmation

/// Draws a Host Confirmation near the pointer in a small panel that takes
/// the keyboard without activating Spinnet, so the App it names stays in
/// front. Its words are the Host's. Cancel is the default button: Escape
/// declines, and Return never confirms the destructive button. Each panel
/// answers for its own confirmation only, and showing one never closes
/// another.
final class HostConfirmationPanel: HostConfirming {
    private var shown: [UUID: NSPanel] = [:]

    func confirm(_ confirmation: HostConfirmation, for action: ActionConfiguration,
                 answer: @escaping (HostConfirmationAnswer) -> Void) -> () -> Void {
        let panel = ConfirmationNSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 140),
                                        styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                        backing: .buffered, defer: false)
        let token = UUID()
        let respond: (HostConfirmationAnswer) -> Void = { [weak self] response in
            guard self?.close(token) == true else { return }
            answer(response)
        }
        let hosting = NSHostingController(rootView: HostConfirmationContent(confirmation: confirmation,
                                                                            respond: respond))
        hosting.sizingOptions = [.preferredContentSize]
        panel.contentViewController = hosting
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .transient]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.setAccessibilityLabel(confirmation.title)
        panel.onCancel = { respond(.declined) }
        shown[token] = panel
        place(panel, near: NSEvent.mouseLocation)
        panel.makeKeyAndOrderFront(nil)
        return { [weak self] in _ = self?.close(token) }
    }

    /// Closes the confirmation `token`; false when it already went.
    private func close(_ token: UUID) -> Bool {
        guard let panel = shown.removeValue(forKey: token) else { return false }
        panel.orderOut(nil)
        return true
    }

    private func place(_ panel: NSPanel, near pointer: NSPoint) {
        let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var origin = NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 12)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private final class ConfirmationNSPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct HostConfirmationContent: View {
    let confirmation: HostConfirmation
    let respond: (HostConfirmationAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(confirmation.title).font(.headline)
            Text(confirmation.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                // The default button, so Return declines too.
                Button("Cancel") { respond(.declined) }
                    .keyboardShortcut(.defaultAction)
                Button(confirmation.confirmTitle, role: confirmation.isDestructive ? .destructive : nil) {
                    respond(.confirmed)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
