import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show(monitor: TimeCapsuleMonitor) {
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            let view = SettingsView()
                .environment(monitor)

            let hostingView = NSHostingView(rootView: view)
            hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 320)

            let window = NSWindow(
                contentRect: hostingView.frame,
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "TimeCapsule Revive Settings"
            window.contentView = hostingView
            window.center()
            window.isReleasedWhenClosed = false
            window.delegate = self

            self.window = window
            window.makeKeyAndOrderFront(nil)
        }

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
