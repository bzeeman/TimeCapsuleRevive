import Foundation

struct TimeCapsuleDevice: Identifiable, Codable, Equatable {
    var id: String { host }
    var host: String
    var name: String
    var isOnline: Bool = false
    var isSambaRunning: Bool = false
    var lastChecked: Date?
}

struct SMBShare: Identifiable, Codable {
    var id: String { name }
    var name: String
    var path: String
    var isTimeMachine: Bool
}

struct AppSettings: Codable {
    var host: String = ""
    var checkInterval: TimeInterval = 120
    var autoStart: Bool = false

    private static let key = "TimeCapsuleReviveSettings"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: AppSettings.key)
        }
    }
}
