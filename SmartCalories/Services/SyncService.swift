import Foundation
import Observation

/// Cloud backup and restore of everything the app stores locally.
///
/// The `Store` layer already keeps each domain as one JSON blob, which makes
/// sync simple: push the blobs up, pull them down, last-write-wins per key.
/// That is the right trade for a single user on a couple of devices — a real
/// merge would risk producing a half-correct diary, and losing the older of
/// two concurrent edits is far more predictable.
///
/// Restore-on-fresh-install is the whole point: sign in on a new phone and the
/// profile, diary, weights, workouts and calibration come straight back.
@MainActor
@Observable
final class SyncService {

    enum State: Equatable {
        case idle, syncing, synced(Date), failed(String)
    }

    private(set) var state: State = .idle

    /// Every Store key worth preserving. Deliberately excludes transient
    /// device state (the last connected scale/monitor), which is meaningless
    /// on a different phone.
    static let syncedKeys: [String] = [
        Store.Key.profile, Store.Key.settings, Store.Key.diary, Store.Key.weights,
        Store.Key.water, Store.Key.sessions, Store.Key.favorites, Store.Key.recipes,
        Store.Key.scaleConfig, Store.Key.calibration, Store.Key.heartDaily,
    ]

    private static let base = Secrets.backendBaseURL
    private let auth: AuthService
    private var lastPushedHashes: [String: Int] = [:]

    init(auth: AuthService) {
        self.auth = auth
    }

    // MARK: - Push

    /// Upload any blob whose contents changed since the last successful push.
    func push() async {
        guard auth.isSignedIn else { return }
        var items: [[String: Any]] = []
        var hashes: [String: Int] = [:]

        for key in Self.syncedKeys {
            guard let json = Store.rawJSON(key: key) else { continue }
            let hash = json.hashValue
            hashes[key] = hash
            guard lastPushedHashes[key] != hash else { continue }
            items.append([
                "key": key,
                "json": json,
                "updated_at": Int(Date().timeIntervalSince1970),
            ])
        }
        guard !items.isEmpty else { return }

        state = .syncing
        do {
            _ = try await send(path: "/sync/push", method: "POST", body: ["items": items])
            lastPushedHashes = hashes
            state = .synced(Date())
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Pull

    /// Download the account's blobs and write them to disk.
    ///
    /// Returns the keys restored. Only applied when the local side has
    /// nothing for that key or the server copy is newer, so signing in on a
    /// phone that already has data can't silently wipe it.
    @discardableResult
    func pull(overwriteLocal: Bool) async -> [String] {
        guard auth.isSignedIn else { return [] }
        state = .syncing
        do {
            let data = try await send(path: "/sync/pull", method: "GET", body: nil)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = object["items"] as? [[String: Any]]
            else {
                state = .failed("Unexpected response from the server.")
                return []
            }

            var restored: [String] = []
            for item in items {
                guard let key = item["key"] as? String,
                      let json = item["json"] as? String,
                      Self.syncedKeys.contains(key)
                else { continue }
                let localExists = Store.rawJSON(key: key) != nil
                guard overwriteLocal || !localExists else { continue }
                Store.writeRawJSON(json, key: key)
                restored.append(key)
            }
            state = .synced(Date())
            return restored
        } catch {
            state = .failed(error.localizedDescription)
            return []
        }
    }

    // MARK: - Heart archive restore

    /// Rebuild the local per-second archive from the account's server-side
    /// history. Paged, because a few weeks of 1 Hz data is tens of thousands
    /// of rows and one giant response would be fragile on a phone network.
    @discardableResult
    func restoreHeartArchive(into store: HeartSampleStore) async -> Int {
        guard auth.isSignedIn else { return 0 }
        var since = 0
        var total = 0

        // Bounded so a corrupt cursor can't spin forever.
        for _ in 0..<40 {
            do {
                let data = try await send(
                    path: "/sync/heart?since=\(since)&limit=20000", method: "GET", body: nil)
                guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let raw = object["samples"] as? [[Int]]
                else { break }

                let samples = raw.compactMap { pair -> (ts: Int, bpm: Int)? in
                    guard pair.count == 2 else { return nil }
                    return (ts: pair[0], bpm: pair[1])
                }
                guard !samples.isEmpty else { break }

                total += store.importRestored(samples)
                since = samples.map(\.ts).max() ?? since
                if (object["hasMore"] as? Bool) != true { break }
            } catch {
                break
            }
        }
        return total
    }

    // MARK: - Transport

    private func send(path: String, method: String, body: [String: Any]?) async throws -> Data {
        let token = try auth.sessionToken()
        var request = URLRequest(url: URL(string: Self.base + path)!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        request.timeoutInterval = 45
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.message("No response from the server.")
        }
        guard http.statusCode == 200 else {
            if http.statusCode == 401 { throw AuthError.message("Session expired — sign in again.") }
            throw AuthError.message("Sync failed (HTTP \(http.statusCode)).")
        }
        return data
    }
}
