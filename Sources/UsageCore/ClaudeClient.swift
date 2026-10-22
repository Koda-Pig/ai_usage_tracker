import Foundation

/// Claude subscription usage via the app's own OAuth grant (see `ClaudeOAuth`).
public actor ClaudeClient {
    /// Undocumented: the endpoint behind Claude Code's `/usage`. Fixture: Tests/UsageCoreTests/Fixtures/claude-usage.json,
    /// observed 2026-10-13. It rate-limits hard if polled with bad tokens, so we never call it with one we know is expired.
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let account = "claude-oauth"
    /// Refresh this long before expiry so a fetch never races the deadline.
    private static let refreshMargin: TimeInterval = 300

    private let transport: Transport
    private let keychain: any SecretStore
    private var tokens: ClaudeTokens?
    private var loaded = false
    /// Refresh tokens rotate, so two overlapping refreshes would burn one. Everyone awaits the same task.
    private var refreshing: Task<ClaudeTokens, any Error>?

    public init(transport: Transport = URLSessionTransport(), keychain: any SecretStore) {
        self.transport = transport
        self.keychain = keychain
    }

    public var isSignedIn: Bool {
        loadIfNeeded()
        return tokens != nil
    }

    /// Opens the browser, waits for the localhost redirect, exchanges the code, stores the tokens.
    public func signIn(open: @Sendable (URL) async -> Void) async throws {
        let callback = try LoopbackCallback()
        let pkce = ClaudeOAuth.PKCE.random()
        let redirectURI = ClaudeOAuth.redirectURI(port: callback.port)
        await open(ClaudeOAuth.authorizeURL(redirectURI: redirectURI, pkce: pkce))

        let params = try await Self.offMain { try callback.waitForCallback(timeout: 300) }
        guard let code = params["code"] else { throw UsageError.unavailable("Sign-in was cancelled") }
        guard params["state"] == pkce.state else { throw UsageError.unavailable("Sign-in state mismatch") }

        let (data, response) = try await transport.send(ClaudeOAuth.exchangeRequest(code: code, redirectURI: redirectURI, pkce: pkce))
        guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
        store(try ClaudeOAuth.parseTokens(data))
    }

    public func signOut() {
        tokens = nil
        loaded = true
        keychain.delete(Self.account)
    }

    public func fetchUsage() async throws -> ProviderUsage {
        var current = try await validTokens()
        var (data, response) = try await transport.send(usageRequest(current.accessToken))
        if response.statusCode == 401 {
            // Revoked or clock skew: one forced refresh, then give up.
            current = try await refresh(current)
            (data, response) = try await transport.send(usageRequest(current.accessToken))
        }
        switch response.statusCode {
        case 200: return try Self.parseUsage(data)
        case 401: signOut(); throw UsageError.signedOut
        case 429: throw UsageError.rateLimited(retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 600)
        default: throw UsageError.http(response.statusCode)
        }
    }

    static func parseUsage(_ data: Data, at now: Date = Date()) throws -> ProviderUsage {
        struct Response: Decodable {
            struct Window: Decodable {
                let utilization: Double?   // 0–100
                let resetsAt: String?
            }
            let fiveHour: Window?
            let sevenDay: Window?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let r = try? decoder.decode(Response.self, from: data) else { throw UsageError.malformed("Claude usage") }
        func window(_ w: Response.Window?) -> UsageWindow? {
            guard let w, let u = w.utilization else { return nil }
            return UsageWindow(usedPercent: u, resetsAt: w.resetsAt.flatMap(DateParsing.iso8601))
        }
        return ProviderUsage(fiveHour: window(r.fiveHour), weekly: window(r.sevenDay), plan: nil, fetchedAt: now)
    }

    // MARK: Tokens

    private func validTokens() async throws -> ClaudeTokens {
        loadIfNeeded()
        guard let tokens else { throw UsageError.signedOut }
        return tokens.expires(within: Self.refreshMargin) ? try await refresh(tokens) : tokens
    }

    private func refresh(_ stale: ClaudeTokens) async throws -> ClaudeTokens {
        if let refreshing { return try await refreshing.value }
        let transport = transport
        let task = Task<ClaudeTokens, any Error> {
            let (data, response) = try await transport.send(ClaudeOAuth.refreshRequest(refreshToken: stale.refreshToken))
            switch response.statusCode {
            case 200: return try ClaudeOAuth.parseTokens(data, previousRefreshToken: stale.refreshToken)
            case 400, 401, 403: throw UsageError.signedOut   // invalid_grant: the grant is gone
            default: throw UsageError.http(response.statusCode)
            }
        }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            store(fresh)
            return fresh
        } catch UsageError.signedOut {
            signOut()
            throw UsageError.signedOut
        }
    }

    private func store(_ fresh: ClaudeTokens) {
        tokens = fresh
        loaded = true
        if let data = try? JSONEncoder().encode(fresh) { keychain.write(data, for: Self.account) }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        tokens = keychain.read(Self.account).flatMap { try? JSONDecoder().decode(ClaudeTokens.self, from: $0) }
    }

    private func usageRequest(_ accessToken: String) -> URLRequest {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Runs blocking work on a utility-QoS thread instead of tying up the cooperative pool.
    static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async { cont.resume(with: Result(catching: work)) }
        }
    }
}
