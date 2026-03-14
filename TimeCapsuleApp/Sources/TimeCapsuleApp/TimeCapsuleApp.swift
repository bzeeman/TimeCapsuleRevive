import SwiftUI

@main
struct TimeCapsuleReviveApp: App {
    @State private var monitor = TimeCapsuleMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(monitor)
                .task {
                    monitor.startMonitoring()
                }
        } label: {
            Label("Time Capsule", systemImage: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
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
}
