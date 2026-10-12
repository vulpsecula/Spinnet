import Foundation
import Darwin
import SpinnetCore

/// Fixed pkgutil reads inherit the inventory worker's group. Killing that
/// group covers the whole read, without a sampling/orphaning race.
enum ReceiptQuery {
    static func execute(_ arguments: [String], _ deadline: Date) throws -> Data {
        let verbs = ["--pkg-info-plist", "--export-plist", "--files"]
        guard arguments == ["--pkgs"] || (arguments.count == 2 && verbs.contains(arguments[0])
            && arguments[1].utf8.count <= 200 && arguments[1].range(of: "^[A-Za-z0-9][A-Za-z0-9_.-]+$", options: .regularExpression) != nil) else {
            throw PluginHostServiceError.tool(.planChanged)
        }
        let maximum = arguments.first == "--files" ? 16 * 1024 * 1024 : 4 * 1024 * 1024
        let absolute = ProcessInfo.processInfo.systemUptime + max(0, deadline.timeIntervalSinceNow)
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw PluginHostServiceError.tool(.failed) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
            close(descriptors[0]); close(descriptors[1]); throw PluginHostServiceError.tool(.failed)
        }
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        var mask = sigset_t(); sigemptyset(&mask)
        var defaults = sigset_t(); sigfillset(&defaults)
        let setup = [
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO),
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0),
            posix_spawn_file_actions_addclose(&actions, descriptors[0]),
            posix_spawn_file_actions_addclose(&actions, descriptors[1]),
            posix_spawnattr_setsigmask(&attributes, &mask),
            posix_spawnattr_setsigdefault(&attributes, &defaults),
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        ]
        guard setup.allSatisfy({ $0 == 0 }) else { close(descriptors[0]); close(descriptors[1]); throw PluginHostServiceError.tool(.failed) }
        let argv = (["/usr/sbin/pkgutil"] + arguments).map { strdup($0) } + [nil]
        let environment: [String] = ["LANG=C", "LC_ALL=C", "PATH=/usr/bin:/bin:/usr/sbin:/sbin"]
        let env = environment.map { strdup($0) } + [nil]
        defer { for item in argv + env { if let item { free(item) } } }
        var child: pid_t = 0
        let spawned = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in
            posix_spawn(&child, "/usr/sbin/pkgutil", &actions, &attributes, UnsafeMutablePointer(mutating: a.baseAddress!), UnsafeMutablePointer(mutating: e.baseAddress!))
        } }
        close(descriptors[1])
        guard spawned == 0 else { close(descriptors[0]); throw PluginHostServiceError.tool(.failed) }
        defer { close(descriptors[0]) }
        guard fcntl(descriptors[0], F_SETFL, O_NONBLOCK) == 0 else { kill(child, SIGKILL); throw PluginHostServiceError.tool(.failed) }
        var output = Data(), status: Int32 = 0, exited = false, eof = false
        do {
            while !exited || !eof {
                guard ProcessInfo.processInfo.systemUptime < absolute else { throw PluginHostServiceError.tool(.timedOut) }
                var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                let count = Darwin.read(descriptors[0], &bytes, bytes.count)
                if count > 0 {
                    guard output.count <= maximum - count else { throw PluginHostServiceError.tool(.outputTooLarge) }
                    output.append(contentsOf: bytes.prefix(count))
                } else if count == 0 { eof = true }
                else if errno != EAGAIN && errno != EINTR { throw PluginHostServiceError.tool(.failed) }
                if !exited {
                    let result = waitpid(child, &status, WNOHANG)
                    guard result >= 0 || errno == EINTR else { throw PluginHostServiceError.tool(.failed) }
                    exited = result == child
                }
                if !exited || !eof { usleep(1000) }
            }
        } catch {
            if !exited { kill(child, SIGKILL) }
            // Parent supervises this group if a kernel wait cannot terminate.
            if !exited { _ = waitpid(child, &status, 0) }
            throw error
        }
        guard status == 0 else { throw PluginHostServiceError.unavailable("Native receipt inventory is incomplete") }
        return output
    }
}
