import Foundation

/// Cross-device calibration: learns how this user's WHOOP-derived numbers
/// relate to their Apple Watch's, from days when both were worn.
///
/// The Watch isn't ground truth — but Apple's energy and resting-HR models
/// are far better validated than a population HR regression, so agreement
/// with them is the best target available without a metabolic chamber.
/// Pure math, no app types: compiles standalone in Tests/run.sh.
enum CalibrationMath {

    /// Multiplier that maps our Keytel-derived daily kcal onto the Watch's
    /// active-energy scale.
    ///
    /// Estimator chosen for 5–30 noisy day-pairs where BOTH sides carry
    /// error (so least-squares would attenuate): a trimmed ratio-of-sums
    /// with shrinkage toward 1.0.
    ///
    /// 1. Quality filter — both sides in [100, 3000] kcal (ratios of small
    ///    numbers are noise; huge days are data errors), per-pair ratio
    ///    inside [0.4, 2.5].
    /// 2. Outlier screen — drop pairs whose log-ratio sits > 3 MAD from the
    ///    median log-ratio.
    /// 3. Point estimate — Σwatch / Σours over what survives.
    /// 4. Shrink toward 1.0 with weight n/(n+6), so a handful of odd days
    ///    can't produce an extreme factor; the data earns its influence.
    /// 5. Hard clamp to [0.5, 2.0].
    ///
    /// Callers should pass a rolling window (~30 recent pairs) — fitness and
    /// behaviour drift, so ancient pairs shouldn't vote forever.
    static func energyScale(pairs: [(ours: Double, watch: Double)]) -> Double? {
        let bounded = pairs.filter {
            $0.ours >= 100 && $0.watch >= 100 && $0.ours <= 3000 && $0.watch <= 3000
        }.filter {
            let ratio = $0.watch / $0.ours
            return ratio >= 0.4 && ratio <= 2.5
        }
        guard bounded.count >= 5 else { return nil }

        let logs = bounded.map { log($0.watch / $0.ours) }
        let medianLog = median(logs)
        let mad = median(logs.map { abs($0 - medianLog) })
        let kept = mad > 0
            ? bounded.enumerated().filter { abs(logs[$0.offset] - medianLog) <= 3 * mad }.map(\.element)
            : bounded
        guard kept.count >= 5 else { return nil }

        let k = kept.reduce(0) { $0 + $1.watch } / kept.reduce(0) { $0 + $1.ours }
        let n = Double(kept.count)
        let shrunk = (n * k + 6.0) / (n + 6.0)
        return min(2.0, max(0.5, shrunk))
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2)
            ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            : sorted[sorted.count / 2]
    }

    /// Systematic offset between our resting-HR proxy (lowest calm reading)
    /// and Apple's resting-HR algorithm, as median(ours − apple). Subtract it
    /// from our readings to put both devices on one scale, so a baseline can
    /// blend days from either wrist.
    static func restingHROffset(pairs: [(ours: Double, apple: Double)]) -> Double? {
        let diffs = pairs.map { $0.ours - $0.apple }.sorted()
        guard diffs.count >= 5 else { return nil }
        let median = diffs.count.isMultiple(of: 2)
            ? (diffs[diffs.count / 2 - 1] + diffs[diffs.count / 2]) / 2
            : diffs[diffs.count / 2]
        return min(15, max(-15, median))
    }

    /// Personal max HR from observed daily maxima, replacing the age formula
    /// once real data exceeds it.
    ///
    /// The *second*-highest observation is used: a single 210 bpm sample is
    /// far more likely to be optical artifact than a true max, but two
    /// independent days near the same peak is a real ceiling. Never returns
    /// less than the formula — undershooting max HR inflates every zone.
    static func personalMaxHR(observedDailyMaxes: [Int], age: Double) -> Double {
        let formula = 208 - 0.7 * age
        let plausible = observedDailyMaxes.filter { $0 > 100 && $0 < 220 }.sorted(by: >)
        guard plausible.count >= 2 else { return formula }
        return max(formula, Double(plausible[1]))
    }

    /// Blended resting-HR baseline across both devices: our summaries
    /// (corrected by `offset`) and Apple's resting HR, pooled, last 7 values,
    /// median. This is the payoff of the offset — days wearing either device
    /// keep the baseline alive.
    static func blendedRestingBaseline(
        ourRecent: [Double], appleRecent: [Double], offset: Double?
    ) -> Double? {
        let corrected = offset.map { o in ourRecent.map { $0 - o } } ?? ourRecent
        let pooled = (corrected + appleRecent).suffix(14).sorted()
        guard pooled.count >= 3 else { return nil }
        return pooled.count.isMultiple(of: 2)
            ? (pooled[pooled.count / 2 - 1] + pooled[pooled.count / 2]) / 2
            : pooled[pooled.count / 2]
    }
}
