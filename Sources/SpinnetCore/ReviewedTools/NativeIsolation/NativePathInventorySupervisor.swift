import Foundation
import Darwin
import Security

/// Fixed read-only subprocess boundary for open/getattr/readdir/hash stalls.
/// The lane remains occupied until an interrupted kernel worker is reaped.
enum NativePathInventorySupervisor {
    private static let lane = NSLock()
    private static var active = false
    static func capture(_ request: HomebrewPathManifest.Request, worker: HomebrewPathManifest.WorkerConfiguration, isCancelled: @escaping () -> Bool) throws -> HomebrewPathManifest.Response {
        let data = try run(try JSONEncoder().encode(request), deadline: request.deadline, mode: "--capture", worker: worker, isCancelled: isCancelled)
        do { return try JSONDecoder().decode(HomebrewPathManifest.Response.self, from: data) } catch { throw PluginHostServiceError.tool(.failed) }
    }
    static func captureKext(_ request: HomebrewNativeKextRemoval.Request, worker: HomebrewPathManifest.WorkerConfiguration, isCancelled: @escaping () -> Bool) throws -> HomebrewNativeKextRemoval.Response {
        let data = try run(try JSONEncoder().encode(request), deadline: request.deadline, mode: "--capture-kexts", worker: worker, isCancelled: isCancelled)
        do { return try JSONDecoder().decode(HomebrewNativeKextRemoval.Response.self, from: data) } catch { throw PluginHostServiceError.tool(.failed) }
    }
    private static func run(_ bytes: Data, deadline: Date, mode: String, worker: HomebrewPathManifest.WorkerConfiguration, isCancelled: @escaping () -> Bool) throws -> Data {
        guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
        let expires = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
        func check() throws {
            guard !isCancelled() else { throw PluginHostServiceError.tool(.planChanged) }
            guard ProcessInfo.processInfo.systemUptime < expires else { throw PluginHostServiceError.tool(.timedOut) }
        }
        try check()
        guard bytes.count <= 64 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
        // Root accepts only fixed signed copies already placed by Host staging.
        // The unprivileged development lane uses the same named package product.
        if getuid() == 0 { try validateRootTool(worker.executable) }
        lane.lock(); guard !active else { lane.unlock(); throw PluginHostServiceError.unavailable("The previous native path inventory is still stopping") }
        active = true; lane.unlock()
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { release(); throw PluginHostServiceError.tool(.failed) }
        guard pipe(&output) == 0 else { input.forEach { close($0) }; release(); throw PluginHostServiceError.tool(.failed) }
        guard pipe(&errors) == 0 else { (input + output).forEach { close($0) }; release(); throw PluginHostServiceError.tool(.failed) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else { (input + output + errors).forEach { close($0) }; release(); throw PluginHostServiceError.tool(.failed) }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigfillset(&defaults)
        var actionStatus = posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO)
        actionStatus |= posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO)
        actionStatus |= posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO)
        for fd in input + output + errors { actionStatus |= posix_spawn_file_actions_addclose(&actions, fd) }
        actionStatus |= posix_spawnattr_setsigmask(&attributes, &mask)
        actionStatus |= posix_spawnattr_setsigdefault(&attributes, &defaults)
        actionStatus |= posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        actionStatus |= posix_spawnattr_setpgroup(&attributes, 0)
        guard actionStatus == 0 else { (input + output + errors).forEach { close($0) }; release(); throw PluginHostServiceError.tool(.failed) }
        let argv = [strdup(worker.executable.path), strdup(mode), nil]
        let env = [strdup("PATH=/usr/bin:/bin:/usr/sbin:/sbin"), strdup("LANG=C"), strdup("LC_ALL=C"), nil]
        defer { for value in argv + env { if let value { free(value) } } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&child, worker.executable.path, &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!)) } }
        close(input[0]); close(output[1]); close(errors[1])
        guard result == 0 else { [input[1], output[0], errors[0]].forEach { close($0) }; release(); throw PluginHostServiceError.tool(.failed) }
        var writer = input[1], reaped = false, status: Int32 = 0
        defer {
            if writer >= 0 { close(writer) }; close(output[0]); close(errors[0])
            if !reaped {
                kill(-child, SIGKILL)
                let leader = child
                DispatchQueue.global(qos: .utility).async {
                    var value: Int32 = 0
                    while waitpid(leader, &value, 0) < 0 && errno == EINTR {}
                    release()
                }
            } else { release() }
        }
        for fd in [writer, output[0], errors[0]] { guard fcntl(fd, F_SETFL, O_NONBLOCK) >= 0 else { throw PluginHostServiceError.tool(.failed) } }
        guard fcntl(writer, F_SETNOSIGPIPE, 1) == 0 else { throw PluginHostServiceError.tool(.failed) }
        var written = 0, captured = Data(), stderrBytes = 0, stdoutOpen = true, stderrOpen = true
        while true {
            try check()
            if writer >= 0 {
                var ready = pollfd(fd: writer, events: Int16(POLLOUT), revents: 0)
                if poll(&ready, 1, 0) > 0 {
                    guard ready.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else { throw PluginHostServiceError.tool(.failed) }
                    let count = bytes.withUnsafeBytes { raw in Darwin.write(writer, raw.baseAddress!.advanced(by: written), min(4096, bytes.count - written)) }
                    if count > 0 { written += count }
                    else if count < 0 && errno != EINTR && errno != EAGAIN { throw PluginHostServiceError.tool(.failed) }
                    if written == bytes.count { close(writer); writer = -1 }
                }
            }
            for (fd, standardOutput) in [(output[0], true), (errors[0], false)] {
                if standardOutput ? !stdoutOpen : !stderrOpen { continue }
                var buffer = [UInt8](repeating: 0, count: 16384)
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    if standardOutput { guard captured.count + count <= HomebrewPathManifest.maximumResponseBytes else { throw PluginHostServiceError.tool(.outputTooLarge) }; captured.append(contentsOf: buffer.prefix(count)) }
                    else { stderrBytes += count; guard stderrBytes <= 32 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) } }
                } else if count == 0 { if standardOutput { stdoutOpen = false } else { stderrOpen = false } }
                else if errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }
            }
            if !reaped { let value = waitpid(child, &status, WNOHANG); if value == child { reaped = true }; if value < 0 && errno != EINTR { throw PluginHostServiceError.tool(.failed) } }
            if reaped && !stdoutOpen && !stderrOpen { break }
            var usage = rusage_info_v4()
            let measured = withUnsafeMutablePointer(to: &usage) { $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(child, RUSAGE_INFO_V4, $0) } }
            guard measured != 0 || usage.ri_phys_footprint <= 512 * 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            var ready = pollfd(fd: output[0], events: Int16(POLLIN), revents: 0)
            _ = poll(&ready, 1, 10)
        }
        guard status == 0 else { throw PluginHostServiceError.tool(.failed) }
        return captured
    }
    private static func release() { lane.lock(); active = false; lane.unlock() }
    private static func validateRootTool(_ path: URL) throws {
        let (parent, name) = try NativeFileQuarantine.openParent(path); defer { close(parent) }
        var file = stat(), directory = stat()
        guard fstat(parent, &directory) == 0, directory.st_uid == 0, directory.st_mode & 0o022 == 0,
              fstatat(parent, name, &file, AT_SYMLINK_NOFOLLOW) == 0, file.st_mode & S_IFMT == S_IFREG,
              file.st_uid == 0, file.st_nlink == 1, file.st_mode & 0o022 == 0 else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(path as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        var values: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &values) == errSecSuccess,
              let values = values as? [String: Any], values[kSecCodeInfoIdentifier as String] as? String == "com.vulpsecula.SpinnetHost.path-inventory",
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
    }
}
