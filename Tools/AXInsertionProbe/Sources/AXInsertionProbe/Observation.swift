import Foundation

/// What a probe page reports about its own field, through the page's own
/// script: the field's value as the DOM holds it, whether the field had the
/// page's focus, and the DOM events it saw. It reaches the probe over
/// `ObservationServer`, so it does not depend on Accessibility at all.
struct PageObservation: Codable, Equatable {
    var seq: Int
    /// load, poll (the value or focus changed between two 200 ms polls),
    /// input or focus.
    var reason: String
    var value: String
    var activeIsTarget: Bool
    var hasFocus: Bool
    /// The last DOM events on the field, such as `beforeinput:insertText`.
    var events: [String]
}

/// A tiny HTTP server on 127.0.0.1 that serves the probe's pages and
/// receives each page's observations of its own field. The pages are served
/// from here, not from file URLs, so their reports are same-origin requests
/// that no browser blocks.
///
///   GET  /page/<kind>?row=<row id>   the page for one row
///   POST /observe?row=<row id>       a PageObservation as JSON
final class ObservationServer {
    let marker: String
    private(set) var port: UInt16 = 0
    private var listener: Int32 = -1
    private let store = Box<[String: [PageObservation]]>([:])

    init(marker: String) { self.marker = marker }

    struct StartError: LocalizedError {
        let step: String
        var errorDescription: String? { "the probe's local page server could not \(step) (errno \(errno))" }
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError(step: "open a socket") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw StartError(step: "bind to 127.0.0.1") }
        guard listen(fd, 32) == 0 else { close(fd); throw StartError(step: "listen") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    func pageURL(_ kind: WebFieldKind, row: String) -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = Int(port)
        components.path = "/page/\(kind.rawValue)"
        components.queryItems = [URLQueryItem(name: "row", value: row)]
        return components.url!
    }

    func observations(row: String) -> [PageObservation] { store.value[row] ?? [] }

    func latest(row: String) -> PageObservation? { observations(row: row).max { $0.seq < $1.seq } }

    /// The latest observation once one satisfies `condition`, or the latest
    /// at the timeout.
    func wait(row: String, timeout: TimeInterval, until condition: (PageObservation) -> Bool) -> PageObservation? {
        Apps.poll(timeout, interval: 0.1) { latest(row: row).map(condition) ?? false }
        return latest(row: row)
    }

    func record(_ observation: PageObservation, row: String) {
        var all = store.value
        all[row, default: []].append(observation)
        store.value = all
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            // A browser may open a speculative connection and send nothing,
            // so every connection gets its own thread and a read timeout.
            Thread.detachNewThread { [weak self] in
                self?.handle(client)
                close(client)
            }
        }
    }

    private func handle(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        guard let request = Self.readRequest(client) else { return }
        let response = respond(to: request)
        response.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let sent = send(client, buffer.baseAddress! + offset, buffer.count - offset, 0)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var body: Data
    }

    static func readRequest(_ client: Int32) -> Request? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            data.append(buffer, count: count)
            headerEnd = data.range(of: separator)
            if data.count > 1_000_000 { return nil }
        }
        guard let headerEnd, let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == "content-length" { contentLength = Int(pair[1]) ?? 0 }
        }
        guard contentLength <= 1_000_000 else { return nil }
        var body = Data(data[headerEnd.upperBound...])
        while body.count < contentLength {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            body.append(buffer, count: count)
        }
        let components = URLComponents(string: String(parts[1]))
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return Request(method: String(parts[0]), path: components?.path ?? String(parts[1]), query: query,
                       body: body.prefix(contentLength))
    }

    func respond(to request: Request) -> Data {
        if request.method == "GET", request.path.hasPrefix("/page/"),
           let kind = WebFieldKind(rawValue: String(request.path.dropFirst("/page/".count))),
           let row = request.query["row"] {
            return Self.response(200, type: "text/html; charset=utf-8", body: Data(Pages.html(kind, marker: marker, row: row).utf8))
        }
        if request.method == "POST", request.path == "/observe", let row = request.query["row"] {
            guard let observation = try? JSONDecoder().decode(PageObservation.self, from: request.body) else {
                return Self.response(400, type: "text/plain", body: Data("bad observation".utf8))
            }
            record(observation, row: row)
            return Self.response(204, type: "text/plain", body: Data())
        }
        return Self.response(404, type: "text/plain", body: Data("not found".utf8))
    }

    static func response(_ status: Int, type: String, body: Data) -> Data {
        let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 404: "Not Found"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}

/// The checks of an insertion that do not go through Accessibility: the
/// page's own report, the file an editor saved, or the fixture's status.
enum IndependentChecks {
    /// The page's own report of its field, waiting up to `timeout` for the
    /// whole text. The page's state right now is kept as the state before.
    static func page(_ server: ObservationServer, row: String, timeout: TimeInterval = 3) -> (InsertionText) -> IndependentCheck {
        let before = server.latest(row: row)
        return { text in
            let source = "the page's own script (field value from the DOM), reported to the probe's 127.0.0.1 endpoint"
            guard let observation = server.wait(row: row, timeout: timeout, until: { $0.value.contains(text.text) }) else {
                return IndependentCheck(label: "page", source: source, observed: false, detail: "the page reported nothing")
            }
            var check = IndependentCheck(label: "page", source: source, value: observation.value, text: text)
            check.targetFocusedBefore = before.map { $0.activeIsTarget && $0.hasFocus }
            check.targetFocusedAfter = observation.activeIsTarget && observation.hasFocus
            check.events = observation.events
            return check
        }
    }

    /// Files an editor saves on its own (VS Code's and Cursor's auto save,
    /// Obsidian's note saving), read from disk until the text is there or
    /// `timeout` passes.
    static func files(_ list: @escaping () -> [URL], label: String, source: String,
                      timeout: TimeInterval) -> (InsertionText) -> IndependentCheck {
        { text in
            var contents: [(URL, String)] = []
            Apps.poll(timeout, interval: 0.25) {
                contents = list().compactMap { url in (try? String(contentsOf: url, encoding: .utf8)).map { (url, $0) } }
                return contents.contains { $0.1.contains(text.text) }
            }
            guard !contents.isEmpty else {
                return IndependentCheck(label: label, source: source, observed: false, detail: "no file to read")
            }
            let best = contents.first { $0.1.contains(text.marker) } ?? contents[0]
            var check = IndependentCheck(label: label, source: source, value: best.1, text: text)
            check.detail = best.0.lastPathComponent
            return check
        }
    }

    /// The fixture's own status file, which holds its control's value.
    static func fixture(_ status: URL) -> (InsertionText) -> IndependentCheck {
        { text in
            let source = "the fixture's own report of its control's value"
            var value: String?
            Apps.poll(1.5, interval: 0.1) {
                value = FixtureStatusRead.read(status)?.value
                return value?.contains(text.text) == true
            }
            guard let value else {
                return IndependentCheck(label: "fixture", source: source, observed: false, detail: "no status")
            }
            return IndependentCheck(label: "fixture", source: source, value: value, text: text)
        }
    }
}
