import Foundation
import WatchConnectivity

/// Holds the latest snapshot from the phone and forwards user actions back.
///
/// Uses `updateApplicationContext` for state (the system keeps only the newest
/// payload, which is exactly right for "today's totals") and `sendMessage`
/// with a transferUserInfo fallback for actions, so a tap still lands if the
/// phone isn't reachable at that instant.
final class WatchModel: NSObject, ObservableObject, WCSessionDelegate {

    @Published private(set) var snapshot = WatchSnapshot()
    @Published private(set) var lastActionFeedback: String?

    private var session: WCSession { .default }

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        // Show whatever the phone last pushed, even before activation completes.
        applyContext(session.receivedApplicationContext)
    }

    // MARK: - Sending

    func send(_ action: WatchAction) {
        guard let data = try? JSONEncoder().encode(action) else { return }
        let payload = [WatchSyncKey.action: data]

        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { [weak self] _ in
                // Reachability can drop mid-send; queue it instead of losing it.
                self?.session.transferUserInfo(payload)
            }
        } else {
            session.transferUserInfo(payload)
        }

        switch action {
        case .logWater(let ml): feedback("Logged \(Int(ml)) ml")
        case .logFavorite: feedback("Logged")
        }
    }

    private func feedback(_ text: String) {
        lastActionFeedback = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.lastActionFeedback = nil
        }
    }

    // MARK: - Receiving

    private func applyContext(_ context: [String: Any]) {
        guard let data = context[WatchSyncKey.snapshot] as? Data,
              let decoded = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return }
        DispatchQueue.main.async { self.snapshot = decoded }
    }

    func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState,
                 error: Error?) {
        applyContext(session.receivedApplicationContext)
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        applyContext(context)
    }
}
