import Foundation
import Network

/// Synthetic Google callbacks must never follow the public completion-page redirect.
func sendLocalOAuthCallback(to url: URL) async throws -> (Data, HTTPURLResponse) {
    guard url.scheme == "http", url.host == "127.0.0.1" else { throw URLError(.badURL) }
    let session = URLSession(configuration: .ephemeral, delegate: RejectOAuthRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (body, response) = try await session.data(from: url)
    guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    return (body, response)
}

private final class RejectOAuthRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Keeps the browser's write side open, and lets a test postpone reading until the
/// native authorization has finished and stopped its listener.
func sendOpenLoopbackRequest(to url: URL) async throws -> NWConnection {
    guard url.scheme == "http", url.host == "127.0.0.1", let port = url.port,
          let endpointPort = NWEndpoint.Port(rawValue: UInt16(port)) else { throw URLError(.badURL) }
    let connection = NWConnection(host: .ipv4(.loopback), port: endpointPort, using: .tcp)
    connection.start(queue: DispatchQueue(label: "app.yap.tests.google-callback"))
    let target = url.path + (url.query.map { "?" + $0 } ?? "")
    let request = "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: keep-alive\r\n\r\n"
    do {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        return connection
    } catch {
        connection.cancel()
        throw error
    }
}

func readLoopbackResponse(from connection: NWConnection) async throws -> String {
    var response = Data()
    while true {
        let (data, complete): (Data, Bool) = try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), complete)) }
            }
        }
        response += data
        if complete { return String(decoding: response, as: UTF8.self) }
    }
}
