import Foundation
import WatchConnectivity

/// The phone half of the Watch sync.
///
/// The phone is the single writer of the diary — the Watch only ever *asks* for
/// something to be logged. That deliberately avoids two devices independently
/// mutating the same data and having to merge it later.
@MainActor
final class PhoneConnectivity: NSObject, WCSessionDelegate {

    /// Applies an action that arrived from the Watch.
    var onAction: ((WatchAction) -> Void)?

    /// A live heart-rate sample from the Watch's workout session.
    var onHeartSample: ((_ bpm: Int, _ at: Date) -> Void)?

    private var session: WCSession { .default }
    private var isActivated = false

    func activate() {
        guard WCSession.isSupported(), !isActivated else { return }
        isActivated = true
        session.delegate = self
        session.activate()
    }

    /// Push the latest state. `updateApplicationContext` keeps only the newest
    /// payload, which is exactly the semantics we want for "today's totals" —
    /// no queue to drain, no stale updates arriving out of order.
    func push(_ snapshot: WatchSnapshot) {
        guard WCSession.isSupported(), session.activationState == .activated else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? session.updateApplicationContext([WatchSyncKey.snapshot: data])
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Required on iOS: re-activate so a switched watch keeps working.
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        handle(userInfo)
    }

    private nonisolated func handle(_ payload: [String: Any]) {
        // Live HR sample: [unixSeconds, bpm]. Checked first — during a
        // streaming session this is the hot path, one message per second.
        if let sample = payload[WatchSyncKey.heartSample] as? [Int],
           sample.count == 2, sample[1] > 20, sample[1] < 250 {
            let date = Date(timeIntervalSince1970: TimeInterval(sample[0]))
            let bpm = sample[1]
            Task { @MainActor in self.onHeartSample?(bpm, date) }
            return
        }
        guard let data = payload[WatchSyncKey.action] as? Data,
              let action = try? JSONDecoder().decode(WatchAction.self, from: data)
        else { return }
        Task { @MainActor in self.onAction?(action) }
    }
}
