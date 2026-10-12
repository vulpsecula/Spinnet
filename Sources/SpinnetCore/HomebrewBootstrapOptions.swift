import Foundation
import Darwin

/// Live configuration drift checks, not an immutable Homebrew snapshot.
/// bin/brew exports these data files before brew.sh invokes Ruby. In developer
/// mode its "warning" option is an arbitrary single Ruby option, including -r.
enum HomebrewBootstrapOptions {
    static func validate(executable: URL, environment: [String: String], deadline: Date,
                         cancellation: HostFetchedSections.Cancellation) throws {
        let refusal = PluginHostServiceError.unavailable("This Homebrew bootstrap configuration enables unreviewed executable options")
        let protected = Set(["HOMEBREW_BREW_FILE", "HOMEBREW_PREFIX", "HOMEBREW_REPOSITORY", "HOMEBREW_LIBRARY", "HOMEBREW_USER_CONFIG_HOME"])
        var values = environment, total = 0
        func read(_ url: URL) throws {
            guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
            guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
            // Regular config symlinks are supported (e.g. a dotfile manager).
            // The opened target itself must be bounded and owned by this user
            // or root; FIFOs/devices never block this prelaunch check.
            let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 { if errno == ENOENT || errno == ENOTDIR { return }; throw refusal }
            defer { close(fd) }
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                  before.st_uid == 0 || before.st_uid == getuid(), before.st_mode & 0o022 == 0,
                  before.st_size >= 0, before.st_size <= 256 * 1024 else { throw refusal }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                guard !cancellation.isCancelled else { throw PluginHostServiceError.unavailable("The reviewed read was cancelled") }
                guard Date() < deadline else { throw PluginHostServiceError.tool(.timedOut) }
                let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                if count < 0 { if errno == EINTR { continue }; throw refusal }
                if count == 0 { break }
                total += count; data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 256 * 1024, total <= 1024 * 1024 else { throw PluginHostServiceError.tool(.outputTooLarge) }
            }
            guard fstat(fd, &after) == 0, data.count == before.st_size, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
                  let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw refusal }
            for raw in text.split(separator: "\n") {
                // Match Bash `read -r line`'s IFS trimming, not shell evaluation.
                let line = String(raw).trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                guard line.hasPrefix("HOMEBREW_"), let separator = line.firstIndex(of: "=") else { continue }
                let rawKey = String(line[..<separator]), appended = rawKey.hasSuffix("+")
                let key = appended ? String(rawKey.dropLast()) : rawKey
                guard key.range(of: "^HOMEBREW_[A-Z0-9_]+$", options: .regularExpression) != nil else { throw refusal }
                // bin/brew ignores protected NAME=... but its regex permits
                // NAME+=..., which could redirect the reviewed Library tree.
                if protected.contains(key) { if appended { throw refusal }; continue }
                if key == "HOMEBREW_EXPERIMENTAL_RUST_FRONTEND" { continue }
                let value = String(line[line.index(after: separator)...])
                values[key] = (appended ? values[key, default: ""] : "") + value
            }
        }
        let system = URL(fileURLWithPath: "/etc/homebrew/brew.env")
        try read(system)
        let systemPriority = !(values["HOMEBREW_SYSTEM_ENV_TAKES_PRIORITY"] ?? "").isEmpty
        try read(HomebrewManagementReads.prefix(of: executable).appendingPathComponent("etc/homebrew/brew.env"))
        guard let home = environment["HOME"] else { throw refusal }
        let base = [values["XDG_CONFIG_HOME"], values["HOMEBREW_XDG_CONFIG_HOME"]].compactMap { $0 }.first(where: { !$0.isEmpty })
        let user = base.map { URL(fileURLWithPath: $0).appendingPathComponent("homebrew") } ?? URL(fileURLWithPath: home).appendingPathComponent(".homebrew")
        if let base, (!base.hasPrefix("/") || base.utf8.count > 2048 || base.contains("\n") || base.contains("\0")) { throw refusal }
        try read(user.appendingPathComponent("brew.env"))
        if systemPriority { try read(system) }
        if !(values["HOMEBREW_DEVELOPER"] ?? "").isEmpty,
           let warnings = values["HOMEBREW_RUBY_WARNINGS"], !warnings.isEmpty,
           !["-W0", "-W1", "-W2"].contains(warnings) { throw refusal }
        guard values["HOMEBREW_NO_BOOTSNAP"] != nil else { throw refusal }
    }
}
