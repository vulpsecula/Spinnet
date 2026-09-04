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

    func detect() -> [MouseInputConflict] {
        Self.detect(
            runningApplications: runningApplications(),
            definitions: Self.knownDrivers
        )
    }

    static func detect(
        runningApplications: [RunningApplicationIdentity],
        definitions: [MouseInputConflictDefinition] = knownDrivers
    ) -> [MouseInputConflict] {
        definitions.compactMap { definition in
            let isRunning = runningApplications.contains { application in
                application.bundleIdentifier.map(definition.bundleIdentifiers.contains) == true
                    || application.localizedName.map(definition.processNames.contains) == true
            }
            guard isRunning else { return nil }
            return MouseInputConflict(
                id: definition.id,
                applicationName: definition.applicationName,
                guidance: definition.guidance
            )
        }
    }
}
