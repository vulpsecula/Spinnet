import Combine
import Foundation

/// The Welcome Guide's steps, in order.
enum WelcomeGuideStep: CaseIterable, Equatable {
    case welcome
    case systemPermissions
    case menuTrigger
    case officialPlugins
    case finish
}

/// Owns whether the Welcome Guide shows and which step it is on.
///
/// The guide opens by itself only at a launch with no Plugin installed, and
/// only until the user has completed or skipped it once. General reopens it
/// at any time.
final class WelcomeGuideModel: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var step: WelcomeGuideStep = .welcome

    /// Finishing the guide continues in the Menu Editor.
    var onComplete: (() -> Void)?
    /// Each opening starts the official Plugins step afresh.
    var onOpen: (() -> Void)?

    private let defaults: UserDefaults
    private let hasInstalledPlugins: () -> Bool

    init(defaults: UserDefaults, hasInstalledPlugins: @escaping () -> Bool) {
        self.defaults = defaults
        self.hasInstalledPlugins = hasInstalledPlugins
    }

    func openAtLaunchIfNeeded() {
        guard !hasInstalledPlugins(), !defaults.bool(forKey: Self.finishedKey) else { return }
        open()
    }

    /// Completed or skipped, either of which keeps it from opening at launch.
    static let finishedKey = "welcome-guide.finished"

    /// Closes the guide for good; General can still reopen it.
    func skip() {
        defaults.set(true, forKey: Self.finishedKey)
        isPresented = false
    }

    func open() {
        onOpen?()
        step = .welcome
        isPresented = true
    }

    func complete() {
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
