import CryptoKit
import Foundation
import Testing
@testable import UsageCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// MARK: Claude

@Test func claudeUsageDecodesFixture() throws {
    let usage = try ClaudeClient.parseUsage(fixture("claude-usage.json"))
    #expect(usage.fiveHour?.usedPercent == 7)
    #expect(usage.weekly?.usedPercent == 10)
    let reset = try #require(usage.fiveHour?.resetsAt)
    #expect(abs(reset.timeIntervalSince1970 - 1_791_889_200.302) < 0.01)   // 2026-10-13T11:00:00.302Z
}

@Test func windowReadsZeroAfterReset() {
    let w = UsageWindow(usedPercent: 80, resetsAt: Date(timeIntervalSince1970: 100))
    #expect(w.percent(at: Date(timeIntervalSince1970: 99)) == 80)
    #expect(w.percent(at: Date(timeIntervalSince1970: 100)) == 0)
}

@Test func pkceChallengeIsS256OfVerifier() {
    let pkce = ClaudeOAuth.PKCE.random()
    #expect(pkce.verifier.count == 43)
    let expected = Data(SHA256.hash(data: Data(pkce.verifier.utf8))).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    #expect(pkce.challenge == expected)
}

@Test func authorizeURLCarriesFlowParameters() throws {
    let pkce = ClaudeOAuth.PKCE.random()
    let url = ClaudeOAuth.authorizeURL(redirectURI: ClaudeOAuth.redirectURI(port: 54321), pkce: pkce)
    let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(q["redirect_uri"] == "http://localhost:54321/callback")
    #expect(q["scope"] == "user:profile")
    #expect(q["code_challenge_method"] == "S256")
    #expect(q["state"] == pkce.state)
}

@Test func tokenResponseKeepsOldRefreshTokenWhenOmitted() throws {
    let now = Date(timeIntervalSince1970: 1000)
    let t = try ClaudeOAuth.parseTokens(Data(#"{"access_token":"a2","expires_in":28800}"#.utf8), previousRefreshToken: "r1", now: now)
    #expect(t.accessToken == "a2")
    #expect(t.refreshToken == "r1")
    #expect(t.expiresAt == now.addingTimeInterval(28800))
    #expect(!t.description.contains("a2"))
}

@Test func expiredTokenIsRefreshedOnceThenUsageFetched() async throws {
    let store = MemoryStore()
    store.seed(ClaudeTokens(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-60)))
    let transport = StubTransport { request in
        if request.url == ClaudeOAuth.tokenURL {
            return (200, #"{"access_token":"new","refresh_token":"r2","expires_in":28800}"#)
        }
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer new")
        return (200, #"{"five_hour":{"utilization":42,"resets_at":null},"seven_day":{"utilization":31,"resets_at":null}}"#)
    }
    let client = ClaudeClient(transport: transport, keychain: store)

    async let a = client.fetchUsage()
    async let b = client.fetchUsage()
    let (first, second) = try await (a, b)

    #expect(first.fiveHour?.usedPercent == 42)
    #expect(second.weekly?.usedPercent == 31)
    #expect(transport.count(of: ClaudeOAuth.tokenURL) == 1)   // rotation must not be spent twice
    #expect(store.tokens?.refreshToken == "r2")
}

@Test func rejectedRefreshSignsOut() async throws {
    let store = MemoryStore()
    store.seed(ClaudeTokens(accessToken: "old", refreshToken: "r1", expiresAt: Date().addingTimeInterval(-60)))
    let client = ClaudeClient(transport: StubTransport { _ in (400, #"{"error":"invalid_grant"}"#) }, keychain: store)

    await #expect(throws: UsageError.signedOut) { try await client.fetchUsage() }
    #expect(store.tokens == nil)
    #expect(await client.isSignedIn == false)
}

@Test func rateLimitHonoursRetryAfter() async throws {
    let store = MemoryStore()
    store.seed(ClaudeTokens(accessToken: "ok", refreshToken: "r1", expiresAt: Date().addingTimeInterval(3600)))
    let client = ClaudeClient(transport: StubTransport { _ in (429, "{}", ["Retry-After": "120"]) }, keychain: store)
    await #expect(throws: UsageError.rateLimited(retryAfter: 120)) { try await client.fetchUsage() }
}

// MARK: Codex

@Test func codexAppServerDecodesFixture() throws {
    let usage = try CodexClient.parseAppServer(fixture("codex-ratelimits.json"))
    #expect(usage.fiveHour?.usedPercent == 0)
    #expect(usage.weekly?.usedPercent == 59)
    #expect(usage.weekly?.resetsAt == Date(timeIntervalSince1970: 1_793_087_127))
    #expect(usage.plan == "Team")
    #expect(usage.source == .live)
}

@Test func codexSessionTailUsesLastLineWithLimits() throws {
    let usage = try #require(CodexClient.parseSessionTail(fixture("codex-session-tail.jsonl")))
    #expect(usage.fiveHour?.usedPercent == 70)
    #expect(usage.weekly?.usedPercent == 59)
    #expect(usage.source == .sessionLog(asOf: try #require(DateParsing.iso8601("2026-10-21T15:02:36.128Z"))))
}

@Test func codexWindowsAreSortedByLengthNotPosition() {
    let limits = CodexClient.RateLimits(
        primary: .init(usedPercent: 59, windowDurationMins: 10080, windowMinutes: nil, resetsAt: nil),
        secondary: .init(usedPercent: 12, windowDurationMins: 300, windowMinutes: nil, resetsAt: nil),
        planType: nil
    )
    let usage = CodexClient.usage(from: limits, source: .live, at: Date())
    #expect(usage.fiveHour?.usedPercent == 12)
    #expect(usage.weekly?.usedPercent == 59)
}

// MARK: Stubs

private final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]

    func read(_ account: String) -> Data? { lock.withLock { items[account] } }
    func write(_ data: Data, for account: String) { lock.withLock { items[account] = data } }
    func delete(_ account: String) { lock.withLock { _ = items.removeValue(forKey: account) } }

    func seed(_ tokens: ClaudeTokens) { write(try! JSONEncoder().encode(tokens), for: "claude-oauth") }
    var tokens: ClaudeTokens? { read("claude-oauth").flatMap { try? JSONDecoder().decode(ClaudeTokens.self, from: $0) } }
}

private final class StubTransport: Transport, @unchecked Sendable {
    typealias Reply = (Int, String, [String: String])
    private let lock = NSLock()
    private var requests: [URL] = []
    private let handler: @Sendable (URLRequest) -> Reply

    init(_ handler: @escaping @Sendable (URLRequest) -> (Int, String)) {
        self.handler = { let (s, b) = handler($0); return (s, b, [:]) }
    }

    init(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        self.handler = handler
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { requests.append(request.url!) }
        // Yield so concurrent callers genuinely overlap inside the client.
        try await Task.sleep(for: .milliseconds(20))
        let (status, body, headers) = handler(request)
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func count(of url: URL) -> Int { lock.withLock { requests.filter { $0 == url }.count } }
}
