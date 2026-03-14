import SwiftUI

struct MenuBarView: View {
    @Environment(TimeCapsuleMonitor.self) var monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status header
            statusSection

            Divider()

            // Shares
            sharesSection

            Divider()

            // Actions
            actionsSection

            Divider()

            // Footer
            HStack {
                Button("Settings...") {
                    SettingsWindowController.shared.show(monitor: monitor)
                }
                .keyboardShortcut(",")

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .frame(width: 280)
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        let device = monitor.device

        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .font(.title3)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if monitor.isChecking {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)

        if !monitor.lastEvent.isEmpty {
            Text(monitor.lastEvent)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private var sharesSection: some View {
        if monitor.shares.isEmpty {
            Button("Refresh Shares") {
                Task { await monitor.refreshShares() }
            }
            .padding(.horizontal, 4)
        } else {
            ForEach(monitor.shares) { share in
                HStack {
                    Image(systemName: share.isTimeMachine
                          ? "externaldrive.fill.badge.timemachine"
                          : "folder.fill")
                    Text(share.name)
                    Spacer()
                    Text(share.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        if monitor.device.isOnline {
            if monitor.device.isSambaRunning {
                Button {
                    Task { await monitor.stopSamba() }
                } label: {
                    Label("Stop Samba", systemImage: "stop.circle")
                }
                .padding(.horizontal, 4)
            } else {
                Button {
                    Task { await monitor.startSamba() }
                } label: {
                    Label("Start Samba", systemImage: "play.circle")
                }
                .padding(.horizontal, 4)
            }
        }

        Button {
            Task { await monitor.checkStatus() }
        } label: {
            Label("Check Now", systemImage: "arrow.clockwise")
        }
        .padding(.horizontal, 4)

        if monitor.device.isSambaRunning, !monitor.settings.host.isEmpty {
            Button {
                let url = URL(string: "smb://\(monitor.settings.host)/TimeMachine")!
                NSWorkspace.shared.open(url)
            } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Helpers

    private var statusIcon: String {
        if monitor.device.isSambaRunning { return "externaldrive.fill.badge.checkmark" }
        if monitor.device.isOnline { return "externaldrive.fill.badge.exclamationmark" }
        return "externaldrive.fill.badge.xmark"
    }

    private var statusColor: Color {
        if monitor.device.isSambaRunning { return .green }
        if monitor.device.isOnline { return .orange }
        return .red
    }

    private var statusText: String {
        if monitor.settings.host.isEmpty { return "Not configured" }
        if monitor.device.isSambaRunning { return "SMBv3 active on \(monitor.settings.host)" }
        if monitor.device.isOnline { return "Online — Samba not running" }
        return "Offline"
    }
}
