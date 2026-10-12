import Foundation

/// Learns what a person's maintenance calories *actually* are, instead of
/// trusting a population formula.
///
/// Mifflin–St Jeor predicts the average person of your height/weight/age. Real
/// individuals routinely sit 300+ kcal either side of that, and the formula
/// never learns. But energy balance is directly observable: if someone eats
/// 2,400 kcal a day and their weight holds, their true expenditure *is* 2,400 —
/// whatever any equation claims.
///
/// So we solve for it:
///
///     TDEE = mean daily intake − (weight change in kg × 7,700 kcal ⁄ days)
///
/// Two details make this trustworthy rather than noisy:
///
/// 1. **Trend weight, not scale weight.** Day-to-day bodyweight is mostly water,
///    glycogen and gut contents — swings of ±1.5 kg are routine and dwarf real
///    tissue change. We smooth with an exponential moving average and fit a
///    line through the smoothed series, so we measure the signal, not the noise.
///
/// 2. **Confidence weighting.** With three days of data this estimate is
///    garbage. We score how much evidence exists (days logged, span covered,
///    weigh-in count) and blend toward the formula when evidence is thin, so
///    the number degrades gracefully instead of lying confidently.
struct AdaptiveEnergy {

    /// Energy density of body mass. ~7,700 kcal per kg is the standard figure
    /// for mixed fat/lean tissue change.
    static let kcalPerKg: Double = 7700

    /// How far back to look. Long enough to average out water swings, short
    /// enough to track real metabolic change.
    static let windowDays = 28
    /// Below this, don't even try — blend fully to the formula.
    static let minimumDaysLogged = 10

    struct Result {
        /// Best estimate of maintenance calories, already blended with the formula.
        let tdee: Double
        /// Maintenance implied purely by the data, before blending (nil if unusable).
        let observedTDEE: Double?
        /// Formula baseline, for comparison in the UI.
        let formulaTDEE: Double
        /// 0…1 — how much the data drove the final number.
        let confidence: Double
        /// Smoothed weight change per week, in kg. Negative = losing.
        let weeklyChangeKg: Double?
        let daysLogged: Int
        let weighIns: Int

        var isAdaptive: Bool { confidence > 0.15 && observedTDEE != nil }

        var summary: String {
            guard isAdaptive else {
                return "Using the standard formula until there's more data."
            }
            return "Learned from \(daysLogged) days of logging and \(weighIns) weigh-ins."
        }
    }

    // MARK: - Entry point

    static func estimate(
        profile: UserProfile,
        diary: [DiaryEntry],
        weights: [WeightEntry],
        asOf now: Date = Date()
    ) -> Result {
        let formula = profile.tdee
        let calendar = Calendar.current
        let windowStart = calendar.date(byAdding: .day, value: -windowDays, to: now) ?? now

        // --- Intake: only days that were actually logged count. A skipped day
        // isn't a zero-calorie day, and averaging zeros in would fake a deficit.
        var kcalByDay: [Date: Double] = [:]
        for entry in diary where entry.date >= windowStart && entry.date <= now {
            let day = calendar.startOfDay(for: entry.date)
            kcalByDay[day, default: 0] += entry.calories
        }
        // Guard against partially-logged days dragging the mean down.
        let loggedDays = kcalByDay.filter { $0.value >= 400 }
        let daysLogged = loggedDays.count
        let meanIntake = daysLogged > 0
            ? loggedDays.values.reduce(0, +) / Double(daysLogged)
            : 0

        // --- Weight trend
        //
        // The slope is fitted to the RAW weigh-ins, not the smoothed series.
        // An EMA lags by construction, and that lag biases the slope toward
        // zero — which would understate the deficit and hand back a maintenance
        // figure that's too low. Least squares is already a noise-robust
        // estimator and is unbiased here, so the smoothing is kept purely for
        // drawing a readable trend line.
        let windowWeights = weights
            .filter { $0.date >= windowStart && $0.date <= now }
            .sorted { $0.date < $1.date }
        let slopePerDay = linearSlopePerDay(windowWeights.map { (date: $0.date, kg: $0.kg) })
        let weeklyChange = slopePerDay.map { $0 * 7 }

        // --- Solve for expenditure
        var observed: Double?
        if daysLogged >= minimumDaysLogged,
           windowWeights.count >= 2,
           let slopePerDay,
           meanIntake > 0 {
            let dailyStorage = slopePerDay * kcalPerKg
            let candidate = meanIntake - dailyStorage
            // Reject physiologically implausible results — usually a mistyped
            // weight or a week of unlogged meals.
            if candidate > 1000, candidate < 6000 {
                observed = candidate
            }
        }

        let confidence = confidenceScore(
            daysLogged: daysLogged,
            weighIns: windowWeights.count,
            spanDays: spanInDays(windowWeights)
        )

        let blended: Double
        if let observed {
            blended = observed * confidence + formula * (1 - confidence)
        } else {
            blended = formula
        }

        return Result(
            tdee: blended,
            observedTDEE: observed,
            formulaTDEE: formula,
            confidence: observed == nil ? 0 : confidence,
            weeklyChangeKg: weeklyChange,
            daysLogged: daysLogged,
            weighIns: windowWeights.count
        )
    }

    /// Daily calorie target = learned maintenance + the goal's deficit/surplus.
    static func target(for profile: UserProfile, result: Result) -> Int {
        let raw = result.tdee + Double(profile.goal.calorieDelta)
        return min(max(Int(raw.rounded()), 1200), 6000)
    }

    // MARK: - Trend maths

    /// Exponentially-weighted moving average over the weigh-ins.
    ///
    /// Returned as (date, smoothedKg). A ~0.25 factor means today's reading
    /// contributes a quarter of the new trend value — responsive enough to
    /// follow real change, damped enough to ignore a salty dinner.
    static func exponentialTrend(_ entries: [WeightEntry], alpha: Double = 0.25) -> [(date: Date, kg: Double)] {
        guard !entries.isEmpty else { return [] }
        var smoothed: [(date: Date, kg: Double)] = []
        var current = entries[0].kg
        for entry in entries {
            current = alpha * entry.kg + (1 - alpha) * current
            smoothed.append((entry.date, current))
        }
        return smoothed
    }

    /// Least-squares slope in kg per day across the smoothed series.
    private static func linearSlopePerDay(_ points: [(date: Date, kg: Double)]) -> Double? {
        guard points.count >= 2, let first = points.first else { return nil }

        let xs = points.map { $0.date.timeIntervalSince(first.date) / 86400 }
        let ys = points.map(\.kg)
        let n = Double(points.count)

        let meanX = xs.reduce(0, +) / n
        let meanY = ys.reduce(0, +) / n

        var numerator = 0.0
        var denominator = 0.0
        for (x, y) in zip(xs, ys) {
            numerator += (x - meanX) * (y - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        // All weigh-ins on the same day — no slope to speak of.
        guard denominator > 0.0001 else { return nil }
        return numerator / denominator
    }

    private static func spanInDays(_ entries: [WeightEntry]) -> Double {
        guard let first = entries.first, let last = entries.last else { return 0 }
        return last.date.timeIntervalSince(first.date) / 86400
    }

    /// How much to trust the observation. Each factor saturates at 1, and the
    /// weakest one dominates — a month of logging is still worthless with a
    /// single weigh-in.
    private static func confidenceScore(daysLogged: Int, weighIns: Int, spanDays: Double) -> Double {
        let logging = min(Double(daysLogged) / 21.0, 1.0)
        let weighing = min(Double(weighIns) / 8.0, 1.0)
        let span = min(spanDays / 21.0, 1.0)
        return min(logging, weighing, span)
    }
}
