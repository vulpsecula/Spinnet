import Foundation
import SpinnetCore

/// The production `HTTPSTransport`. It sends exactly one request on an
/// ephemeral session with no cookie store, cache, or credential storage, and
/// hands a redirect back to the Host's policy instead of following it.
final class URLSessionHTTPSTransport: NSObject, HTTPSTransport, URLSessionDataDelegate {
    private final class Exchange {
        let done = DispatchSemaphore(value: 0)
        let limit: Int
        var response: HTTPURLResponse?
        var body = Data()
        var error: Error?
        var tooLarge = false

        init(limit: Int) { self.limit = limit }
    }

    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        configuration.httpAdditionalHeaders = ["User-Agent": "Spinnet"]
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func send(_ request: HTTPSTransportRequest) throws -> HTTPSTransportResponse {
        var urlRequest = URLRequest(url: request.url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                                    timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpShouldHandleCookies = false
        urlRequest.httpBody = request.body
        for (name, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: name) }

        let exchange = Exchange(limit: request.maximumResponseBytes)
        let task = session.dataTask(with: urlRequest)
        lock.withLock { exchanges[task.taskIdentifier] = exchange }
        defer { _ = lock.withLock { exchanges.removeValue(forKey: task.taskIdentifier) } }
        task.resume()
        guard exchange.done.wait(timeout: .now() + request.timeout) == .success else {
            task.cancel()
            throw HTTPSTransportError.timedOut
        }
        if exchange.tooLarge { throw HTTPSTransportError.responseTooLarge }
        if let error = exchange.error as? URLError, error.code == .timedOut { throw HTTPSTransportError.timedOut }
        guard exchange.error == nil, let response = exchange.response else { throw HTTPSTransportError.connectionFailed }
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            if let name = name as? String, let value = value as? String { headers[name] = value }
        }
        return HTTPSTransportResponse(status: response.statusCode, headers: headers, body: exchange.body)
    }

    private func exchange(for task: URLSessionTask) -> Exchange? {
        lock.withLock { exchanges[task.taskIdentifier] }
    }

    // The Host decides where a redirect may go, so the 3xx response itself is
    // returned rather than followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        exchange(for: dataTask)?.response = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(for: dataTask) else { return }
        exchange.body.append(data)
        if exchange.body.count > exchange.limit {
            exchange.tooLarge = true
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = exchange(for: task) else { return }
        exchange.error = error
        exchange.done.signal()
    }
}
