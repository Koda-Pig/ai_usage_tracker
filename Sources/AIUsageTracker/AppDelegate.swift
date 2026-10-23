import AppKit
import ServiceManagement
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Both providers' windows move in minutes, not seconds. Polling faster just burns energy
    /// and invites rate limits on Anthropic's usage endpoint.
    private static let pollInterval: TimeInterval = 5 * 60
    /// Opening the menu triggers a refresh when the numbers are older than this.
    private static let staleOnOpen: TimeInterval = 60

    private let store = UsageStore()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var timer: Timer?
    private var menuIsOpen = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let i = CommandLine.arguments.firstIndex(of: "--dump") {
            let dir = CommandLine.arguments.dropFirst(i + 1).first ?? NSTemporaryDirectory()
            Task { await dump(to: URL(fileURLWithPath: dir)) }
            return
        }
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        statusItem.button?.setAccessibilityLabel("AI allowance remaining")
        statusItem.button?.toolTip = "Allowance remaining · 5-hour above weekly"
        store.onChange = { [weak self] in self?.render() }
        render()

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer.tolerance = 60   // lets macOS coalesce our wake-ups with others
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Timers don't fire during sleep; catch up once on wake instead of waiting a full interval.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        Task { await store.refresh() }
    }

    private func render() {
        statusItem.button?.image = StatusImage.render(StatusImage.columns(claude: store.claude, codex: store.codex))
        if menuIsOpen { populate(menu) }
    }

    // MARK: NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if let last = store.lastRefresh, Date().timeIntervalSince(last) > Self.staleOnOpen { refresh() }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    // MARK: Menu

    private func populate(_ menu: NSMenu) {
        let now = Date()
        menu.removeAllItems()

        section(menu, title: "Claude", status: store.claude, now: now)
        if !store.claudeSignedIn {
            menu.addItem(item("Sign in to Claude…", action: #selector(signIn)))
        }
        menu.addItem(.separator())
        section(menu, title: "Codex", status: store.codex, now: now)
        menu.addItem(.separator())

        let refresh = item(store.isRefreshing ? "Refreshing…" : "Refresh", action: #selector(refreshNow), key: "r")
        refresh.isEnabled = !store.isRefreshing
        if let last = store.lastRefresh {
            refresh.subtitle = "Updated \(last.formatted(date: .omitted, time: .shortened))"
        }
        menu.addItem(refresh)
        if store.claudeSignedIn {
            menu.addItem(item("Sign Out of Claude", action: #selector(signOut)))
        }
        let login = item("Open at Login", action: #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit", action: #selector(quit), key: "q"))
    }

    private func section(_ menu: NSMenu, title: String, status: ProviderStatus, now: Date) {
        let header = NSMenuItem.sectionHeader(title: [title, status.usage?.plan].compactMap { $0 }.joined(separator: " · "))
        menu.addItem(header)
        if let usage = status.usage {
            menu.addItem(windowRow("5-hour", usage.fiveHour, now: now))
            menu.addItem(windowRow("Weekly", usage.weekly, now: now))
            if case .sessionLog(let asOf) = usage.source {
                menu.addItem(note("From Codex session log, \(asOf.formatted(.relative(presentation: .named)))"))
            }
        }
        if let error = status.error, error != .signedOut || status.usage != nil {
            menu.addItem(note(status.usage == nil ? error.description : "\(error.description) · showing last numbers"))
        }
    }

    private func windowRow(_ label: String, _ window: UsageWindow?, now: Date) -> NSMenuItem {
        let percent = window.map { "\(Int($0.remainingPercent(at: now).rounded()))%" } ?? "–"
        let reset = window?.resetsAt.flatMap { Self.resetText($0, now: now) } ?? ""

        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: 90), NSTextTab(textAlignment: .left, location: 104)]
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let title = NSMutableAttributedString(string: "\(label)\t\(percent)", attributes: [.font: font, .paragraphStyle: style])
        title.append(NSAttributedString(string: "\t\(reset)", attributes: [.font: font, .paragraphStyle: style, .foregroundColor: NSColor.secondaryLabelColor]))

        let row = NSMenuItem()
        row.attributedTitle = title
        row.image = UsageBar.image(fraction: (window?.remainingPercent(at: now) ?? 0) / 100)
        row.toolTip = "\(label) allowance remaining"
        return row   // no action: enabled so it reads at full contrast, but clicking does nothing
    }

    private func note(_ text: String) -> NSMenuItem {
        let row = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        row.isEnabled = false
        return row
    }

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    static func resetText(_ date: Date, now: Date) -> String? {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "reset" }
        if seconds < 24 * 3600 {
            let h = Int(seconds) / 3600, m = Int(seconds) % 3600 / 60
            return h > 0 ? "resets in \(h)h \(m)m" : "resets in \(m)m"
        }
        return "resets " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: Actions

    @objc private func refreshNow() { refresh() }

    @objc private func signIn() {
        Task { await store.signInToClaude(open: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } }) }
    }

    @objc private func signOut() {
        Task { await store.signOutOfClaude() }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = "Install the app to ~/Applications first (scripts/build.sh install). \(error.localizedDescription)"
            alert.runModal()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    /// `--dump [dir]`: one real refresh, print the menu as text, write the menu bar glyph to dir/status.png, exit.
    /// For checking the UI without screen-recording permission.
    private func dump(to dir: URL) async {
        await store.refresh()
        populate(menu)
        for item in menu.items {
            let text = item.isSeparatorItem ? "—" : (item.attributedTitle?.string ?? item.title).replacingOccurrences(of: "\t", with: "  ")
            print(text + (item.subtitle.map { "  (\($0))" } ?? ""))
        }
        let image = StatusImage.render(StatusImage.columns(claude: store.claude, codex: store.codex))
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 4), pixelsHigh: Int(image.size.height * 4),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("status.png"))
        exit(0)
    }
}

/// Small horizontal meter shown beside each window row.
enum UsageBar {
    static func image(fraction: Double) -> NSImage {
        let size = NSSize(width: 36, height: 6)
        let f = min(max(fraction, 0), 1)
        let image = NSImage(size: size, flipped: false) { rect in
            let radius = rect.height / 2
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            if f > 0 {
                // Blend through orange at 30% and reach red at 10% remaining.
                let color: NSColor
                if f > 0.3 {
                    color = NSColor.systemOrange.blended(withFraction: (f - 0.3) / 0.7, of: .systemGreen) ?? .systemGreen
                } else {
                    color = NSColor.systemRed.blended(withFraction: max(0, (f - 0.1) / 0.2), of: .systemOrange) ?? .systemRed
                }
                color.setFill()
                let fill = NSRect(x: 0, y: 0, width: max(rect.width * f, rect.height), height: rect.height)
                NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
            }
            return true
        }
        return image
    }
}
