import AppKit

// Hand-written entry point: a menu bar-only app with no storyboard or SwiftUI scene.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
