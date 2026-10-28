import AppKit
import ApplicationServices
import SpinnetCore
import SwiftUI

/// A running application as the Host reads and ends it: `NSRunningApplication`
/// on the desktop, a fake in tests. Close and Quit are not here: the Host
/// presses the App's own menu items for them, through Accessibility.
protocol RunningApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var bundleIdentifier: String? { get }
    var launchDate: Date? { get }
    /// When the kernel started the process: what identifies an application
    /// that Launch Services did not launch, such as Finder.
    var processStartDate: Date? { get }
    var localizedName: String? { get }
    var bundleURL: URL? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isTerminated: Bool { get }
    func forceTerminate() -> Bool
}

extension NSRunningApplication: RunningApplication {
    var processStartDate: Date? { DesktopRunningApps.processStartDate(of: processIdentifier) }
}

extension DesktopRunningApps {
    /// When the kernel started process `processIdentifier`, or nil when no
    /// such process runs.
    static func processStartDate(of processIdentifier: pid_t) -> Date? {
        guard processIdentifier > 0 else { return nil }
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, processIdentifier]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == processIdentifier else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000)
    }

    /// One item of the menus of an App's menu bar, as Accessibility reads
    /// it.
    struct MenuItem {
        /// Its shortcut's key (`AXMenuItemCmdChar`), such as "Q"; nil when
        /// it has none.
        var commandCharacter: String?
        /// Its shortcut's modifiers (`AXMenuItemCmdModifiers`): 0 is Command
        /// alone; nil when it has no shortcut.
        var commandModifiers: Int?
        var isEnabled: Bool
        /// Presses it (`AXPress`), as a click on it does.
        var press: () -> MenuPress
    }

    /// What pressing a menu item came to.
    enum MenuPress {
        case pressed
        /// The App took the message but did not answer within its bound, as
        /// when the item's action shows a save dialog before it returns.
        case noReply
        case failed
    }
}

/// The Current App: the App in front when the user invokes a Menu, which
/// stays in front behind the non-activating Menu panel. It is resolved once
/// per invocation, from the desktop at that moment; the Menu's centre shows
/// it, and App Overrides select by its bundle identifier.
struct CurrentApp: Equatable {
    let identity: RunningAppIdentity
    /// Where its bundle is, from which its icon is read; nil for an App
    /// without one.
    let bundleURL: URL?

    var bundleIdentifier: String? { identity.bundleIdentifier }
    var name: String { identity.name }
    /// What selects its App Overrides; nil for an App without a bundle
    /// identifier, which gets the default Menu.
    var appBundleIdentifier: AppBundleIdentifier? { AppBundleIdentifier(validating: bundleIdentifier) }
}

/// The Apps running on this Mac, for `apps.frontmost`, `apps.quit` and
/// `apps.close` (#83): the App in front, never a list of Apps, and an exit
/// performed on exactly the App the Host resolved, checked by process ID,
/// bundle identifier and launch date (or, for an App Launch Services did
/// not launch, such as Finder, its process's start time) so a reused process
/// ID never matches.
///
/// Close and Quit are the App's own: the Host reads the menus of the App's
/// menu bar through Accessibility and offers Close or Quit only when one of
/// them has an enabled item whose shortcut is ⌘W or ⌘Q, Command alone, and
/// performs it by pressing that item, exactly as the shortcut does. An App
/// without such an item, as Finder has no ⌘Q, is not closed or quit; no
/// rule names an App. Force Quit ends the process, for any regular App.
///
/// The main thread keeps which App is in front current from the desktop's
/// activation notifications, so a Host Service reads it from any thread
/// without waiting on the main thread. The menus are read on the calling
/// thread, never hopping to the main thread. Each App that quits is told to
/// the observers of terminations.
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
        /// Whether macOS lets Spinnet use Accessibility.
        var isAccessibilityTrusted: () -> Bool
        /// The items of the menus of process's menu bar, in order, read on
        /// the calling thread within a bound; nil when its menu bar does not
        /// answer.
        var menuItems: (pid_t) -> [DesktopRunningApps.MenuItem]?
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

    /// The Current App: the App in front now, read from the desktop when
    /// the Menu is invoked rather than from the last activation notice, which
    /// may still be on its way; never the App under the pointer. Nil when
    /// Spinnet itself or no App is in front, by the same rule `apps.frontmost`
    /// identifies the App in front. Called on the main thread, where it also
    /// brings the App in front that Host Services read up to date.
    func currentApp() -> CurrentApp? {
        refreshFront()
        guard let facts = appInFront() else { return nil }
        return CurrentApp(identity: facts.identity, bundleURL: running(facts.identity)?.bundleURL)
    }

    func menuExits(of app: RunningAppIdentity) throws -> Set<AppExit> {
        try requireAccessibility()
        guard let running = running(app), let items = environment.menuItems(running.processIdentifier) else { return [] }
        return Set(AppExit.allCases.filter { Self.item(for: $0, in: items) != nil })
    }

    func perform(_ exit: AppExit, on app: RunningAppIdentity) throws -> AppExitDelivery {
        if exit.isMenuItem { try requireAccessibility() }
        guard let running = running(app) else { return .failed }
        guard exit.isMenuItem else { return running.forceTerminate() ? .delivered : .failed }
        // Found again now: the item may have gone since it was offered.
        guard let item = environment.menuItems(running.processIdentifier).flatMap({ Self.item(for: exit, in: $0) }) else {
            return .notOffered
        }
        switch item.press() {
        case .pressed, .noReply: return .delivered
        case .failed: return .failed
        }
    }

    func observeTerminations(_ terminated: @escaping (RunningAppIdentity) -> Void) {
        lock.lock()
        terminationObservers.append(terminated)
        lock.unlock()
    }

    /// The first enabled item of `items` whose shortcut is `exit`'s key with
    /// Command alone.
    static func item(for exit: AppExit, in items: [MenuItem]) -> MenuItem? {
        guard let key = exit.menuKey else { return nil }
        return items.first { $0.isEnabled && $0.commandModifiers == 0 && $0.commandCharacter?.uppercased() == key }
    }

    private func requireAccessibility() throws {
        guard environment.isAccessibilityTrusted() else {
            throw PluginHostServiceError.systemPermissionDenied(.accessibility)
        }
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
                           launchDate: running.launchDate ?? running.processStartDate,
                           name: running.localizedName ?? running.bundleIdentifier ?? "the App in front")
    }
}

extension DesktopRunningApps {
    /// Reads an App's menus through Accessibility: each menu of its menu
    /// bar, and each item of those menus with its shortcut and whether it is
    /// enabled, never their submenus. Every message waits at most
    /// `messagingTimeout` for the App's answer, and the whole reading stops
    /// at `readingBound`, keeping what it read, so an App that is slow or
    /// hung bounds `apps.frontmost` and every Close and Quit; the first
    /// message the App does not answer ends the reading.
    ///
    /// Measured 2026-10-09 on an Apple M1 Pro with nine regular Apps
    /// running: a whole reading took 28 to 219 ms (Outlook, 219 items;
    /// Mail 182 ms; the rest under 70 ms), so the bounds leave over four
    /// times the slowest. An App that is not active often reports its ⌘W
    /// item disabled, having no key window; the App in front, which Close
    /// acts on, does not.
    enum AccessibilityMenus {
        /// The longest wait for one answer of the App.
        static let messagingTimeout: Float = 0.25
        /// The longest whole reading of one App's menus.
        static let readingBound: TimeInterval = 1
        private static let accessibility = HostAccessibility()

        static func items(of processIdentifier: pid_t) -> [MenuItem]? {
            let deadline = Date().addingTimeInterval(readingBound)
            let app = AXUIElementCreateApplication(processIdentifier)
            guard case .value(let bar) = element(of: app, kAXMenuBarAttribute),
                  case .value(let menus) = elements(of: bar, kAXChildrenAttribute) else { return nil }
            var items: [MenuItem] = []
            for barItem in menus {
                // A menu bar item's one child is its menu.
                guard Date() < deadline else { return items }
                let menu: AXUIElement
                switch elements(of: barItem, kAXChildrenAttribute) {
                case .value(let children): guard let first = children.first else { continue }; menu = first
                case .missing: continue
                case .unanswered: return items
                }
                let entries: [AXUIElement]
                switch elements(of: menu, kAXChildrenAttribute) {
                case .value(let children): entries = children
                case .missing: continue
                case .unanswered: return items
                }
                for entry in entries {
                    guard Date() < deadline else { return items }
                    guard let item = item(entry) else { return items }
                    items.append(item)
                }
            }
            return items
        }

        private enum Reading<Value> {
            case value(Value)
            /// The attribute is absent, or not of the kind expected.
            case missing
            /// The App did not answer in time, or Accessibility refused.
            case unanswered
        }

        private static func copy(_ element: AXUIElement, _ attribute: String) -> Reading<CFTypeRef> {
            _ = accessibility.timeout(element, messagingTimeout)
            let (status, value) = accessibility.copy(element, attribute as CFString)
            switch status {
            case .success: return value.map { .value($0) } ?? .missing
            case .noValue, .attributeUnsupported, .invalidUIElement: return .missing
            default: return .unanswered
            }
        }

        private static func element(of element: AXUIElement, _ attribute: String) -> Reading<AXUIElement> {
            switch copy(element, attribute) {
            case .value(let value) where CFGetTypeID(value) == AXUIElementGetTypeID():
                return .value(unsafeBitCast(value, to: AXUIElement.self))
            case .unanswered: return .unanswered
            default: return .missing
            }
        }

        private static func elements(of element: AXUIElement, _ attribute: String) -> Reading<[AXUIElement]> {
            switch copy(element, attribute) {
            case .value(let value):
                guard let array = value as? [AnyObject] else { return .missing }
                return .value(array.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID()
                    ? unsafeBitCast($0, to: AXUIElement.self) : nil })
            case .missing: return .missing
            case .unanswered: return .unanswered
            }
        }

        /// One menu item's shortcut and whether it is enabled, in one
        /// message; nil when the App does not answer.
        private static func item(_ entry: AXUIElement) -> MenuItem? {
            _ = accessibility.timeout(entry, messagingTimeout)
            let attributes = [kAXMenuItemCmdCharAttribute, kAXMenuItemCmdModifiersAttribute, kAXEnabledAttribute]
            let (status, values) = accessibility.multiple(entry, attributes as CFArray)
            switch status {
            case .success: break
            case .noValue, .attributeUnsupported, .invalidUIElement:
                return MenuItem(commandCharacter: nil, commandModifiers: nil, isEnabled: false, press: { .failed })
            default: return nil
            }
            // An attribute the item lacks comes back as an AXValue holding
            // its error.
            let read = (values as? [AnyObject]) ?? []
            func value(_ index: Int) -> AnyObject? {
                guard index < read.count, CFGetTypeID(read[index]) != AXValueGetTypeID() else { return nil }
                return read[index]
            }
            return MenuItem(commandCharacter: value(0) as? String, commandModifiers: (value(1) as? NSNumber)?.intValue,
                            isEnabled: (value(2) as? NSNumber)?.boolValue ?? false) {
                _ = accessibility.timeout(entry, messagingTimeout)
                switch accessibility.action(entry, kAXPressAction as CFString) {
                case .success: return .pressed
                case .cannotComplete: return .noReply
                default: return .failed
                }
            }
        }
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
            },
            isAccessibilityTrusted: { AXIsProcessTrusted() },
            menuItems: DesktopRunningApps.AccessibilityMenus.items(of:)
        )
    }
}

// MARK: - Host Confirmation

/// Draws a Host Confirmation in a small panel that takes
/// the keyboard without activating Spinnet, so the App it names stays in
/// front. It sits over the window whose operation it confirms, or near the
/// pointer when Spinnet has no key window. Its words are the Host's. Cancel is the default button: Escape
/// declines, and Return never confirms the destructive button. Each panel
/// answers for its own confirmation only, and showing one never closes
/// another.
final class HostConfirmationPanel: HostConfirming {
    private var shown: [UUID: ConfirmationNSPanel] = [:]

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
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame.size ?? NSSize(width: 800, height: 600)
        let width = min(confirmation.details == nil ? 340 : 620, max(240, visible.width - 32))
        let height = min(640, max(240, visible.height - 32))
        let hosting = NSHostingController(rootView: HostConfirmationContent(confirmation: confirmation,
            contentWidth: width, maximumHeight: height, respond: respond))
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
        // The window it takes the keyboard from, usually the view whose
        // operation it confirms, has it back when the confirmation goes.
        let origin = NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil }
        place(panel, over: origin)
        panel.returnsKeyTo = origin
        panel.makeKeyAndOrderFront(nil)
        return { [weak self] in _ = self?.close(token) }
    }

    /// Closes the confirmation `token`; false when it already went.
    private func close(_ token: UUID) -> Bool {
        guard let panel = shown.removeValue(forKey: token) else { return false }
        let previous = panel.returnsKeyTo
        panel.orderOut(nil)
        if panel.isKeyWindow || NSApp.keyWindow == nil, let previous, previous.isVisible {
            previous.makeKeyAndOrderFront(nil)
        }
        return true
    }

    /// Centres the panel across the top of `window`, where a sheet would
    /// drop, and below the pointer without one.
    private func place(_ panel: NSPanel, over window: NSWindow?) {
        let size = panel.contentViewController?.view.fittingSize ?? panel.frame.size
        let pointer = NSEvent.mouseLocation
        let screen = window?.screen ?? NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        var origin = if let frame = window?.frame {
            NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - 40 - size.height)
        } else {
            NSPoint(x: pointer.x - size.width / 2, y: pointer.y - size.height - 12)
        }
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

/// A Host Confirmation's panel. A Plugin View that loses the keyboard to
/// one stays open: its own operation waits on the answer.
final class ConfirmationNSPanel: NSPanel {
    var onCancel: (() -> Void)?
    weak var returnsKeyTo: NSWindow?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

private struct HostConfirmationContent: View {
    let confirmation: HostConfirmation
    let contentWidth: CGFloat
    let maximumHeight: CGFloat
    let respond: (HostConfirmationAnswer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(confirmation.title).font(.headline)
            ScrollView {
                Text(confirmation.message).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            .frame(height: min(confirmation.details == nil ? maximumHeight - 140 : 100,
                               max(44, CGFloat(confirmation.message.count / 40 + 1) * 18)))
            if let details = confirmation.details {
                HostConfirmationDetailsContent(details: details, height: max(100, maximumHeight - 270))
            }
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
        .frame(width: contentWidth - 32)
    }
}
