import Foundation

public struct ZoomHTTPTransport: Sendable {
    public var send: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    public init(send: @escaping @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)) { self.send = send }

    public static var live: Self {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoZoomRedirects(), delegateQueue: nil)
        return Self { request in
            let result: (Data, URLResponse)
            do { result = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw ZoomAccountError.network }
            guard let response = result.1 as? HTTPURLResponse else { throw ZoomAccountError.invalidResponse }
            return (result.0, response)
        }
    }
}

private final class NoZoomRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
