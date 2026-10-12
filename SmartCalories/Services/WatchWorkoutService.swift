import Foundation
import HealthKit
#if canImport(WorkoutKit)
import WorkoutKit
#endif

/// Sends a plan from this app into the Apple Watch's own Workout app.
///
/// This is what turns a training plan from text on a screen into something you
/// actually do: the workout appears on the wrist, the Watch tracks heart rate
/// and calories through it, and the result lands back in HealthKit — which this
/// app already reads. The loop closes.
///
/// One honest constraint shapes the design. WorkoutKit models workouts as
/// *timed or distance-based intervals*, not as sets and reps of a named lift.
/// So the mapping differs by workout type:
///
///   - **Circuits** map almost perfectly — work and rest intervals are exactly
///     what the framework expresses.
///   - **Strength work** has no native representation. Each exercise becomes an
///     open-ended work step carrying the exercise name (iOS 18+ lets a step
///     display a name), with timed rests between. The Watch tracks the session
///     and shows what's next; the app remains the source of truth for sets and
///     reps.
@MainActor
enum WatchWorkoutService {

    enum SendResult: Equatable {
        case scheduled(String)
        case notAuthorized
        case unsupported
        case failed(String)
    }

    static var isSupported: Bool {
        #if canImport(WorkoutKit)
        if #available(iOS 17.0, *) { return true }
        return false
        #else
        return false
        #endif
    }

    /// Ask once for permission to place workouts on the watch.
    static func requestAuthorization() async -> Bool {
        #if canImport(WorkoutKit)
        guard #available(iOS 17.0, *) else { return false }
        let state = await WorkoutScheduler.shared.requestAuthorization()
        return state == .authorized
        #else
        return false
        #endif
    }

    /// Async because WorkoutKit reads the state off the scheduler actor.
    static func isAuthorized() async -> Bool {
        #if canImport(WorkoutKit)
        guard #available(iOS 17.0, *) else { return false }
        return await WorkoutScheduler.shared.authorizationState == .authorized
        #else
        return false
        #endif
    }

    /// Schedule one day of a plan onto the watch.
    /// - Parameter date: when it should appear. Defaults to today.
    static func send(day: WorkoutDay, from plan: SmartCalories.WorkoutPlan,
                     at date: Date = Date()) async -> SendResult {
        #if canImport(WorkoutKit)
        guard #available(iOS 17.0, *) else { return .unsupported }

        if await WorkoutScheduler.shared.authorizationState != .authorized {
            guard await requestAuthorization() else { return .notAuthorized }
        }

        let custom = buildWorkout(day: day, plan: plan)
        let scheduled = WorkoutKit.WorkoutPlan(.custom(custom))

        var components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: date)
        // Nudge to the next hour so it doesn't land in the past.
        components.minute = 0

        await WorkoutScheduler.shared.schedule(scheduled, at: components)
        return .scheduled(day.title)
        #else
        return .unsupported
        #endif
    }

    #if canImport(WorkoutKit)
    @available(iOS 17.0, *)
    private static func buildWorkout(day: WorkoutDay,
                                     plan: SmartCalories.WorkoutPlan) -> CustomWorkout {
        // Circuits are genuinely interval-shaped; everything else is treated as
        // strength, where the Watch's job is tracking rather than pacing.
        let isCircuit = day.title.lowercased().contains("circuit")
        let activity: HKWorkoutActivityType = isCircuit
            ? .highIntensityIntervalTraining
            : .traditionalStrengthTraining

        let warmup = namedStep("Warm-up", goal: .time(5, .minutes))
        let cooldown = namedStep("Cool-down", goal: .time(5, .minutes))

        var blocks: [IntervalBlock] = []
        for exercise in day.exercises {
            var steps: [IntervalStep] = []

            // The work step carries the exercise name and its prescription, so
            // the wrist shows "Back Squat · 4 × 6–10" rather than "Interval 3".
            let label = "\(exercise.name) · \(exercise.sets)×\(exercise.reps)"
            if isCircuit {
                steps.append(IntervalStep(.work, step: namedStep(label, goal: .time(45, .seconds))))
                steps.append(IntervalStep(.recovery, step: namedStep("Rest", goal: .time(20, .seconds))))
            } else {
                // Open-ended: the lifter sets the pace, the Watch just records.
                steps.append(IntervalStep(.work, step: namedStep(label, goal: .open)))
                steps.append(IntervalStep(.recovery, step: namedStep("Rest", goal: .time(90, .seconds))))
            }

            blocks.append(IntervalBlock(steps: steps, iterations: max(1, exercise.sets)))
        }

        return CustomWorkout(
            activity: activity,
            location: .indoor,
            displayName: "\(plan.name) — \(day.title)",
            warmup: warmup,
            blocks: blocks,
            cooldown: cooldown
        )
    }

    /// `displayName` on a step only exists from iOS 18; degrade quietly on 17.
    @available(iOS 17.0, *)
    private static func namedStep(_ name: String, goal: WorkoutGoal) -> WorkoutStep {
        var step = WorkoutStep(goal: goal)
        if #available(iOS 18.0, *) { step.displayName = name }
        return step
    }
    #endif
}
