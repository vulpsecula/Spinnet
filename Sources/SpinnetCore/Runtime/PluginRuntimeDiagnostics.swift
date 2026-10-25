import Foundation
import os

/// Runtime diagnostics stay in the protected system log. User-facing Action
/// feedback receives only the stable failure category and never these details.
enum PluginRuntimeDiagnostics {
    private static let logger = Logger(
        subsystem: "com.vulpsecula.Spinnet",
        category: "PluginRuntime"
    )

    static func helperResourceExceeded(
        pluginID: PluginID,
        processID: Int32,
        footprint: UInt64,
        limit: UInt64
    ) {
        logger.error(
            "Plugin helper resource limit exceeded plugin=\(pluginID.rawValue, privacy: .private) pid=\(processID, privacy: .private) footprint=\(footprint, privacy: .private) limit=\(limit, privacy: .private)"
        )
    }

    static func helperFailure(
        pluginID: PluginID,
        actionID: ActionID,
        error: Error
    ) {
        logger.error(
            "Plugin helper Action failed plugin=\(pluginID.rawValue, privacy: .private) action=\(actionID.rawValue, privacy: .private) diagnostic=\(error.localizedDescription, privacy: .private)"
        )
    }
}
