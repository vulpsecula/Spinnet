import Combine
import Foundation

/// The Welcome Guide's steps, in order.
enum WelcomeGuideStep: String, CaseIterable, Equatable {
    case welcome
    case systemPermissions
    case menuTrigger
    case officialPlugins
    case finish
}

/// How the Menu starts when the Welcome Guide finishes.
enum WelcomeGuideMenuStart: Equatable {
    /// The Starter Menu's Menu Items fill the empty Slots.
    case starterMenu
    /// Every Slot stays empty.
    case empty
}

/// Owns whether the Welcome Guide shows and which step it is on.
///
/// The guide opens by itself only at a launch with no Plugin installed, and
/// only until the user has completed or skipped it once. General reopens it
/// at any time.
final class WelcomeGuideModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var step: WelcomeGuideStep = .welcome
    /// The finish step's choice, when it offers the Starter Menu.
    @Published var menuStart: WelcomeGuideMenuStart = .starterMenu

    /// Finishing the guide continues in the Menu Editor.
    var onComplete: (() -> Void)?
    /// Each opening starts the Official Plugins step afresh.
    var onOpen: (() -> Void)?

    private let defaults: UserDefaults
    private let hasInstalledPlugins: () -> Bool

    init(defaults: UserDefaults, hasInstalledPlugins: @escaping () -> Bool) {
        self.defaults = defaults
        self.hasInstalledPlugins = hasInstalledPlugins
    }

    func openAtLaunchIfNeeded() {
        let resumed = defaults.string(forKey: Self.resumeStepKey).flatMap(WelcomeGuideStep.init(rawValue:))
        defaults.removeObject(forKey: Self.resumeStepKey)
        // Spinnet reopened itself mid-guide, often to apply Screen
        // Recording: continue where the user was, even in a guide reopened
        // from General and whatever they installed.
        if let resumed {
            open()
            step = resumed
            return
        }
        guard !defaults.bool(forKey: Self.finishedKey), !hasInstalledPlugins() else { return }
        open()
    }

    /// Completed or skipped, either of which keeps it from opening at launch.
    static let finishedKey = "welcome-guide.finished"
    /// The step an open guide was on when Spinnet reopened itself.
    static let resumeStepKey = "welcome-guide.resume-step"

    /// Spinnet is reopening itself: an open guide reopens at this step.
    func rememberStepForNextLaunch() {
        guard isPresented else { return }
        defaults.set(step.rawValue, forKey: Self.resumeStepKey)
    }

    /// The quit was cancelled, and the guide is still open.
    func forgetStepForNextLaunch() {
        defaults.removeObject(forKey: Self.resumeStepKey)
    }

    /// Closes the guide for good; General can still reopen it.
    func skip() {
        defaults.set(true, forKey: Self.finishedKey)
        isPresented = false
    }

    func open() {
        onOpen?()
        step = .welcome
        menuStart = .starterMenu
        isPresented = true
    }

    /// Whether Official Plugin installs started in the guide are still under
    /// way; Open Menu Editor waits until each has installed or failed.
    var hasInstallsUnderWay: () -> Bool = { false }

    var canComplete: Bool { !hasInstallsUnderWay() }

    func complete() {
        guard canComplete else { return }
        skip()
        onComplete?()
    }

    var canGoBack: Bool { step != .welcome }

    func next() {
        let steps = WelcomeGuideStep.allCases
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    func back() {
        let steps = WelcomeGuideStep.allCases
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }
}
