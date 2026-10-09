import Foundation
import IOKit.pwr_mgt
import SpinnetCore
import OSLog

/// Bounded OS power adapter. No subprocess, arbitrary assertion type or
/// user-provided reason is exposed to Plugins. macOS releases assertions
/// automatically when the Host process exits, including crashes/logout.
final class DesktopPowerAssertions: PowerAssertions {
    func acquire(_ assertion: KeepAwakeAssertion, reason: String) throws -> () -> Void {
        let type = assertion == .idleSystem ? kIOPMAssertionTypePreventUserIdleSystemSleep : kIOPMAssertionTypePreventUserIdleDisplaySleep
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            throw PluginHostServiceError.failed("macOS refused Keep Awake (\(result))")
        }
        return {
            let result = IOPMAssertionRelease(id)
            if result != kIOReturnSuccess {
                Logger(subsystem: "com.vulpsecula.Spinnet", category: "keep-awake")
                    .error("Power assertion release failed: \(result)")
            }
        }
    }
}
