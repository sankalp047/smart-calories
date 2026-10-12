import Foundation

/// One set actually performed — the unit of truth for training progress.
struct SetLog: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var exercise: String
    var reps: Int
    var weightKg: Double
    var date: Date = Date()

    /// Estimated one-rep max via the Epley formula.
    ///
    /// Comparing raw weight across sets is misleading — 100 kg × 3 is a better
    /// effort than 90 kg × 8, but 60 kg × 20 isn't better than either despite
    /// the volume. Normalising to an estimated 1RM lets sets of different
    /// rep ranges be compared on one scale, which is what progression needs.
    /// Accuracy degrades above ~12 reps, so those are excluded from PRs.
    var estimatedOneRepMax: Double {
        guard reps > 0, weightKg > 0 else { return 0 }
        if reps == 1 { return weightKg }
        return weightKg * (1 + Double(reps) / 30.0)
    }

    /// Whether this set is a reasonable basis for a strength PR.
    var countsForPR: Bool { (1...12).contains(reps) && weightKg > 0 }

    var volume: Double { Double(reps) * weightKg }
}

/// A training session: one day of a plan, as actually performed.
struct WorkoutSession: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var planName: String
    var dayTitle: String
    var startedAt: Date = Date()
    var finishedAt: Date?
    var sets: [SetLog] = []
    /// Present only when a heart-rate monitor was connected for the session.
    /// Optional so sessions logged before this existed still decode.
    var heart: SessionHeartStats?

    var isFinished: Bool { finishedAt != nil }
    var totalVolume: Double { sets.reduce(0) { $0 + $1.volume } }
    var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    var exercisesPerformed: [String] {
        var seen = Set<String>()
        return sets.compactMap { seen.insert($0.exercise).inserted ? $0.exercise : nil }
    }

    func sets(for exercise: String) -> [SetLog] {
        sets.filter { $0.exercise == exercise }
    }
}

/// Personal-best tracking and progression advice derived from logged sets.
struct StrengthHistory {
    let sessions: [WorkoutSession]

    private var allSets: [SetLog] {
        sessions.flatMap(\.sets)
    }

    /// Best estimated 1RM ever recorded for an exercise.
    func personalBest(for exercise: String) -> SetLog? {
        allSets
            .filter { $0.exercise == exercise && $0.countsForPR }
            .max { $0.estimatedOneRepMax < $1.estimatedOneRepMax }
    }

    /// The most recent working sets for an exercise, newest session first.
    func lastPerformance(of exercise: String) -> [SetLog] {
        for session in sessions.sorted(by: { $0.startedAt > $1.startedAt }) {
            let matching = session.sets(for: exercise)
            if !matching.isEmpty { return matching }
        }
        return []
    }

    /// Is this set a new personal best?
    func isPersonalBest(_ set: SetLog) -> Bool {
        guard set.countsForPR else { return false }
        guard let best = personalBest(for: set.exercise) else { return true }
        // Compare against everything logged *before* this set.
        guard best.id != set.id else {
            let others = allSets.filter { $0.exercise == set.exercise && $0.id != set.id && $0.countsForPR }
            let previousBest = others.map(\.estimatedOneRepMax).max() ?? 0
            return set.estimatedOneRepMax > previousBest
        }
        return set.estimatedOneRepMax > best.estimatedOneRepMax
    }

    /// What to attempt next, based on what was actually achieved last time.
    ///
    /// The rule is deliberately conservative — the classic double-progression
    /// approach: add reps within the target range first, and only add load once
    /// the top of the range is reached. Chasing weight before reps is how people
    /// stall and get hurt.
    func suggestion(for exercise: String, targetReps: String) -> String? {
        let last = lastPerformance(of: exercise)
        guard let heaviest = last.max(by: { $0.weightKg < $1.weightKg }) else { return nil }

        let upperTarget = Self.upperBound(of: targetReps)
        let weightText = Self.formatWeight(heaviest.weightKg)

        if let upperTarget, heaviest.reps >= upperTarget {
            let next = Self.formatWeight(heaviest.weightKg + Self.increment(for: heaviest.weightKg))
            return "Last time: \(weightText) × \(heaviest.reps). Hit the top of the range — try \(next)."
        }
        return "Last time: \(weightText) × \(heaviest.reps). Aim for one more rep."
    }

    /// Smallest sensible jump: bigger lifts tolerate bigger increments.
    private static func increment(for weightKg: Double) -> Double {
        weightKg >= 60 ? 2.5 : 1.25
    }

    /// Pull the top of a rep prescription like "8–12", "6-10" or "5".
    static func upperBound(of reps: String) -> Int? {
        let numbers = reps
            .components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap(Int.init)
        return numbers.max()
    }

    static func formatWeight(_ kg: Double) -> String {
        kg == kg.rounded()
            ? "\(Int(kg)) kg"
            : String(format: "%.1f kg", kg)
    }
}
