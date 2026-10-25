import Foundation
import CryptoKit
import Darwin

/// Host-owned confirmation evidence for publisher-authorized `no_check` bytes.
/// Callers pass a verified metadata snapshot; no Plugin URL or command is accepted.
public enum HomebrewNoCheckSnapshot {
    public static let maximumBytes: Int64 = 8 * 1024 * 1024 * 1024
    public typealias Fetch = (URL, Int32, Int64, Date, @escaping () -> Bool) throws -> Void
    public struct Result: Codable, Equatable {
        public let fileURL: URL
        public let sha256: String
        public let sourceURL: URL
        public let byteCount: Int64
        public let sourceSHA256: String
        public let projectionSHA256: String
        public let configurationSHA256: String
    }
    private struct Receipt: Codable {
        let identity: String
        let sha256: String
        let byteCount: Int64
    }
    private struct Budget {
        let date: Date
        let uptime: UInt64
        init(_ requested: Date) {
            let remaining = max(0, min(900, requested.timeIntervalSinceNow))
            date = min(requested, Date().addingTimeInterval(remaining))
            uptime = DispatchTime.now().uptimeNanoseconds + UInt64(remaining * 1_000_000_000)
        }
    }
    public static func capture(snapshot: HomebrewPrivilegeMetadata.Snapshot, into directory: URL,
                               deadline: Date, expectedSHA256: String? = nil,
                               isCancelled: @escaping () -> Bool = { false },
                               fetch: Fetch = download) throws -> Result {
        let deadline = Budget(deadline)
        try check(deadline, isCancelled)
        if let expectedSHA256, !HomebrewPrivilegePlan.validDigest(expectedSHA256) { throw PluginHostServiceError.tool(.planChanged) }
        guard let evidence = snapshot.officialEvidence, let configuration = snapshot.configuration,
              case .string(let name)? = snapshot.metadata["name"], name.hasPrefix("homebrew/cask/"),
              case .string("no_check")? = snapshot.metadata["sha256"],
              case .string(let text)? = snapshot.metadata["url"], let source = URL(string: text),
              source.absoluteString == text, validSource(source) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let token = String(name.dropFirst("homebrew/cask/".count))
        try evidence.catalog.validate(snapshot.metadata, token: token, configuration: configuration)
        return try captureAuthenticated(name: name, source: source, sourceSHA256: evidence.catalog.envelopeSHA256,
            projection: evidence.catalog.projectionDigest(token, configuration: configuration), configuration: configuration,
            into: directory, deadline: deadline, expectedSHA256: expectedSHA256, publishedSHA256: nil, filenamePrefix: "no-check-", isCancelled: isCancelled, fetch: fetch)
    }
    /// Old-version code uses the original independently verified publisher
    /// checksum. no_check needs an already confirmed original-byte snapshot;
    /// this lane never invents provenance by downloading a fresh latest body.
    public static func capturePinnedSource(proof: HomebrewPrivilegePlan.SourceProof, name: String, into directory: URL,
                                          deadline: Date, expectedSHA256: String? = nil, isCancelled: @escaping () -> Bool = { false },
                                          allowConfirmedSourceMatch: Bool = false,
                                          fetch: Fetch = download) throws -> Result {
        let budget = Budget(deadline)
        try check(budget, isCancelled)
        guard HomebrewTaskInput.validPackageName(name) else { throw PluginHostServiceError.tool(.planChanged) }
        let metadata = try proof.verifiedProjection(name: name, prefix: proof.configuration.prefix.path, owner: getuid(), deadline: budget.date)
        guard case .string(let checksum)? = metadata["sha256"], case .string(let text)? = metadata["url"],
              let source = URL(string: text), source.absoluteString == text, validSource(source) else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        guard HomebrewPrivilegePlan.validDigest(checksum) || (checksum == "no_check" && allowConfirmedSourceMatch) else { throw PluginHostServiceError.unavailable("Original immutable bytes are missing for this historical no_check installer") }
        if let expectedSHA256, checksum != "no_check", expectedSHA256 != checksum { throw PluginHostServiceError.tool(.planChanged) }
        return try captureAuthenticated(name: name, source: source, sourceSHA256: proof.envelopeSHA256, projection: proof.projectionSHA256,
            configuration: proof.configuration, into: directory, deadline: budget, expectedSHA256: expectedSHA256, publishedSHA256: checksum == "no_check" ? nil : checksum,
            filenamePrefix: "native-payload-", isCancelled: isCancelled, fetch: fetch)
    }
    private static func captureAuthenticated(name: String, source: URL, sourceSHA256: String, projection: String,
                                             configuration: HomebrewSignedCaskCatalog.Configuration, into directory: URL, deadline: Budget,
                                             expectedSHA256: String?, publishedSHA256: String?, filenamePrefix: String,
                                             isCancelled: @escaping () -> Bool, fetch: Fetch) throws -> Result {
        let text = source.absoluteString
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let configurationHash = digest(try encoder.encode(configuration))
        let identity = digest(Data([name, sourceSHA256, projection, configurationHash, text].joined(separator: "\n").utf8))
        let filename = filenamePrefix + identity + ".archive", receiptName = filenamePrefix + identity + ".json"
        let (parent, basename) = try NativeFileQuarantine.openParent(directory); defer { close(parent) }
        let stage = openat(parent, basename, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(stage) }
        try privateDirectory(stage)
        let fileURL = directory.appendingPathComponent(filename)
        let prior = openat(stage, receiptName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if prior >= 0 {
            defer { close(prior) }
            try privateFile(prior, maximum: 4096)
            let bytes = try read(prior, maximum: 4096, deadline: deadline, isCancelled: isCancelled).bytes
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: bytes), receipt.identity == identity,
                  HomebrewPrivilegePlan.validDigest(receipt.sha256), receipt.byteCount > 0, receipt.byteCount <= maximumBytes else { throw PluginHostServiceError.tool(.planChanged) }
            let file = openat(stage, filename, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
            try privateFile(file, maximum: maximumBytes)
            let frozen = try hash(file, deadline: deadline, isCancelled: isCancelled)
            guard frozen.sha256 == receipt.sha256, frozen.count == receipt.byteCount,
                  (expectedSHA256 == nil || frozen.sha256 == expectedSHA256),
                  (publishedSHA256 == nil || frozen.sha256 == publishedSHA256) else { throw PluginHostServiceError.tool(.planChanged) }
            return .init(fileURL: fileURL, sha256: frozen.sha256, sourceURL: source, byteCount: frozen.count, sourceSHA256: sourceSHA256, projectionSHA256: projection, configurationSHA256: configurationHash)
        }
        guard errno == ENOENT else { throw PluginHostServiceError.tool(.planChanged) }
        // At launch the confirmed SHA is mandatory authority. Missing evidence
        // cannot be silently replaced with a fresh download after confirmation.
        guard expectedSHA256 == nil else { throw PluginHostServiceError.tool(.planChanged) }
        let file = openat(stage, filename, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        // An orphan or changed cache is never silently discarded and fetched again.
        guard file >= 0 else { throw PluginHostServiceError.tool(.planChanged) }; defer { close(file) }
        do {
            let downloadStarted = ProcessInfo.processInfo.systemUptime
            try fetch(source, file, maximumBytes, deadline.date, isCancelled)
            try check(deadline, isCancelled)
            guard fsync(file) == 0, fchmod(file, 0o400) == 0, lseek(file, 0, SEEK_SET) == 0 else { throw PluginHostServiceError.tool(.failed) }
            try privateFile(file, maximum: maximumBytes)
            let frozen = try hash(file, deadline: deadline, isCancelled: isCancelled)
            ReviewedTaskPreparationDiagnostics.downloadFinished(bytes: frozen.count, started: downloadStarted)
            guard publishedSHA256 == nil || frozen.sha256 == publishedSHA256 else { throw PluginHostServiceError.tool(.planChanged) }
            let bytes = try encoder.encode(Receipt(identity: identity, sha256: frozen.sha256, byteCount: frozen.count))
            let receipt = openat(stage, receiptName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard receipt >= 0 else { throw PluginHostServiceError.tool(.planChanged) }
            defer { close(receipt) }
            try writeAll(bytes, receipt)
            guard fsync(receipt) == 0, fchmod(receipt, 0o400) == 0, fsync(stage) == 0 else { throw PluginHostServiceError.tool(.failed) }
            try check(deadline, isCancelled)
            return .init(fileURL: fileURL, sha256: frozen.sha256, sourceURL: source, byteCount: frozen.count, sourceSHA256: sourceSHA256, projectionSHA256: projection, configurationSHA256: configurationHash)
        } catch {
            unlinkat(stage, filename, 0); unlinkat(stage, receiptName, 0)
            throw error
        }
    }
    private static func check(_ deadline: Budget, _ cancelled: () -> Bool) throws {
        if cancelled() { throw PluginHostServiceError.tool(.planChanged) }
        guard Date() < deadline.date, DispatchTime.now().uptimeNanoseconds < deadline.uptime else { throw PluginHostServiceError.tool(.timedOut) }
    }
    private static func validSource(_ source: URL) -> Bool {
        source.scheme == "https" && source.host?.isEmpty == false && source.user == nil && source.password == nil && source.fragment == nil && source.absoluteString.utf8.count <= 8192 && !source.absoluteString.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func noACL(_ fd: Int32) throws {
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var entry: acl_entry_t?
            guard acl_valid(acl) == 0, acl_get_entry(acl, ACL_FIRST_ENTRY.rawValue, &entry) != 0 else { throw PluginHostServiceError.tool(.planChanged) }
        } else if errno != ENOENT { throw PluginHostServiceError.tool(.planChanged) }
    }
    private static func privateDirectory(_ fd: Int32) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        try noACL(fd)
    }
    private static func privateFile(_ fd: Int32, maximum: Int64) throws {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_mode & 0o777 == 0o400, info.st_size > 0 else { throw PluginHostServiceError.tool(.planChanged) }
        guard info.st_size <= maximum else { throw PluginHostServiceError.tool(.outputTooLarge) }
        try noACL(fd)
    }
    private static func read(_ fd: Int32, maximum: Int64, deadline: Budget, isCancelled: () -> Bool) throws -> (bytes: Data, sha256: String, count: Int64) {
        try consume(fd, maximum: maximum, retain: true, deadline: deadline, isCancelled: isCancelled)
    }
    private static func hash(_ fd: Int32, deadline: Budget, isCancelled: () -> Bool) throws -> (sha256: String, count: Int64) {
        let result = try consume(fd, maximum: maximumBytes, retain: false, deadline: deadline, isCancelled: isCancelled)
        return (result.sha256, result.count)
    }
    private static func consume(_ fd: Int32, maximum: Int64, retain: Bool, deadline: Budget, isCancelled: () -> Bool) throws -> (bytes: Data, sha256: String, count: Int64) {
        var before = stat(); guard fstat(fd, &before) == 0 else { throw PluginHostServiceError.tool(.planChanged) }
        var sha = SHA256(), bytes = Data(), count: Int64 = 0, buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            try check(deadline, isCancelled)
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw PluginHostServiceError.tool(.failed) }; if size == 0 { break }
            count += Int64(size); guard count <= maximum else { throw PluginHostServiceError.tool(.outputTooLarge) }
            let data = Data(buffer.prefix(size)); sha.update(data: data); if retain { bytes.append(data) }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_ino == after.st_ino, before.st_dev == after.st_dev,
              before.st_size == after.st_size, count == before.st_size, before.st_mode == after.st_mode, after.st_nlink == 1,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PluginHostServiceError.tool(.planChanged) }
        return (bytes, sha.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func writeAll(_ data: Data, _ fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let size = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if size < 0 && errno == EINTR { continue }
                guard size > 0 else { throw PluginHostServiceError.tool(.failed) }; offset += size
            }
        }
    }
    public static func download(_ source: URL, _ fd: Int32, _ maximum: Int64, _ deadline: Date, _ isCancelled: @escaping () -> Bool) throws {
        guard validSource(source), maximum > 0, maximum <= maximumBytes else { throw PluginHostServiceError.tool(.sourceNotAllowed) }
        let deadline = Budget(deadline)
        try check(deadline, isCancelled)
        let held = dup(fd); guard held >= 0 else { throw PluginHostServiceError.tool(.failed) }
        let delegate = Downloader(fd: held, maximum: maximum)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = min(60, deadline.date.timeIntervalSinceNow)
        configuration.timeoutIntervalForResource = min(900, deadline.date.timeIntervalSinceNow)
        configuration.httpMaximumConnectionsPerHost = 1
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: URLRequest(url: source)); task.resume()
        while delegate.done.wait(timeout: .now() + 0.025) == .timedOut {
            do { try check(deadline, isCancelled) }
            catch { task.cancel(); throw error }
        }
        if let error = delegate.failure { throw error }
        try check(deadline, isCancelled)
    }
    private final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        private let fd: Int32, maximum: Int64
        private var count: Int64 = 0, redirects = 0
        private(set) var failure: Error?
        init(fd: Int32, maximum: Int64) { self.fd = fd; self.maximum = maximum }
        deinit { close(fd) }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.expectedContentLength <= maximum else { failure = PluginHostServiceError.tool(.failed); completionHandler(.cancel); return }
            completionHandler(.allow)
        }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard failure == nil else { return }
            count += Int64(data.count)
            guard count <= maximum else { failure = PluginHostServiceError.tool(.outputTooLarge); dataTask.cancel(); return }
            do { try writeAll(data, fd) } catch { failure = error; dataTask.cancel() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            redirects += 1
            guard redirects <= 3, let target = request.url, validSource(target) else { failure = PluginHostServiceError.tool(.sourceNotAllowed); completionHandler(nil); return }
            completionHandler(URLRequest(url: target))
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust { completionHandler(.performDefaultHandling, nil) }
            else { failure = PluginHostServiceError.tool(.sourceNotAllowed); completionHandler(.cancelAuthenticationChallenge, nil) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if failure == nil { failure = error }
            done.signal()
        }
    }
}
