import CryptoKit
import Foundation

/// The app's own Claude sign-in. Same public OAuth client and PKCE flow that `claude auth login` uses,
/// but a separate grant: our refresh token is ours, so refreshing it can never log Claude Code out,
/// and Claude Code's Keychain item is never read.
///
/// Undocumented. Constants copied from the Claude Code 2.1.287 binary on 2026-10-22. If Anthropic
/// changes them, sign-in or refresh fails with an HTTP error shown in the menu.
public enum ClaudeOAuth {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let authorizeURL = URL(string: "https://claude.com/cai/oauth/authorize")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// The usage endpoint needs only this. We never ask for inference.
    static let scope = "user:profile"

    public struct PKCE: Sendable {
        public let verifier: String
        public let challenge: String
        public let state: String

        public static func random() -> PKCE {
            let verifier = base64URL(randomBytes(32))
            return PKCE(
                verifier: verifier,
                challenge: base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                state: base64URL(randomBytes(32))
            )
        }
    }

    public static func redirectURI(port: UInt16) -> String {
        "http://localhost:\(port)/callback"
    }

    public static func authorizeURL(redirectURI: String, pkce: PKCE) -> URL {
        var c = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: scope),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: pkce.state),
        ]
        return c.url!
    }

    static func exchangeRequest(code: String, redirectURI: String, pkce: PKCE) -> URLRequest {
        jsonPost([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
            "state": pkce.state,
        ])
    }

    static func refreshRequest(refreshToken: String) -> URLRequest {
        jsonPost([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "scope": scope,
        ])
    }

    /// The token endpoint may omit `refresh_token` on refresh; then the old one stays valid.
    static func parseTokens(_ data: Data, previousRefreshToken: String? = nil, now: Date = Date()) throws -> ClaudeTokens {
        struct Response: Decodable {
            let accessToken: String
            let refreshToken: String?
            let expiresIn: Double
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let r = try? decoder.decode(Response.self, from: data),
              let refresh = r.refreshToken ?? previousRefreshToken else {
            throw UsageError.malformed("Claude token response")
        }
        return ClaudeTokens(accessToken: r.accessToken, refreshToken: refresh, expiresAt: now.addingTimeInterval(r.expiresIn))
    }

    private static func jsonPost(_ body: [String: String]) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func randomBytes(_ count: Int) -> Data {
        var g = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &g) })
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Stored as JSON in the app's own Keychain item. `description` is redacted so it can't leak into logs.
public struct ClaudeTokens: Codable, Sendable, Equatable, CustomStringConvertible {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date

    public var description: String { "ClaudeTokens(expiresAt: \(expiresAt))" }

    func expires(within interval: TimeInterval, of now: Date = Date()) -> Bool {
        expiresAt.timeIntervalSince(now) < interval
    }
}
