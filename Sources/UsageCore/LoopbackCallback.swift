import Darwin
import Foundation

/// A one-request HTTP listener on 127.0.0.1 that catches the OAuth redirect.
/// Plain BSD sockets: it lives for one sign-in, so a framework would be overkill.
final class LoopbackCallback: Sendable {
    let port: UInt16
    private let fd: Int32

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UsageError.unavailable("Could not open a local port for sign-in") }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else {
            Darwin.close(fd)
            throw UsageError.unavailable("Could not open a local port for sign-in")
        }
        self.fd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { Darwin.close(fd) }

    /// Blocks until `/callback` is hit or the timeout passes, and returns its query parameters.
    /// Other paths the browser asks for (favicon) get a 404 and we keep waiting.
    func waitForCallback(timeout: TimeInterval) throws -> [String: String] {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw UsageError.unavailable("Sign-in timed out") }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, Int32(min(remaining, 60) * 1000)) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            defer { Darwin.close(client) }

            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(client, &buffer, buffer.count)
            guard n > 0, let request = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            // "GET /callback?code=…&state=… HTTP/1.1"
            let target = request.split(separator: " ", maxSplits: 2).dropFirst().first.map(String.init) ?? ""
            guard let components = URLComponents(string: target), components.path == "/callback" else {
                respond(client, status: "404 Not Found", body: "")
                continue
            }
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name] = item.value }
            let ok = params["code"] != nil
            respond(client, status: "200 OK", body: ok
                ? "<h3>Signed in to AI Usage Tracker.</h3><p>You can close this tab.</p>"
                : "<h3>Sign-in was not completed.</h3><p>Try again from the menu bar.</p>")
            return params
        }
    }

    private func respond(_ client: Int32, status: String, body: String) {
        let html = "<!doctype html><meta charset=utf-8><body style=\"font:15px -apple-system;padding:2em\">\(body)"
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        _ = response.withCString { write(client, $0, strlen($0)) }
    }
}
