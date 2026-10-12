import Foundation

/// The contract between the iPhone app and the Watch app.
///
/// App Groups do **not** span devices — the Watch is a separate machine with
/// its own container — so the phone pushes a small snapshot over
/// WatchConnectivity and the Watch sends back the actions the user takes.
/// Keeping that payload tiny and Codable is what makes the sync reliable.
///
/// Compiled into both the iOS and watchOS targets.
struct WatchSnapshot: Codable, Equatable {
    var eaten: Double = 0
    var goal: Double = 2000
    var burned: Double = 0
    var protein: Double = 0
    var proteinTarget: Double = 0
    var waterMl: Double = 0
    var waterTarget: Double = 2500
    var streak: Int = 0
    /// Name + grams + calories of the user's quick-add favourites.
    var favorites: [WatchFavorite] = []
    var updatedAt: Date = Date()

    var remaining: Double { goal - eaten }
    var progress: Double { goal > 0 ? min(eaten / goal, 1) : 0 }

    /// Small enough to travel as an application context payload.
    static let maxFavorites = 6
}

struct WatchFavorite: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var grams: Double
    var calories: Double
}

/// Actions the Watch can ask the phone to perform. The phone stays the single
/// writer of the diary, which avoids two devices merging conflicting state.
enum WatchAction: Codable, Equatable {
    case logWater(ml: Double)
    case logFavorite(id: String)
}

enum WatchSyncKey {
    static let snapshot = "snapshot"
    static let action = "action"
    /// Live heart-rate sample from the Watch's workout session:
    /// value is `[unixSeconds, bpm]` as Ints. Sent fire-and-forget — a live
    /// stream re-sends every second, so a dropped sample costs nothing.
    static let heartSample = "hr"
}
