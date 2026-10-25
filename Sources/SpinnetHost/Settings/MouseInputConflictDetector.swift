import AppKit

struct MouseInputConflict: Identifiable, Equatable {
    let id: String
    let applicationName: String
    let guidance: String
}

struct RunningApplicationIdentity: Equatable {
    let bundleIdentifier: String?
    let localizedName: String?
}

struct MouseInputConflictDefinition {
    let id: String
    let applicationName: String
    let bundleIdentifiers: Set<String>
    let processNames: Set<String>
    let guidance: String
}

struct MouseInputConflictDetector {
    private static let macMouseFixID = "mac-mouse-fix"

    static let knownDrivers: [MouseInputConflictDefinition] = [
        MouseInputConflictDefinition(
            id: "mac-mouse-fix",
            applicationName: "Mac Mouse Fix",
            bundleIdentifiers: [
                "com.nuebling.mac-mouse-fix",
                "com.nuebling.mac-mouse-fix.helper"
            ],
            processNames: ["Mac Mouse Fix", "Mac Mouse Fix Helper"],
            guidance: "Remove every Click, Click and Drag, and Click and Scroll action for the same mouse button in Mac Mouse Fix."
        ),
        MouseInputConflictDefinition(
            id: "better-touch-tool",
            applicationName: "BetterTouchTool",
            bundleIdentifiers: [],
            processNames: ["BetterTouchTool"],
            guidance: "Remove Normal Mouse triggers for the same button, including click, long-press, drag, drawing, and scroll combinations."
        ),
        MouseInputConflictDefinition(
            id: "steer-mouse",
            applicationName: "SteerMouse",
            bundleIdentifiers: [],
            processNames: ["SteerMouse"],
            guidance: "Clear the same button and any chord containing it from global, per-application, and per-mouse profiles."
        ),
        MouseInputConflictDefinition(
            id: "logi-options-plus",
            applicationName: "Logi Options+",
            bundleIdentifiers: [],
            processNames: ["Logi Options+", "Logi Options Plus"],
            guidance: "Remove actions and gestures from the same button, or configure the device to emit an unmodified native mouse button."
        ),
        MouseInputConflictDefinition(
            id: "linear-mouse",
            applicationName: "LinearMouse",
            bundleIdentifiers: ["com.lujjjh.LinearMouse"],
            processNames: ["LinearMouse"],
            guidance: "Remove the same button action from every matching device and application scheme; scrolling and pointer adjustments can remain enabled."
        )
    ]

    var runningApplications: () -> [RunningApplicationIdentity] = {
        NSWorkspace.shared.runningApplications.map {
            RunningApplicationIdentity(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName
            )
        }
    }
    var macMouseFixConfigurationData: () -> Data? = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.nuebling.mac-mouse-fix/config.plist")
        return try? Data(contentsOf: url)
    }

    func detect(mouseButton: Int) -> [MouseInputConflict] {
        var claimedButtonsByDriver: [String: Set<Int>] = [:]
        if let data = macMouseFixConfigurationData() {
            claimedButtonsByDriver[Self.macMouseFixID] = Self.macMouseFixClaimedButtons(from: data)
        }
        return Self.detect(
            runningApplications: runningApplications(),
            mouseButton: mouseButton,
            claimedButtonsByDriver: claimedButtonsByDriver,
            definitions: Self.knownDrivers
        )
    }

    static func detect(
        runningApplications: [RunningApplicationIdentity],
        mouseButton: Int,
        claimedButtonsByDriver: [String: Set<Int>],
        definitions: [MouseInputConflictDefinition] = knownDrivers
    ) -> [MouseInputConflict] {
        definitions.compactMap { definition in
            let isRunning = runningApplications.contains { application in
                application.bundleIdentifier.map(definition.bundleIdentifiers.contains) == true
                    || application.localizedName.map(definition.processNames.contains) == true
            }
            guard isRunning,
                  claimedButtonsByDriver[definition.id]?.contains(mouseButton) == true else {
                return nil
            }
            return MouseInputConflict(
                id: definition.id,
                applicationName: definition.applicationName,
                guidance: definition.guidance
            )
        }
    }

    static func macMouseFixClaimedButtons(from data: Data) -> Set<Int> {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
        let constants = root["Constants"] as? [String: Any],
        integer(from: constants["configVersion"]) == 24,
        let general = root["General"] as? [String: Any],
        general["buttonKillSwitch"] as? Bool != true,
        let remaps = root["Remaps"] as? [[String: Any]] else {
            return []
        }

        var claimedButtons: Set<Int> = []
        for remap in remaps {
            if let trigger = remap["trigger"] as? [String: Any],
               let oneBasedButton = integer(from: trigger["button"]),
               oneBasedButton >= 3 {
                claimedButtons.insert(oneBasedButton - 1)
            }
            if let modifiers = remap["modifiers"] as? [String: Any],
               let buttonModifiers = modifiers["buttonModifiers"] as? [[String: Any]] {
                for modifier in buttonModifiers {
                    if let oneBasedButton = integer(from: modifier["button"]),
                       oneBasedButton >= 3 {
                        claimedButtons.insert(oneBasedButton - 1)
                    }
                }
            }
        }
        return claimedButtons
    }

    private static func integer(from value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}
