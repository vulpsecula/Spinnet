import Foundation
import SpinnetCore
import XCTest
@testable import SpinnetHost

/// The production transport against a stubbed network. Host-Fetched
/// Sections send a view's requests at once, often as the transport's very
/// first requests, so each must get its own response and none may wait out
/// its timeout.
final class URLSessionHTTPSTransportTests: XCTestCase {
    func testConcurrentFirstRequestsEachGetTheirOwnResponse() throws {
        for _ in 0..<20 {
            let transport = URLSessionHTTPSTransport(protocolClasses: [PathEchoingURLProtocol.self])
            let paths = (0..<4).map { "/item/\($0)" }
            var bodies: [String: String] = [:]
            var failures: [String] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: paths.count) { index in
                let path = paths[index]
                do {
                    let response = try transport.send(HTTPSTransportRequest(
                        method: "GET", url: URL(string: "https://api.example.com\(path)")!, headers: [:], body: nil,
                        timeout: 2, maximumResponseBytes: HTTPSRequestBudgets.maximumResponseBodyBytes
                    ))
                    lock.withLock { bodies[path] = String(data: response.body, encoding: .utf8) }
                } catch {
                    lock.withLock { failures.append("\(path): \(error)") }
                }
            }
            XCTAssertEqual(failures, [])
            XCTAssertEqual(bodies, Dictionary(uniqueKeysWithValues: paths.map { ($0, #"{"path":"\#($0)"}"#) }))
        }
    }

    /// Cancelling stops the transfer itself: the send returns at once
    /// instead of waiting out its timeout.
    func testCancellingStopsTheTransferAtOnce() throws {
        let transport = URLSessionHTTPSTransport(protocolClasses: [SilentURLProtocol.self])
        let cancellation = HostFetchedSections.Cancellation()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { cancellation.cancel() }
        let started = Date()
        XCTAssertThrowsError(try transport.send(HTTPSTransportRequest(
            method: "GET", url: URL(string: "https://images.example.com/slow.png")!, headers: [:], body: nil,
            timeout: 10, maximumResponseBytes: 1024
        ), cancellation: cancellation)) {
            XCTAssertEqual($0 as? HTTPSTransportError, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)

        // Already cancelled: nothing is sent.
        XCTAssertThrowsError(try transport.send(HTTPSTransportRequest(
            method: "GET", url: URL(string: "https://images.example.com/slow.png")!, headers: [:], body: nil,
            timeout: 10, maximumResponseBytes: 1024
        ), cancellation: cancellation)) {
            XCTAssertEqual($0 as? HTTPSTransportError, .cancelled)
        }
    }
}

/// Never answers.
final class SilentURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}

/// Answers every request with its own path as JSON.
final class PathEchoingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"path":"\#(url.path)"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
