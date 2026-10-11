import Foundation
import Security
import Darwin
import SpinnetCore

do {
    // Only fixed bridge arguments are accepted. The root helper independently
    // checks the Task, signed client, runner ancestry, authorization and target.
    let arguments = CommandLine.arguments
    guard let task = ProcessInfo.processInfo.environment["HOMEBREW_SPINNET_TASK_ID"] else { exit(64) }
    let request: HomebrewPrivilegeRequest
    let prompt: String
    if arguments.count == 9, arguments[1] == "--installer", arguments[7] == "--target", arguments[8] == "/", HomebrewPrivilegePlan.validDigest(arguments[4]) {
        request = HomebrewPrivilegeRequest(taskID: task, package: arguments[2], operation: .installPackage,
            source: arguments[3], sha256: arguments[4], archive: arguments[5], relativePackage: arguments[6])
        prompt = "Install the reviewed Homebrew package \(request.relativePackage) for \(request.package). Stopping does not undo installation."
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
    guard prepared.wait(timeout: .now() + 15) == .success, rightName.hasPrefix(HomebrewSystemAuthorization.right + ".") else { exit(77) }
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
