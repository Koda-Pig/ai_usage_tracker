import Foundation

/// One rate-limit window (the 5-hour session or the weekly limit).
public struct UsageWindow: Sendable, Equatable {
    public var usedPercent: Double   // 0–100
    public var resetsAt: Date?

    public init(usedPercent: Double, resetsAt: Date?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    /// Once the reset time has passed the window has rolled over, so nothing is used yet.
    /// This keeps cached or log-sourced numbers honest between fetches.
    public func percent(at now: Date) -> Double {
        if let resetsAt, resetsAt <= now { return 0 }
        return usedPercent
    }

    /// Available allowance, like battery fullness: 100 is full and 0 is exhausted.
    public func remainingPercent(at now: Date) -> Double {
        100 - min(max(percent(at: now), 0), 100)
    }
}

public struct ProviderUsage: Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case live
        /// Codex session log: only as fresh as the last Codex request, at `asOf`.
        case sessionLog(asOf: Date)
    }

    public var fiveHour: UsageWindow?
    public var weekly: UsageWindow?
    public var plan: String?
    public var source: Source
    public var fetchedAt: Date

    public init(fiveHour: UsageWindow?, weekly: UsageWindow?, plan: String?, source: Source = .live, fetchedAt: Date = Date()) {
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.plan = plan
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

public enum UsageError: Error, Sendable, Equatable, CustomStringConvertible {
    case signedOut
    case rateLimited(retryAfter: TimeInterval)
    case http(Int)
    case malformed(String)
    case unavailable(String)

    public var description: String {
        switch self {
        case .signedOut: "Not signed in"
        case .rateLimited: "Rate limited, will retry later"
        case .http(let code): "HTTP \(code)"
        case .malformed(let what): "Unexpected response: \(what)"
        case .unavailable(let why): why
        }
    }
}

enum DateParsing {
    /// Anthropic timestamps carry microseconds ("2026-10-13T11:00:00.302391+00:00"); some have none.
    static func iso8601(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }
}
