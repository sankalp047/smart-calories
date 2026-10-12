import Foundation
import HealthKit
import WatchConnectivity

/// Streams live heart rate from the Watch's own sensor to the iPhone.
///
/// A workout session is the only sanctioned way to keep the heart-rate sensor
/// sampling at ~1 Hz with the app alive in the background — outside one,
/// watchOS reads the heart every few minutes and suspends third-party apps.
/// Each sample goes to the phone as a fire-and-forget message; the phone
/// feeds it into the same pipeline the WHOOP broadcast uses.
///
/// The workout is *discarded* on stop, deliberately: this session exists to
/// power the stream, and saving it would double-count against real workouts
/// the user logs elsewhere.
final class WatchWorkoutStreamer: NSObject, ObservableObject {

    @Published private(set) var bpm: Int?
    @Published private(set) var isStreaming = false
    @Published private(set) var errorMessage: String?

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?

    func start() {
        errorMessage = nil
        Task { @MainActor in
            do {
                try await store.requestAuthorization(
                    toShare: [HKObjectType.workoutType()],
                    read: [HKQuantityType(.heartRate)]
                )
                let config = HKWorkoutConfiguration()
                config.activityType = .other
                config.locationType = .indoor

                let session = try HKWorkoutSession(healthStore: store, configuration: config)
                let builder = session.associatedWorkoutBuilder()
                builder.dataSource = HKLiveWorkoutDataSource(
                    healthStore: store, workoutConfiguration: config)
                session.delegate = self
                builder.delegate = self

                self.session = session
                self.builder = builder

                session.startActivity(with: Date())
                try await builder.beginCollection(at: Date())
                isStreaming = true
            } catch {
                errorMessage = error.localizedDescription
                isStreaming = false
            }
        }
    }

    func stop() {
        session?.end()
        Task { @MainActor in
            try? await builder?.endCollection(at: Date())
            builder?.discardWorkout()
            session = nil
            builder = nil
            isStreaming = false
            bpm = nil
        }
    }

    private func send(bpm: Int) {
        // Live stream: a dropped message costs one second of data, so
        // fire-and-forget is right — no queue that would arrive late.
        guard WCSession.default.isReachable else { return }
        WCSession.default.sendMessage(
            [WatchSyncKey.heartSample: [Int(Date().timeIntervalSince1970), bpm]],
            replyHandler: nil
        )
    }
}

extension WatchWorkoutStreamer: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession,
        didChangeTo toState: HKWorkoutSessionState,
        from fromState: HKWorkoutSessionState, date: Date
    ) {
        Task { @MainActor in
            if toState == .ended { isStreaming = false }
        }
    }

    nonisolated func workoutSession(
        _ workoutSession: HKWorkoutSession, didFailWithError error: Error
    ) {
        Task { @MainActor in
            errorMessage = error.localizedDescription
            isStreaming = false
        }
    }
}

extension WatchWorkoutStreamer: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilder(
        _ workoutBuilder: HKLiveWorkoutBuilder,
        didCollectDataOf collectedTypes: Set<HKSampleType>
    ) {
        let heartRate = HKQuantityType(.heartRate)
        guard collectedTypes.contains(heartRate),
              let stats = workoutBuilder.statistics(for: heartRate),
              let quantity = stats.mostRecentQuantity()
        else { return }
        let bpm = Int(quantity.doubleValue(
            for: HKUnit.count().unitDivided(by: .minute())).rounded())
        guard bpm > 20, bpm < 250 else { return }
        Task { @MainActor in
            self.bpm = bpm
            self.send(bpm: bpm)
        }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}
}
