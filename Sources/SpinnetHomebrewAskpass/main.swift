import AppKit
import Darwin
import SpinnetCore

// sudo invokes this signed executable. Its sole stdout value is the password;
// errors, cancellations and command context are never written to that stream.
if CommandLine.arguments == [CommandLine.arguments[0], "--verify"] { exit(0) }
func runAskpass() throws -> Int32 {
    guard getuid() != 0, let socket = ProcessInfo.processInfo.environment[HomebrewAskpass.socketEnvironment] else { return 77 }
    let checking = CommandLine.arguments.count == 2 && CommandLine.arguments[1] == "--check"
    if !checking { try HomebrewAskpass.verifySudoParent() }
    let fd = try HomebrewAskpass.connect(socket)
    defer { close(fd) }
    let context = try HomebrewAskpass.receiveContext(fd)
    // Signed packaging probe exercises mutual peer validation without UI,
    // passwords, sudo, or a Homebrew mutation.
    if checking { return 0 }
    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "Homebrew needs your login password"
    alert.informativeText = context.command + "\n\nSpinnet passes your password to sudo for this Homebrew command. It is not saved or shared with the Plugin."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "Continue")
    alert.addButton(withTitle: "Cancel")
    alert.buttons[1].keyEquivalent = "\u{1b}"
    let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
    password.placeholderString = "Login password"
    alert.accessoryView = password
    alert.window.title = "Spinnet Host"
    alert.window.initialFirstResponder = password
    var valid = true
    let timer = Timer(timeInterval: 0.2, repeats: true) { _ in
        var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
        if poll(&event, 1, 0) > 0 {
            valid = false
            application.abortModal(); alert.window.orderOut(nil)
        }
    }
    RunLoop.main.add(timer, forMode: .common)
    RunLoop.main.add(timer, forMode: .modalPanel)
    let answer = alert.runModal()
    timer.invalidate()
    defer { password.stringValue = "" }
    guard valid, answer == .alertFirstButtonReturn else { return 1 }
    var bytes = Data(password.stringValue.utf8)
    guard !bytes.isEmpty, bytes.count <= 4096, !bytes.contains(10), !bytes.contains(0) else { return 1 }
    bytes.append(10)
    defer { bytes.resetBytes(in: 0..<bytes.count) }
    // The password travels only through sudo's stdout pipe, never the context
    // socket, logging, subprocess argv or environment.
    try FileHandle.standardOutput.write(contentsOf: bytes)
    return 0
}
do { exit(try runAskpass()) } catch { exit(1) }
