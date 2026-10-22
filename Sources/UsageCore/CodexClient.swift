import Foundation

/// Codex usage without ever touching Codex's tokens.
///
/// Live: start `codex app-server`, ask `account/rateLimits/read` over JSON-RPC on stdio, quit.
/// Codex signs the request and refreshes its own login. About 1.3 s wall, 0.25 s CPU per call
/// (codex-cli 0.147.0, 2026-10-22), so nothing is left running between refreshes.
///
/// Fallback: the newest session log in ~/.codex/sessions, which carries the same numbers as of
/// the last Codex request. Used when the CLI is missing or offline.
public struct CodexClient: Sendable {
    private let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let home = home
        return try await ClaudeClient.offMain {
            do {
                guard let binary = Self.locateBinary(home: home) else {
                    throw UsageError.unavailable("Codex CLI not found")
                }
                return try Self.parseAppServer(Self.queryAppServer(binary: binary))
            } catch {
                if let logged = Self.latestFromSessionLogs(home: home) { return logged }
                throw error
            }
        }
    }

    // MARK: Live

    /// GUI apps don't inherit the shell PATH, so look where installers put it.
    static func locateBinary(home: URL) -> URL? {
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            home.appendingPathComponent(".local/bin/codex").path,
            home.appendingPathComponent(".npm-global/bin/codex").path,
            home.appendingPathComponent(".bun/bin/codex").path,
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    /// Blocking. Pipelines initialize → initialized → read; requests are handled in order.
    static func queryAppServer(binary: URL, timeout: TimeInterval = 10) throws -> Data {
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        // An npm-installed codex is a node script; give it a PATH that finds node.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = [binary.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].joined(separator: ":")
        process.environment = env
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageError.unavailable("Could not start codex") }
        defer {
            if process.isRunning { process.terminate() }
            try? stdin.fileHandleForWriting.close()
        }
        // Closing the pipe on timeout turns the blocking read below into EOF.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let messages: [[String: Any]] = [
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "ai_usage_tracker", "title": "AI Usage Tracker", "version": "0.1.0"]]],
            ["jsonrpc": "2.0", "method": "initialized"],
            ["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [String: Any]()],
        ]
        var payload = Data()
        for m in messages {
            payload.append(try JSONSerialization.data(withJSONObject: m))
            payload.append(0x0A)
        }
        try stdin.fileHandleForWriting.write(contentsOf: payload)

        var buffer = Data()
        let reader = stdout.fileHandleForReading
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { throw UsageError.unavailable("codex app-server gave no answer") }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      obj["id"] as? Int == 2 else { continue }   // skip id 1 and notifications
                if let result = obj["result"] { return try JSONSerialization.data(withJSONObject: result) }
                let message = (obj["error"] as? [String: Any])?["message"] as? String ?? "unknown error"
                throw UsageError.unavailable("Codex: \(message)")
            }
        }
    }

    // MARK: Parsing

    /// Shape shared by app-server (camelCase) and session logs (snake_case, converted on decode).
    /// The window length key differs: `windowDurationMins` live, `window_minutes` in logs.
    struct RateLimits: Decodable {
        struct Window: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
            let windowMinutes: Int?
            let resetsAt: Double?        // epoch seconds
            var minutes: Int? { windowDurationMins ?? windowMinutes }
        }
        let primary: Window?
        let secondary: Window?
        let planType: String?
    }

    static func parseAppServer(_ data: Data, at now: Date = Date()) throws -> ProviderUsage {
        struct Result: Decodable { let rateLimits: RateLimits? }
        guard let limits = (try? JSONDecoder().decode(Result.self, from: data))?.rateLimits else {
            throw UsageError.malformed("Codex rate limits")
        }
        return usage(from: limits, source: .live, at: now)
    }

    /// Codex names windows primary/secondary; sort them by length rather than trusting the order.
    static func usage(from limits: RateLimits, source: ProviderUsage.Source, at now: Date) -> ProviderUsage {
        var fiveHour: UsageWindow?, weekly: UsageWindow?
        for (index, w) in [limits.primary, limits.secondary].enumerated() {
            guard let w else { continue }
            let window = UsageWindow(usedPercent: w.usedPercent, resetsAt: w.resetsAt.map(Date.init(timeIntervalSince1970:)))
            let isShort = w.minutes.map { $0 <= 6 * 60 } ?? (index == 0)
            if isShort { fiveHour = window } else { weekly = window }
        }
        return ProviderUsage(fiveHour: fiveHour, weekly: weekly, plan: limits.planType?.capitalized, source: source, fetchedAt: now)
    }

    // MARK: Session logs

    /// ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl. Walks newest-first and stops at the first hit,
    /// reading only the tail of each file.
    static func latestFromSessionLogs(home: URL) -> ProviderUsage? {
        let fm = FileManager.default
        func children(_ url: URL) -> [URL] {
            ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { !$0.lastPathComponent.hasPrefix(".") }
        }
        func newestFirst(_ urls: [URL]) -> [URL] { urls.sorted { $0.lastPathComponent > $1.lastPathComponent } }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }

        var checked = 0
        let root = home.appendingPathComponent(".codex/sessions")
        for year in newestFirst(children(root)) {
            for month in newestFirst(children(year)) {
                for day in newestFirst(children(month)) {
                    let files = children(day).filter { $0.pathExtension == "jsonl" }.sorted { modified($0) > modified($1) }
                    for file in files {
                        if let usage = lastRateLimits(in: file) { return usage }
                        checked += 1
                        if checked >= 8 { return nil }
                    }
                }
            }
        }
        return nil
    }

    static func lastRateLimits(in file: URL, tailBytes: UInt64 = 512 * 1024) -> ProviderUsage? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return parseSessionTail(data)
    }

    static func parseSessionTail(_ data: Data) -> ProviderUsage? {
        struct Line: Decodable {
            struct Payload: Decodable { let rateLimits: RateLimits? }
            let timestamp: String?
            let payload: Payload?
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let marker = Data("\"rate_limits\":{".utf8)
        for line in data.split(separator: 0x0A).reversed() where line.range(of: marker) != nil {
            guard let parsed = try? decoder.decode(Line.self, from: line), let limits = parsed.payload?.rateLimits else { continue }
            let asOf = parsed.timestamp.flatMap(DateParsing.iso8601) ?? Date()
            return usage(from: limits, source: .sessionLog(asOf: asOf), at: asOf)
        }
        return nil
    }
}
