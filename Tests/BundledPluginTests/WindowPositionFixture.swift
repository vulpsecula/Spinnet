import Foundation
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

/// The repository's Window Position package, registered the way the Host
/// registers a Plugin that ships with the app.
enum WindowPositionFixture {
    static func load() throws -> PluginPackage {
        try plugin().package
    }

    static func plugin() throws -> PluginUnderTest {
        try PluginUnderTest(named: "WindowPosition.spinnetplugin", origin: .bundled)
    }

    /// Grants the package's focused-window Capability with its current scope.
    static func grant(_ package: PluginPackage, in grants: PluginCapabilityGrantStore) {
        grants.setDecision(.granted, for: package.manifest.id, pluginVersion: package.manifest.version,
                           capability: .positionFocusedWindow, scope: package.manifest.scope(for: .positionFocusedWindow))
    }

    /// The Host's answers while `window` is focused: reading returns it and
    /// any frame may be set.
    static func services(for window: FocusedWindow) throws -> RecordedHostServices {
        RecordedHostServices([.readFocusedWindow: try .encoding(window), .setFocusedWindowFrame: .value(.null)])
    }
}

extension PluginTestRun {
    /// The frames the script asked the Host to set, in order, read as the
    /// Host reads them.
    func frames(file: StaticString = #filePath, line: UInt = #line) throws -> [WindowRect] {
        try inputs(to: .setFocusedWindowFrame).map {
            try XCTUnwrap(WindowRect(json: $0), "Not a frame the Host accepts: \($0)", file: file, line: line)
        }
    }
}
