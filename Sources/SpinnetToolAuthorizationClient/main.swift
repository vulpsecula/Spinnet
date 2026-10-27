import Foundation
import Security
import Darwin
import SpinnetCore
import SpinnetReviewedTools

do {
    // Only fixed bridge arguments are accepted. The root helper independently
    // checks the Task, signed client, runner ancestry, authorization and target.
    let arguments = CommandLine.arguments
    if (arguments.count == 4 && arguments[1] == "--inspect") || (arguments.count == 5 && arguments[1] == "--validate-inspection") {
        let inspection = arguments[1] == "--inspect", id = arguments[2], right = arguments.last!
        guard id.range(of: "^inspection_[a-f0-9-]{36}$", options: .regularExpression) != nil,
              HomebrewNativeInspectionAuthorization.validRight(right, inspection: inspection),
              inspection || HomebrewPrivilegePlan.validDigest(arguments[3]) else { exit(64) }
        let connection = try HomebrewNativeInspectionAuthorization.clientConnection(); defer { connection.invalidate() }
        let done = DispatchSemaphore(value: 0)
        var output = Data(), errorText = "Native inspection communication unavailable", code: Int32 = 77
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? HomebrewNativeInspectionClientProtocol else { exit(77) }
        let prompt = inspection ? "Read ALL installed receipt ownership metadata/path lists and freeze only the selected confirmed files. No installed package is changed by this inspection." : "Admit only the separately confirmed complete native Homebrew plan after fresh full ownership validation. Stopping after admission does not roll back its changes."
        let (authorization, form) = try HomebrewSystemAuthorization.authorize(prompt: prompt, rightName: right)
        defer { AuthorizationFree(authorization, [.destroyRights]) }
        let request = try JSONEncoder().encode(HomebrewNativeInspection.Request(inspectionID: id, finalPlanSHA256: inspection ? nil : arguments[3]))
        if inspection { proxy.inspect(request, authorization: form) { bytes, message in output = bytes; errorText = message; code = message.isEmpty && bytes.count <= HomebrewNativeInspection.maximumSummaryBytes ? 0 : 77; done.signal() } }
        else { proxy.validateAdmission(request, authorization: form) { message in errorText = message; code = message.isEmpty ? 0 : 77; done.signal() } }
        guard done.wait(timeout: .now() + 90) == .success else { exit(70) }
        if code == 0 && inspection { FileHandle.standardOutput.write(output) }
        if !errorText.isEmpty { FileHandle.standardError.write(Data((String(errorText.prefix(4000)) + "\n").utf8)) }
        exit(code)
    }
    if arguments.count == 4, arguments[1] == "--installed-history-digest", ["/opt/homebrew", "/usr/local"].contains(arguments[3]) {
        let recorded = try HomebrewInstalledUninstall.read(name: arguments[2], prefix: arguments[3])
        print(recorded.fingerprint); exit(0)
    }
    guard let task = ProcessInfo.processInfo.environment["HOMEBREW_SPINNET_TASK_ID"] else { exit(64) }
    let request: HomebrewPrivilegeRequest
    let prompt: String
    if arguments.count == 5, arguments[1] == "--remove-paths", Int(arguments[3]) != nil, HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .removePaths, source: arguments[3], sha256: arguments[4])
        prompt = "Remove the exact confirmed native data manifest for \(request.package). Shared settings may be deleted; nonempty rmdir targets are retained. Stopping does not roll back changes."
    } else if arguments.count == 4, arguments[1] == "--remove-kernel-extensions", HomebrewPrivilegePlan.validDigest(arguments[3]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .removeKernelExtensions, source: "", sha256: arguments[3])
        prompt = "Unload and remove only the confirmed kernel-extension IDs and bundle manifests for \(request.package). Restart is required to finish unloading; security policy may refuse it. Stopping does not undo changes."
    } else if arguments.count == 5, arguments[1] == "--removal-code", Int(arguments[3]) != nil, HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .executeRemovalCode, source: arguments[3], sha256: arguments[4])
        prompt = "Run the exact confirmed old-version immutable uninstall action for \(request.package) as administrator. Stopping does not undo its changes."
    } else if arguments.count == 6, arguments[1] == "--vendor", Int(arguments[3]) != nil, HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .executeVendorScript, source: arguments[3], sha256: arguments[4], archive: arguments[5])
        prompt = "Run the confirmed immutable vendor action for \(request.package) as administrator. Stopping does not undo its changes."
    } else if arguments.count == 9, arguments[1] == "--installer", arguments[7] == "--target", arguments[8] == "/", HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .installPackage,
            source: arguments[3], sha256: arguments[4], archive: arguments[5], relativePackage: arguments[6])
        prompt = "Install the reviewed Homebrew package \(request.relativePackage) for \(request.package). Stopping does not undo installation."
    } else if arguments.count == 5, arguments[1] == "--remove-receipt", HomebrewPrivilegePlan.validReceiptID(arguments[3]), HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .removeReceipt, source: arguments[3], sha256: arguments[4])
        prompt = "Remove the confirmed receipt-owned files for \(request.source) (\(request.package)) and then forget its receipt. Shared, writable or changed entries are refused. Changes are not rolled back."
    } else if arguments.count == 5, arguments[1] == "--remove-launch-services", HomebrewNativeLaunchServiceGrant.Phase(rawValue: arguments[3]) != nil, HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .removeLaunchServices, source: arguments[3], sha256: arguments[4])
        prompt = "Stop only the confirmed system/current-user launch-service phase for \(request.package), then remove its exact owned plist targets. Alias-origin and other-user jobs remain. Changes are not rolled back."
    } else if arguments.count == 5, arguments[1] == "--remove-launch-daemon", HomebrewPrivilegePlan.validLaunchDaemonLabel(arguments[3]), HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .removeLaunchDaemon, source: arguments[3], sha256: arguments[4])
        prompt = "Remove the confirmed system launch daemon \(request.source) for \(request.package). Stops its service and removes only its verified plist. Changes are not rolled back."
    } else if arguments.count == 3, arguments[1] == "--repair-directory" {
        request = HomebrewPrivilegeRequest(taskID: task, operation: .repairOwnership, source: arguments[2])
        prompt = "Restore ownership of root-owned entries in the reviewed Homebrew directory \(request.source). Symbolic links and multiple hard links are refused. Changes are not rolled back."
    } else { exit(64) }
    let connection = try HomebrewSystemAuthorization.clientConnection()
    defer { connection.invalidate() }
    let data = try JSONEncoder().encode(request)
    let prepared = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
    var rightName = ""
    guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in prepared.signal(); done.signal() }) as? HomebrewPrivilegeClientProtocol else { exit(77) }
    proxy.prepare(data) { value in rightName = value; prepared.signal() }
    guard prepared.wait(timeout: .now() + 40) == .success else { exit(77) }
    if rightName == HomebrewSystemAuthorization.noLaunchServicesToRemove, request.operation == .removeLaunchServices {
        FileHandle.standardOutput.write(Data("No matching launch services or plist files remain; no system authorization was needed.\n".utf8))
        exit(0)
    }
    guard rightName.hasPrefix(HomebrewSystemAuthorization.right + ".") else {
        FileHandle.standardError.write(Data((String(rightName.prefix(2000)) + "\n").utf8)); exit(77)
    }
    // A fresh request-bound right is prepared in the root helper before the
    // system prompt. No general admin grant can authorize a different Task.
    let (authorization, form) = try HomebrewSystemAuthorization.authorize(prompt: prompt, rightName: rightName)
    defer { AuthorizationFree(authorization, [.destroyRights]) }
    var status: Int32 = 70
    proxy.perform(data, authorization: form) { code, text in
        status = code
        if !text.isEmpty { FileHandle.standardOutput.write(Data((String(text.prefix(4000)) + "\n").utf8)) }
        done.signal()
    }
    // The helper owns installation; runner Stop is forwarded through its
    // separate signed connection and reaches the root process group.
    guard done.wait(timeout: .now() + 7200) == .success else { exit(70) }
    if status == 70 { FileHandle.standardError.write(Data("Privileged helper communication was lost; installation outcome is unknown. No retry was performed.\n".utf8)) }
    exit(status)
} catch {
    FileHandle.standardError.write(Data("Spinnet system authorization was cancelled, refused or unavailable.\n".utf8)); exit(77)
}
