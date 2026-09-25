import Foundation
@testable import SpinnetCore

/// Answers by host, from any thread, so the sections of one presentation can
/// run at once. A host may answer late or not at all.
///
/// Translator's results are still Host-Fetched Sections sent by the Host, so
/// its tests need the Host's transport answered as `ResultsPresentationTests`
/// answers it; this copy goes once they belong to a Plugin View whose sections
/// the kit can answer.
final class RoutedHTTPSTransport: HTTPSTransport {
    struct Route {
        var response: HTTPSTransportResponse?
        var delay: TimeInterval = 0
    }

    private let lock = NSLock()
    private var routes: [String: Route]
    private var sent: [HTTPSTransportRequest] = []

    init(_ routes: [String: Route] = [:]) { self.routes = routes }

    var requests: [HTTPSTransportRequest] { lock.withLock { sent } }

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        let route = lock.withLock { () -> Route? in
            sent.append(request)
            return routes[request.url.host ?? ""]
        }
        if let delay = route?.delay, delay > 0 { Thread.sleep(forTimeInterval: delay) }
        guard let response = route?.response else { throw HTTPSTransportError.connectionFailed }
        return response
    }

    static func json(_ body: String, status: Int = 200, delay: TimeInterval = 0) -> Route {
        Route(response: HTTPSTransportResponse(status: status, headers: ["content-type": "application/json"],
                                               body: Data(body.utf8)),
              delay: delay)
    }
}
