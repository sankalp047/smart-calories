import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared contract for the live-weighing Activity.
///
/// This file is deliberately compiled into **both** the app and the widget
/// extension: the app starts and updates the Activity, the widget renders it,
/// and ActivityKit matches them by this type. It lives outside either target's
/// synchronized folder and is added to both Sources phases explicitly, which is
/// far less invasive than promoting the whole model layer into a framework.
///
/// Keep it dependency-free — anything imported here has to exist in both
/// targets too.
#if canImport(ActivityKit)
struct ScaleActivityAttributes: ActivityAttributes {

    /// The parts that change while the Activity is live.
    struct ContentState: Codable, Hashable {
        var grams: Double
        var calories: Double
        var isStable: Bool

        var displayWeight: String { "\(Int(grams.rounded())) g" }
        var displayCalories: String { "\(Int(calories.rounded())) kcal" }
    }

    /// Fixed for the lifetime of the Activity.
    var foodName: String
    var kcalPer100g: Double
}
#endif
