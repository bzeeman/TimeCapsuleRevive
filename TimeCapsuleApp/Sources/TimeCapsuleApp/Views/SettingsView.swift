import SwiftUI

struct SettingsView: View {
    @Environment(TimeCapsuleMonitor.self) var monitor

    @State private var host = ""
    @State private var password = ""
    @State private var interval = 120.0
    @State private var autoStart = true
    @State private var saved = false

    var body: some View {
        Form {
            Section("Time Capsule") {
                TextField("IP Address", text: $host, prompt: Text("192.168.1.x"))
                SecureField("Password", text: $password, prompt: Text("AirPort admin password"))
                    .help("Stored in your macOS Keychain")
            }

            Section("Monitoring") {
                Slider(value: $interval, in: 30...600, step: 30) {
                    Text("Check every \(Int(interval))s")
                }
                Toggle("Auto-start Samba when Time Capsule comes online", isOn: $autoStart)
            }

            Section {
                HStack {
                    Spacer()
                    if saved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .transition(.opacity)
                    }
                    Button("Save") {
                        save()
                    }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 280)
        .onAppear {
            host = monitor.settings.host
            interval = monitor.settings.checkInterval
            autoStart = monitor.settings.autoStart
        }
    }

    private func save() {
        monitor.updateHost(host)
        monitor.settings.checkInterval = interval
        monitor.settings.autoStart = autoStart
        monitor.settings.save()

        if !password.isEmpty {
            monitor.savePassword(password)
            password = ""
        }

        monitor.startMonitoring()

        withAnimation {
            saved = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { saved = false }
        }
    }
}
