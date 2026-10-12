import Foundation

/// Small, dependency-free local store: Codable values persisted as JSON in
/// Application Support, with an in-memory cache. Chosen over a database because
/// the data set is small and this keeps reads synchronous and migration-free.
struct Store {

    private static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("SmartCalories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func url(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, key: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url(key), options: .atomic)
    }

    /// Raw JSON for a key, for the cloud sync layer — it moves blobs
    /// verbatim rather than decoding and re-encoding every model.
    static func rawJSON(key: String) -> String? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func writeRawJSON(_ json: String, key: String) {
        try? Data(json.utf8).write(to: url(key), options: .atomic)
    }

    static func delete(key: String) {
        try? FileManager.default.removeItem(at: url(key))
    }

    enum Key {
        static let profile = "profile"
        static let diary = "diary"
        static let weights = "weights"
        static let water = "water"
        static let sessions = "workout_sessions"
        static let favorites = "favorites"
        static let recipes = "recipes"
        static let scaleConfig = "scale_config"
        static let lastScaleId = "last_scale_id"
        static let settings = "settings"
        static let heartDaily = "heart_daily"
        static let lastHeartDevice = "last_hr_device"
        static let calibration = "calibration"
    }
}

/// User-tunable settings that aren't part of the fitness profile.
struct AppSettings: Codable, Equatable {
    var calorieGoalOverride: Int?
    var autoConnectScale: Bool = true
    var mealRemindersEnabled: Bool = true
    var goalCheckInEnabled: Bool = true
    var breakfastHour: Int = 8
    var breakfastMinute: Int = 30
    var lunchHour: Int = 13
    var lunchMinute: Int = 0
    var dinnerHour: Int = 19
    var dinnerMinute: Int = 30
    var checkInHour: Int = 20
    var checkInMinute: Int = 0
    var hasCompletedOnboarding: Bool = false
    /// Appearance choice. Optional so settings saved before this existed
    /// still decode (a synthesized Codable default doesn't cover a missing
    /// key — nil does); read it as `appearance ?? .system`.
    var appearance: Appearance?
}
