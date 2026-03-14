import SwiftUI

struct SettingsView: View {
    @Environment(TimeCapsuleMonitor.self) var monitor

    @State private var host = ""
    @State private var password = ""
    @State private var interval = 120.0
    @State private var autoStart = true
    @State private var saved = false
    @State private var manualEntry = false

    var body: some View {
        Form {
            Section("Time Capsule") {
                if manualEntry {
                    TextField("IP Address", text: $host, prompt: Text("192.168.1.x"))
                    Button("Scan Network Instead") {
                        manualEntry = false
                        monitor.scanForDevices()
                    }
                } else {
                    if monitor.isScanning {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Scanning network...")
                                .foregroundStyle(.secondary)
                        }
                    }

                    if !monitor.discoveredDevices.isEmpty {
                        Picker("Device", selection: $host) {
                            Text("Select a device…")
                                .tag("")
                            ForEach(monitor.discoveredDevices) { device in
                                Text("\(device.name) (\(device.host))")
                                    .tag(device.host)
                            }
                        }
                    } else if !monitor.isScanning {
                        Text("No devices found")
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        Button("Rescan") {
                            monitor.scanForDevices()
                        }
                        .disabled(monitor.isScanning)

                        Button("Enter Manually") {
                            manualEntry = true
                        }
                    }
                }

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
                    .disabled(host.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 320)
        .onAppear {
            host = monitor.settings.host
            interval = monitor.settings.checkInterval
            autoStart = monitor.settings.autoStart
            manualEntry = !host.isEmpty
            if host.isEmpty {
                monitor.scanForDevices()
            }
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
