import Foundation

/// Ships buffered heart-rate samples to the Cloudflare Worker's D1 archive.
///
/// Runs a slow loop (5 min) while the app is alive, plus a kick on
/// foregrounding. Batches are capped, the server dedupes on (device, ts), and
/// the cursor only advances after a 200 — so a lost response just means the
/// same batch goes again harmlessly. If the phone is offline the samples
/// simply wait on disk; nothing is dropped.
@MainActor
final class HeartSampleShipper {

    private static let ingestURL = URL(
        string: Secrets.backendBaseURL + "/hr/ingest")!

    private let store: HeartSampleStore
    private var loop: Task<Void, Never>?
    private var inFlight = false

    /// Last successful ship, for the transparency line.
    private(set) var lastShippedAt: Date?

    init(store: HeartSampleStore) {
        self.store = store
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.shipPending()
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// One shipping pass; drains multiple batches if a backlog built up.
    func shipPending() async {
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        // Drain at most 10 batches per pass (50k samples) so a huge backlog
        // can't monopolise a foreground moment; the loop gets the rest.
        for _ in 0..<10 {
            let batch = store.nextBatch()
            guard !batch.isEmpty else { return }
            guard await ship(batch) else { return }   // offline/error: retry later
            store.markShipped(through: batch.last!.ts)
            lastShippedAt = Date()
        }
    }

    private func ship(_ batch: [(ts: Int, bpm: Int)]) async -> Bool {
        var request = URLRequest(url: Self.ingestURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        request.timeoutInterval = 30

        let payload = ["samples": batch.map { [$0.ts, $0.bpm] }]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = body

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
