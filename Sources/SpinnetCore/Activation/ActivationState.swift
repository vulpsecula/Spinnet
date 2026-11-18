import Foundation

/// Where this build stands on activation. Only an Official Build has a Trial
/// or needs an Activation Code; a build made from source is never limited.
public enum ActivationState: Equatable, Sendable {
    case sourceBuild
    case trial(daysLeft: Int)
    /// Every feature keeps working; the Host only reminds.
    case trialEnded
    case activated(ActivationCode)

    public init(isOfficialBuild: Bool, activation: ActivationCode?, trialStart: Date, now: Date) {
        guard isOfficialBuild else { self = .sourceBuild; return }
        if let activation { self = .activated(activation); return }
        // A clock set before the Trial started shows the whole Trial.
        let elapsed = max(0, now.timeIntervalSince(trialStart))
        let remaining = TimeInterval(Trial.days) * Trial.day - elapsed
        self = remaining > 0 ? .trial(daysLeft: Int((remaining / Trial.day).rounded(.up))) : .trialEnded
    }
}

/// The full-feature period of an Official Build, from its first launch.
public enum Trial {
    public static let days = 30
    static let day: TimeInterval = 24 * 60 * 60
}

/// The reminder an Official Build shows after its Trial, at most once a day.
public enum ActivationReminder {
    public static let interval: TimeInterval = 24 * 60 * 60

    public static func isDue(state: ActivationState, lastShown: Date?, now: Date) -> Bool {
        guard state == .trialEnded else { return false }
        guard let lastShown else { return true }
        // A reminder recorded in the future means the clock went back.
        return lastShown > now || now.timeIntervalSince(lastShown) >= interval
    }
}
