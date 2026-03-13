import Foundation
import Network
import SwiftUI

@MainActor
@Observable
final class TimeCapsuleMonitor {
    var device: TimeCapsuleDevice
    var shares: [SMBShare] = []
    var lastEvent: String = ""
    var isChecking = false
    var settings: AppSettings

    private var monitorTask: Task<Void, Never>?
    private let ssh = SSHService()

    init() {
        self.settings = AppSettings.load()
        self.device = TimeCapsuleDevice(host: settings.host, name: "Time Capsule")
    }

    // MARK: - Monitoring

    func startMonitoring() {
        stopMonitoring()
        guard !settings.host.isEmpty else { return }
        device.host = settings.host

        monitorTask = Task {
            while !Task.isCancelled {
                await checkStatus()
                try? await Task.sleep(for: .seconds(settings.checkInterval))
            }
        }
        log("Monitoring started")
    }

    func stopMonitoring() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    func checkStatus() async {
        guard !settings.host.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }

        let host = settings.host

        // Check if port 445 is open (SMBv3 running)
        let sambaUp = await checkPort(host: host, port: 445, timeout: 5)
        let sshUp = await checkPort(host: host, port: 22, timeout: 5)

        device.isOnline = sshUp || sambaUp
        device.isSambaRunning = sambaUp
        device.lastChecked = Date()

        if device.isOnline && !device.isSambaRunning && settings.autoStart {
            log("TC online but Samba down — starting...")
            await startSamba()
        } else if device.isSambaRunning {
            log("SMBv3 active")
        } else if !device.isOnline {
            log("Time Capsule offline")
        }
    }

    // MARK: - Actions

    func startSamba() async {
        do {
            let output = try await ssh.runCommand(
                host: settings.host,
                command: "/Volumes/dk2/samba/rc_samba.sh"
            )
            log("Samba started")
            // Recheck status
            try? await Task.sleep(for: .seconds(3))
            await checkStatus()
        } catch {
            log("Start failed: \(error.localizedDescription)")
        }
    }

    func stopSamba() async {
        do {
            _ = try await ssh.runCommand(
                host: settings.host,
                command: "for pid in $(/bin/ps ax 2>/dev/null "
                    + "| awk '/\\/smbd/ && !/awk/ {print $1}'); "
                    + "do kill $pid 2>/dev/null; done"
            )
            log("Samba stopped")
            device.isSambaRunning = false
        } catch {
            log("Stop failed: \(error.localizedDescription)")
        }
    }

    func refreshShares() async {
        do {
            let output = try await ssh.runCommand(
                host: settings.host,
                command: "cat /Volumes/dk2/samba/etc/smb.conf"
            )
            shares = parseShares(from: output)
        } catch {
            log("Failed to read shares: \(error.localizedDescription)")
        }
    }

    func listVolumes() async -> [String] {
        do {
            let output = try await ssh.runCommand(
                host: settings.host,
                command: "df"
            )
            return output.components(separatedBy: "\n")
                .dropFirst()
                .compactMap { line in
                    let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                    guard parts.count >= 6,
                          parts[5].hasPrefix("/Volumes/")
                    else { return nil }
                    return "\(parts[5]) (\(parts[4]) used)"
                }
        } catch {
            return []
        }
    }

    // MARK: - Settings

    func updateHost(_ host: String) {
        settings.host = host
        settings.save()
        device.host = host
        startMonitoring()
    }

    func savePassword(_ password: String) {
        try? KeychainService.savePassword(password, forHost: settings.host)
        log("Password saved to Keychain")
    }

    // MARK: - Private

    private func checkPort(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { cont in
            let queue = DispatchQueue(label: "portcheck")
            let connection = NWConnection(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(rawValue: port)!,
                using: .tcp
            )

            var resolved = false
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                guard !resolved else { return }
                resolved = true
                connection.cancel()
                cont.resume(returning: false)
            }
            timer.resume()

            connection.stateUpdateHandler = { state in
                guard !resolved else { return }
                switch state {
                case .ready:
                    resolved = true
                    timer.cancel()
                    connection.cancel()
                    cont.resume(returning: true)
                case .failed, .cancelled:
                    resolved = true
                    timer.cancel()
                    cont.resume(returning: false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private func parseShares(from conf: String) -> [SMBShare] {
        var result: [SMBShare] = []
        var current: (name: String, path: String, tm: Bool)?

        for line in conf.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let match = trimmed.range(of: #"^\[(.+)\]$"#, options: .regularExpression) {
                if let c = current, c.name.lowercased() != "global" {
                    result.append(SMBShare(name: c.name, path: c.path, isTimeMachine: c.tm))
                }
                let name = String(trimmed[trimmed.index(after: trimmed.startIndex)..<trimmed.index(before: trimmed.endIndex)])
                current = (name: name, path: "", tm: false)
            } else if let c = current, trimmed.contains("=") {
                let parts = trimmed.split(separator: "=", maxSplits: 1)
                let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let val = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if key == "path" { current?.path = val }
                if key == "fruit:time machine" && val.lowercased() == "yes" { current?.tm = true }
            }
        }

        if let c = current, c.name.lowercased() != "global" {
            result.append(SMBShare(name: c.name, path: c.path, isTimeMachine: c.tm))
        }
        return result
    }

    private func log(_ message: String) {
        lastEvent = message
    }
}
