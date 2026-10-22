import Foundation
import UsageCore

/// Last good numbers plus the last error, per provider. A failed fetch never clears good numbers.
struct ProviderStatus {
    var usage: ProviderUsage?
    var error: UsageError?
}

@MainActor
final class UsageStore {
    private(set) var claude = ProviderStatus()
    private(set) var codex = ProviderStatus()
    private(set) var claudeSignedIn = false
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    var onChange: () -> Void = {}

    let claudeClient = ClaudeClient(keychain: Keychain(service: "com.joshkoter.ai-usage-tracker"))
    private let codexClient = CodexClient()
    private var claudeBackoffUntil: Date?

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange()

        claudeSignedIn = await claudeClient.isSignedIn
        let skipClaude = !claudeSignedIn || (claudeBackoffUntil.map { $0 > Date() } ?? false)
        let claudeClient = claudeClient, codexClient = codexClient
        async let claudeResult: Result<ProviderUsage, UsageError>? = skipClaude ? nil : Self.capture { try await claudeClient.fetchUsage() }
        async let codexResult = Self.capture { try await codexClient.fetchUsage() }
        let (c, x) = await (claudeResult, codexResult)

        if !claudeSignedIn {
            claude.error = .signedOut
        } else if let c {
            apply(c, to: &claude)
            if case .failure(.rateLimited(let wait)) = c { claudeBackoffUntil = Date().addingTimeInterval(wait) }
            if case .failure(.signedOut) = c { claudeSignedIn = false }
        }
        apply(x, to: &codex)
        lastRefresh = Date()
        isRefreshing = false
        onChange()
    }

    func signInToClaude(open: @escaping @Sendable (URL) async -> Void) async {
        do {
            try await claudeClient.signIn(open: open)
            claudeBackoffUntil = nil
            claude = ProviderStatus()
        } catch {
            claude.error = Self.normalise(error)
            onChange()
            return
        }
        await refresh()
    }

    func signOutOfClaude() async {
        await claudeClient.signOut()
        claudeSignedIn = false
        claude = ProviderStatus(usage: nil, error: .signedOut)
        onChange()
    }

    private func apply(_ result: Result<ProviderUsage, UsageError>, to status: inout ProviderStatus) {
        switch result {
        case .success(let usage): status = ProviderStatus(usage: usage, error: nil)
        case .failure(let error): status.error = error
        }
    }

    nonisolated private static func capture(_ work: () async throws -> ProviderUsage) async -> Result<ProviderUsage, UsageError> {
        do { return .success(try await work()) }
        catch { return .failure(normalise(error)) }
    }

    nonisolated private static func normalise(_ error: any Error) -> UsageError {
        if let error = error as? UsageError { return error }
        if let error = error as? URLError {
            return .unavailable(error.code == .notConnectedToInternet ? "Offline" : "Network error")
        }
        return .unavailable(error.localizedDescription)
    }
}
