import Foundation
import Darwin
import Security

/// This channel carries permission to show a password window and command text.
/// Passwords never enter it: the askpass executable writes only to sudo's pipe.
public enum HomebrewAskpass {
    public static let identifier = "com.vulpsecula.SpinnetHost.homebrew-askpass"
    public static let socketEnvironment = "HOMEBREW_SPINNET_ASKPASS_SOCKET"
    public struct Context: Codable, Equatable {
        public let command: String
        public let verificationOnly: Bool
        public init(command: String, verificationOnly: Bool = false) {
            self.command = String(command.prefix(2048)); self.verificationOnly = verificationOnly
        }
    }
    public static func taskEnvironment(askpass: URL, socket: String) -> [String: String] {
        var environment = HomebrewReadProfile.environment
        environment.removeValue(forKey: "NONINTERACTIVE")
        environment.removeValue(forKey: "HOMEBREW_NO_SUDO")
        environment["SUDO_ASKPASS"] = askpass.path
        environment[socketEnvironment] = socket
        environment["HOMEBREW_NO_INSTALL_UPGRADE"] = "1"
        environment["HOMEBREW_NO_INSTALL_CLEANUP"] = "1"
        return environment
    }
    public static func connect(_ path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PluginHostServiceError.tool(.failed) }
        do {
            try withAddress(path) { address, size in
                guard Darwin.connect(fd, address, size) == 0 else { throw PluginHostServiceError.tool(.failed) }
            }
            configure(fd)
            return fd
        } catch { close(fd); throw error }
    }
    public static func receiveContext(_ fd: Int32) throws -> Context {
        try verifyPeer(fd, identifier: HomebrewSystemAuthorization.runnerIdentifier,
                       executable: try sibling("SpinnetToolTaskRunner"))
        return try JSONDecoder().decode(Context.self, from: receive(fd))
    }
    public static func sibling(_ name: String) throws -> URL {
        try HomebrewBackgroundUpdate.currentExecutableURL().deletingLastPathComponent().appendingPathComponent(name)
    }
    public static func verifyHostParent() throws {
        let pid = getppid()
        guard let birth = HomebrewTaskProcess.startIdentity(pid) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess,
              let code else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let expected = try sibling("SpinnetToolTaskRunner").deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("MacOS/SpinnetHost")
        try verifyCode(code, identifier: HomebrewSystemAuthorization.hostIdentifier, executable: expected)
        guard getppid() == pid, HomebrewTaskProcess.startIdentity(pid) == birth else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
    /// Native package code may invoke sudo, but must never obtain a password
    /// by launching our trusted password window with stdout redirected to itself.
    public static func verifySudoParent() throws {
        let pid = getppid()
        guard let birth = sudoParentIdentity(pid) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        // macOS sudo is execute-only for ordinary users, so validating its
        // static signature would itself require privilege. Use the kernel's
        // image path and the protected system file's Root ownership/mode.
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = path.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        var executable = stat()
        guard count > 0, String(cString: path) == "/usr/bin/sudo",
              lstat("/usr/bin/sudo", &executable) == 0, executable.st_mode & S_IFMT == S_IFREG,
              executable.st_uid == 0, executable.st_mode & 0o022 == 0, executable.st_mode & S_ISUID != 0,
              getppid() == pid, sudoParentIdentity(pid) == birth else {
            throw PluginHostServiceError.tool(.sourceNotAllowed)
        }
        var output = stat()
        guard fstat(STDOUT_FILENO, &output) == 0, output.st_mode & S_IFMT == S_IFIFO else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
    private struct ParentIdentity: Equatable {
        let seconds: Int
        let microseconds: Int
    }
    private static func sudoParentIdentity(_ pid: pid_t) -> ParentIdentity? {
        // PROC_PIDTBSDINFO is denied for setuid sudo to an ordinary askpass
        // process. KERN_PROC_PID exposes its birth without acquiring privilege.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.size
        guard pid > 1, sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size, info.kp_proc.p_pid == pid,
              info.kp_proc.p_starttime.tv_sec > 0 else { return nil }
        return ParentIdentity(seconds: info.kp_proc.p_starttime.tv_sec, microseconds: Int(info.kp_proc.p_starttime.tv_usec))
    }
    static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard path.hasPrefix("/"), bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw PluginHostServiceError.invalidInput("Askpass socket path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in destination.copyBytes(from: bytes) }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    static func send(_ data: Data, to fd: Int32) throws {
        guard data.count <= 8192 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        var framed = data; framed.append(10)
        try framed.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += count
            }
        }
    }
    static func receive(_ fd: Int32) throws -> Data {
        var result = Data(), byte: UInt8 = 0
        while result.count <= 8192 {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw PluginHostServiceError.tool(.failed) }
            if byte == 10 { return result }; result.append(byte)
        }
        throw PluginHostServiceError.tool(.outputTooLarge)
    }
    static func verifyPeer(_ fd: Int32, identifier: String, executable: URL) throws {
        var token = audit_token_t(), length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == MemoryLayout<audit_token_t>.size else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let audit = withUnsafeBytes(of: token) { Data($0) }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit as String: audit] as CFDictionary, [], &code) == errSecSuccess, let code else {
            throw PluginHostServiceError.tool(.sourceNotAllowed)
        }
        try verifyCode(code, identifier: identifier, executable: executable)
    }
    private static func verifyCode(_ code: SecCode, identifier: String, executable: URL) throws {
        var requirement: SecRequirement?
        let expression = try HomebrewSystemAuthorization.requirement(identifier: identifier)
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw PluginHostServiceError.tool(.sourceNotAllowed)
        }
        var staticCode: SecStaticCode?, information: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let values = information as? [String: Any], let actual = values[kSecCodeInfoMainExecutable as String] as? URL,
              actual.resolvingSymlinksInPath() == executable.resolvingSymlinksInPath() else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
    static func peerPID(_ fd: Int32) -> pid_t? {
        var pid: pid_t = 0, size = socklen_t(MemoryLayout<pid_t>.size)
        return getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0 && pid > 0 ? pid : nil
    }
    static func descendant(_ pid: pid_t, of ancestor: pid_t) -> Bool {
        var current = pid
        for _ in 0..<64 {
            if current == ancestor { return true }
            // The short form remains available across a setuid sudo ancestor;
            // the full BSD info requires privilege and incorrectly refuses it.
            var info = proc_bsdshortinfo()
            guard current > 1, proc_pidinfo(current, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return false }
            current = pid_t(info.pbsi_ppid)
        }
        return false
    }

    public final class Server {
        public let path: String
        private let directory: URL
        private let listener: Int32
        private let lock = NSLock()
        private var closed = false
        private var context: Context?
        private var client: Int32?
        private var prompting = false
        private let verify: (Int32) throws -> Void
        private let changed: (Bool) -> Void
        public var isRequestingPassword: Bool {
            lock.lock(); defer { lock.unlock() }; return prompting
        }
        public convenience init(changed: @escaping (Bool) -> Void) throws {
            let expected = try HomebrewAskpass.sibling("SpinnetHomebrewAskpass")
            try self.init(verify: { fd in
                try HomebrewAskpass.verifyPeer(fd, identifier: HomebrewAskpass.identifier, executable: expected)
                guard let pid = peerPID(fd), descendant(pid, of: getpid()) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
            }, changed: changed)
        }
        init(verify: @escaping (Int32) throws -> Void, changed: @escaping (Bool) -> Void) throws {
            self.verify = verify; self.changed = changed
            // sockaddr_un has a short path limit; never derive it from the
            // arbitrarily long app, account or journal path.
            directory = URL(fileURLWithPath: "/private/tmp/spinnet-askpass-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            path = directory.appendingPathComponent("socket").path
            listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard listener >= 0 else { try? FileManager.default.removeItem(at: directory); throw PluginHostServiceError.tool(.failed) }
            do {
                try withAddress(path) { address, size in
                    guard bind(listener, address, size) == 0, chmod(path, 0o600) == 0, listen(listener, 2) == 0 else { throw PluginHostServiceError.tool(.failed) }
                }
                _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
                _ = fcntl(listener, F_SETFL, O_NONBLOCK)
            } catch { Darwin.close(listener); try? FileManager.default.removeItem(at: directory); throw error }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve() }
        }
        public func setCommand(_ command: String?, verificationOnly: Bool = false) {
            lock.lock(); context = command.map { Context(command: $0, verificationOnly: verificationOnly) }
            if command == nil, let client { shutdown(client, SHUT_RDWR) }
            lock.unlock()
        }
        public func stop() {
            lock.lock(); closed = true; context = nil
            if let client { shutdown(client, SHUT_RDWR) }
            lock.unlock()
            try? FileManager.default.removeItem(at: directory)
        }
        deinit { Darwin.close(listener); try? FileManager.default.removeItem(at: directory) }
        private func serve() {
            defer { try? FileManager.default.removeItem(at: directory) }
            while true {
                lock.lock(); let stopped = closed; lock.unlock(); if stopped { return }
                var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                guard poll(&event, 1, 100) > 0 else { continue }
                let fd = accept(listener, nil, nil); guard fd >= 0 else { continue }
                configure(fd)
                do {
                    try verify(fd)
                    lock.lock(); let selected = context; let available = !closed && !prompting
                    if available && selected != nil { prompting = true; client = fd }; lock.unlock()
                    guard available, let selected else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
                    changed(true)
                    try send(JSONEncoder().encode(selected), to: fd)
                    // No password is accepted on this socket. The peer closes
                    // it after the prompt, cancellation or its own termination.
                    var event = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
                    while poll(&event, 1, 250) == 0 {
                        lock.lock(); let done = closed || context == nil; lock.unlock(); if done { break }
                    }
                } catch { /* Refuse without logging process data or credentials. */ }
                lock.lock(); let wasPrompting = client == fd
                if wasPrompting { client = nil; prompting = false }; lock.unlock()
                if wasPrompting { changed(false) }
                Darwin.close(fd)
            }
        }
    }
}
