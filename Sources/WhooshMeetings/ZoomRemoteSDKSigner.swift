import Foundation

enum ZoomRemoteSDKSigner {
    static func signature(configuration: ZoomPublicConfiguration, tokens: ZoomOAuthTokens,
                          transport: ZoomHTTPTransport, now: Date = .now) async throws -> String {
        guard configuration.isValid else { throw ZoomAccountError.invalidPublicConfiguration }
        guard tokens.clientID == configuration.oauthPublicClientID,
              let grant = tokens.signingAuthorization, validHeaderToken(grant),
              validHeaderToken(tokens.accessToken) else { throw ZoomAccountError.notConnected }
        var request = URLRequest(url: configuration.sdkSignerURL, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(tokens.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(grant, forHTTPHeaderField: "X-Signing-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.httpBody = Data("{}".utf8)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.send(request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ZoomAccountError.signingUnavailable }
        try Task.checkCancellation()
        switch response.statusCode {
        case 401: throw ZoomAccountError.notConnected
        case 403: throw ZoomAccountError.signingDenied
        case 429: throw ZoomAccountError.rateLimited
        case 200: break
        default: throw ZoomAccountError.signingUnavailable
        }
        guard response.url == configuration.sdkSignerURL, data.count <= 16_384,
              let result = try? JSONDecoder().decode(Response.self, from: data) else {
            throw ZoomAccountError.invalidSigningResponse
        }
        try validate(result.signature, expiresAt: result.expiresAt, sdkClientID: configuration.sdkClientID, now: now)
        return result.signature
    }

    static func validHeaderToken(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 &&
            value.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7e }
    }

    /// TLS authenticates the pinned signing service; Zoom verifies the HMAC.
    /// The client additionally rejects wrong-app, malformed, or stale responses.
    static func validate(_ signature: String, expiresAt: TimeInterval, sdkClientID: String, now: Date) throws {
        let parts = signature.split(separator: ".", omittingEmptySubsequences: false)
        guard signature.utf8.count <= 8_192, parts.count == 3,
              let headerData = decode(String(parts[0])), let payloadData = decode(String(parts[1])),
              let mac = decode(String(parts[2])), mac.count == 32,
              let header = try? JSONDecoder().decode(Header.self, from: headerData),
              let payload = try? JSONDecoder().decode(Payload.self, from: payloadData),
              header.alg == "HS256", header.typ == "JWT", payload.appKey == sdkClientID,
              payload.iat.isFinite, payload.exp.isFinite, payload.tokenExp.isFinite, expiresAt.isFinite,
              payload.iat <= now.timeIntervalSince1970 + 60,
              payload.iat >= now.timeIntervalSince1970 - 300,
              payload.exp - payload.iat >= 1_800, payload.exp - payload.iat <= 7_200,
              payload.exp > now.timeIntervalSince1970 + 60,
              payload.tokenExp == payload.exp, expiresAt == payload.exp else {
            throw ZoomAccountError.invalidSigningResponse
        }
    }

    private static func decode(_ value: String) -> Data? {
        guard !value.isEmpty, value.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
    private struct Response: Decodable { let signature: String; let expiresAt: TimeInterval }
    private struct Header: Decodable { let alg: String; let typ: String }
    private struct Payload: Decodable { let appKey: String; let iat: TimeInterval; let exp: TimeInterval; let tokenExp: TimeInterval }
}
