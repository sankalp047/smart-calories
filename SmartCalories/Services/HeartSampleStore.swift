import Foundation

/// Durable archive of the raw per-second heart-rate stream.
///
/// Layout: one append-only CSV per day (`HeartSamples/2026-08-13.csv`, lines
/// of `unixSeconds,bpm`) plus a cursor file recording the last timestamp
/// confirmed by the server. Appends are buffered (~10 s) so a workout doesn't
/// hammer the disk, and a crash costs at most the buffer.
///
/// Append-only files were chosen over SQLite deliberately: the write path is
/// a single `FileHandle.write`, corruption can't spread past one line, and
/// the format is trivially exportable. The pure parsing/selection logic lives
/// in static functions so Tests/run.sh can verify it without a filesystem.
final class HeartSampleStore {

    static let batchLimit = 5000

    private let directory: URL
    private let cursorURL: URL
    private var buffer: [(ts: Int, bpm: Int)] = []
    private var lastFlush = Date()

    /// Last timestamp the server has confirmed. Everything ≤ this is shipped.
    private(set) var shippedThrough: Int

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        directory = base.appendingPathComponent("SmartCalories/HeartSamples", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cursorURL = directory.appendingPathComponent("shipped_cursor")
        shippedThrough = (try? String(contentsOf: cursorURL, encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    // MARK: - Writing

    func append(bpm: Int, at date: Date = Date()) {
        buffer.append((ts: Int(date.timeIntervalSince1970), bpm: bpm))
        if buffer.count >= 30 || Date().timeIntervalSince(lastFlush) > 10 {
            flush()
        }
    }

    /// Write the buffer out. Called on the cadence above and by the service
    /// on disconnect/background so nothing lingers in memory.
    func flush() {
        guard !buffer.isEmpty else { return }
        defer { buffer = []; lastFlush = Date() }

        // A buffer can straddle midnight; group by day file.
        let grouped = Dictionary(grouping: buffer) { Self.dayName(forTs: $0.ts) }
        for (day, samples) in grouped {
            let url = directory.appendingPathComponent("\(day).csv")
            let data = Data(samples.map { "\($0.ts),\($0.bpm)\n" }.joined().utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// Merge samples restored from the server into the local archive.
    ///
    /// De-duplicates against what is already on disk, because a restore can
    /// overlap data this device recorded itself. The shipping cursor is then
    /// advanced past everything imported — these samples came *from* the
    /// server, so re-uploading them would be pure waste.
    @discardableResult
    func importRestored(_ samples: [(ts: Int, bpm: Int)]) -> Int {
        guard !samples.isEmpty else { return 0 }
        flush()

        let grouped = Dictionary(grouping: samples) { Self.dayName(forTs: $0.ts) }
        var imported = 0
        for (day, daySamples) in grouped {
            let url = directory.appendingPathComponent("\(day).csv")
            let existing = (try? String(contentsOf: url, encoding: .utf8))
                .map { Set(Self.select(fromCSV: $0, afterTs: 0, limit: .max).map(\.ts)) } ?? []
            let fresh = daySamples.filter { !existing.contains($0.ts) }.sorted { $0.ts < $1.ts }
            guard !fresh.isEmpty else { continue }
            let data = Data(fresh.map { "\($0.ts),\($0.bpm)\n" }.joined().utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
            imported += fresh.count
        }
        if let newest = samples.map(\.ts).max() {
            markShipped(through: newest)
        }
        return imported
    }

    // MARK: - Shipping

    /// Next unshipped batch, oldest first. Empty when caught up.
    func nextBatch(limit: Int = HeartSampleStore.batchLimit) -> [(ts: Int, bpm: Int)] {
        flush()
        var batch: [(ts: Int, bpm: Int)] = []
        for url in dayFiles() {
            guard batch.count < limit else { break }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            batch.append(contentsOf: Self.select(
                fromCSV: content, afterTs: shippedThrough, limit: limit - batch.count))
        }
        return batch
    }

    /// Advance the cursor after the server confirmed a batch.
    func markShipped(through ts: Int) {
        shippedThrough = max(shippedThrough, ts)
        try? "\(shippedThrough)".write(to: cursorURL, atomically: true, encoding: .utf8)
        prune()
    }

    /// Stored-today count and pending count, for the transparency line in
    /// the WHOOP screen.
    func status() -> (today: Int, pending: Int) {
        flush()
        let todayURL = directory.appendingPathComponent("\(Self.dayName(forTs: Int(Date().timeIntervalSince1970))).csv")
        let today = (try? String(contentsOf: todayURL, encoding: .utf8))
            .map { $0.split(whereSeparator: \.isNewline).count } ?? 0
        let pending = dayFiles().reduce(0) { total, url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return total }
            return total + Self.select(fromCSV: content, afterTs: shippedThrough, limit: .max).count
        }
        return (today, pending)
    }

    // MARK: - Reading for charts

    /// All samples in a time range, oldest first — spans day-file boundaries.
    /// Called off the main actor; a concurrent append can at worst leave a
    /// torn final line, which the parser skips.
    func samples(from: Date, to: Date) -> [(ts: Int, bpm: Int)] {
        let fromTs = Int(from.timeIntervalSince1970)
        let toTs = Int(to.timeIntervalSince1970)
        var out: [(ts: Int, bpm: Int)] = []
        for url in dayFiles() {
            let day = url.deletingPathExtension().lastPathComponent
            // Skip files entirely outside the range (day granularity).
            guard day >= Self.dayName(forTs: fromTs), day <= Self.dayName(forTs: toTs) else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            out.append(contentsOf: Self.select(fromCSV: content, afterTs: fromTs - 1, limit: .max)
                .filter { $0.ts <= toTs })
        }
        return out
    }

    /// One chart point per time bucket. Downsampling is what makes a day of
    /// per-second data drawable, and keeping min/max alongside the mean means
    /// the chart can show the honest envelope, not a smoothed fiction.
    struct Bucket: Identifiable {
        var id: Int { ts }
        let ts: Int
        let minBpm: Int
        let avgBpm: Double
        let maxBpm: Int
        var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    }

    /// Bucket width that keeps any window at ~180 chart points — 1 s buckets
    /// for a 1-minute window up to 20 s for a full hour.
    static func adaptiveBucketSeconds(windowSeconds: Int) -> Int {
        max(1, windowSeconds / 180)
    }

    /// The unflushed tail of the stream, so a live chart can include the
    /// last few seconds that haven't hit disk yet. Main-actor callers only.
    func bufferSnapshot() -> [(ts: Int, bpm: Int)] {
        buffer
    }

    static func bucketed(_ samples: [(ts: Int, bpm: Int)], bucketSeconds: Int) -> [Bucket] {
        guard bucketSeconds > 0, !samples.isEmpty else { return [] }
        var buckets: [Int: (min: Int, sum: Int, max: Int, count: Int)] = [:]
        for sample in samples {
            let key = sample.ts / bucketSeconds * bucketSeconds
            if var b = buckets[key] {
                b.min = Swift.min(b.min, sample.bpm)
                b.max = Swift.max(b.max, sample.bpm)
                b.sum += sample.bpm
                b.count += 1
                buckets[key] = b
            } else {
                buckets[key] = (sample.bpm, sample.bpm, sample.bpm, 1)
            }
        }
        return buckets.keys.sorted().map { key in
            let b = buckets[key]!
            return Bucket(ts: key, minBpm: b.min,
                          avgBpm: Double(b.sum) / Double(b.count), maxBpm: b.max)
        }
    }

    // MARK: - Pure logic (tested standalone)

    /// Parse a CSV blob and pick samples newer than the cursor, in order.
    /// Malformed lines are skipped, never fatal — a torn write at crash time
    /// must not poison the whole file.
    static func select(fromCSV content: String, afterTs: Int, limit: Int) -> [(ts: Int, bpm: Int)] {
        var out: [(ts: Int, bpm: Int)] = []
        for line in content.split(whereSeparator: \.isNewline) {
            guard out.count < limit else { break }
            let parts = line.split(separator: ",")
            guard parts.count == 2,
                  let ts = Int(parts[0]), let bpm = Int(parts[1]),
                  ts > afterTs, bpm > 20, bpm < 250
            else { continue }
            out.append((ts: ts, bpm: bpm))
        }
        return out
    }

    /// UTC day bucket for a timestamp — files are named by it.
    static func dayName(forTs ts: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: - Housekeeping

    /// Day files, oldest first, so shipping drains chronologically.
    private func dayFiles() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "csv" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Delete files that are fully shipped and older than 30 days — the
    /// server owns the long history; the phone keeps a rolling month.
    private func prune() {
        let cutoffDay = Self.dayName(forTs: shippedThrough - 30 * 86_400)
        for url in dayFiles() where url.deletingPathExtension().lastPathComponent < cutoffDay {
            let name = url.deletingPathExtension().lastPathComponent
            // Only remove when every sample in it is behind the cursor.
            if name < Self.dayName(forTs: shippedThrough) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
