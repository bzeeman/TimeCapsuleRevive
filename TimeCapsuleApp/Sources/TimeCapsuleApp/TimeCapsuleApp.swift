import SwiftUI

@main
struct TimeCapsuleReviveApp: App {
    @State private var monitor = TimeCapsuleMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
        } label: {
            Label("Time Capsule", systemImage: menuBarIcon)
        }

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }

    private var menuBarIcon: String {
        if monitor.device.isSambaRunning {
            return "externaldrive.fill.badge.timemachine"
        }
        if monitor.device.isOnline {
            return "externaldrive.fill.badge.exclamationmark"
        }
        return "externaldrive.badge.xmark"
    }

    init() {
        // Start monitoring on launch
        Task { @MainActor in
            monitor.startMonitoring()
        }
    }
}
