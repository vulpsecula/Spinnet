import Foundation

/// General's interface language. The choice is saved as the app's preferred
/// language, which macOS and the Host apply when Spinnet next launches.
final class InterfaceLanguageModel: ObservableObject {
    @Published var choice: InterfaceLanguage {
        didSet {
            guard choice != oldValue else { return }
            save(choice)
        }
    }

    /// Only a Host running from an app bundle can reopen itself; otherwise
    /// the page asks the user to quit and open Spinnet again.
    let canRelaunch: Bool
    /// The choice this launch runs in.
    private let launchChoice: InterfaceLanguage
    private let defaults: UserDefaults
    private let relaunchHost: () -> Void

    static let choiceKey = "general.interface-language"
    static let appleLanguagesKey = "AppleLanguages" // Not localized: a defaults key

    init(defaults: UserDefaults, canRelaunch: Bool = HostRelaunch.isAvailable,
         relaunch: @escaping () -> Void = HostRelaunch.relaunch) {
        self.defaults = defaults
        self.canRelaunch = canRelaunch
        relaunchHost = relaunch
        let saved = defaults.string(forKey: Self.choiceKey).flatMap(InterfaceLanguage.init(rawValue:)) ?? .system
        launchChoice = saved
        choice = saved
    }

    /// The choice differs from the language this launch runs in.
    var needsRelaunch: Bool { choice != launchChoice }
    var offersRelaunch: Bool { needsRelaunch && canRelaunch }

    func relaunch() {
        guard offersRelaunch else { return }
        relaunchHost()
    }

    private func save(_ choice: InterfaceLanguage) {
        if choice == .system {
            defaults.removeObject(forKey: Self.choiceKey)
            defaults.removeObject(forKey: Self.appleLanguagesKey)
        } else {
            defaults.set(choice.rawValue, forKey: Self.choiceKey)
            defaults.set([choice.rawValue], forKey: Self.appleLanguagesKey)
        }
    }
}
