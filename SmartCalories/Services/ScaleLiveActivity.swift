import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Puts the live scale reading on the Lock Screen and in the Dynamic Island.
///
/// This is the one place the hardware integration really shines: while you're
/// cooking, the phone is on the counter and your hands are busy. Weight and
/// calories update on the Lock Screen without touching anything.
@MainActor
enum ScaleLiveActivity {

    #if canImport(ActivityKit)
    private static var activity: Activity<ScaleActivityAttributes>?
    #endif

    static var isSupported: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) {
            return ActivityAuthorizationInfo().areActivitiesEnabled
        }
        #endif
        return false
    }

    static var isRunning: Bool {
        #if canImport(ActivityKit)
        if #available(iOS 16.1, *) { return activity != nil }
        #endif
        return false
    }

    static func start(food: Food, grams: Double) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), isSupported, activity == nil else { return }
        let attributes = ScaleActivityAttributes(
            foodName: food.name, kcalPer100g: food.kcalPer100g)
        let state = ScaleActivityAttributes.ContentState(
            grams: grams, calories: food.calories(forGrams: grams), isStable: false)
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil)
        )
        #endif
    }

    static func update(grams: Double, calories: Double, isStable: Bool) {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let activity else { return }
        let state = ScaleActivityAttributes.ContentState(
            grams: grams, calories: calories, isStable: isStable)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
        #endif
    }

    static func end() {
        #if canImport(ActivityKit)
        guard #available(iOS 16.1, *), let current = activity else { return }
        activity = nil
        Task { await current.end(nil, dismissalPolicy: .immediate) }
        #endif
    }
}
