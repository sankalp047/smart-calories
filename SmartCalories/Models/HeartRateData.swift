import Foundation

/// One day of heart data accumulated from a connected BLE monitor.
///
/// Persisted per-day rather than per-sample: the app's questions are all
/// daily-resolution (resting trend, active energy, HRV), and a day of
/// 1 Hz samples is ~86k rows of noise nobody will ever read back.
struct DailyHeartSummary: Identifiable, Codable, Equatable {
    var id: String { WeightEntry.dayKey(date) }
    let date: Date

    /// Lowest HR seen while calm — the day's best proxy for resting HR.
    var minHR: Int
    var maxHR: Int
    /// Running mean over all samples.
    var avgHR: Double
    var sampleCount: Int

    /// Exercise energy accumulated through the Keytel gate, kcal.
    var activeKcal: Double

    /// Median of calm-window RMSSD readings, ms. Only present when the
    /// monitor sends RR intervals (chest straps do; most wrist bands don't).
    var restRMSSD: Double?

    /// Banister training impulse accumulated across the day; the day-strain
    /// score is derived from this. Optional: days recorded before strain
    /// existed still decode.
    var trimp: Double?
    /// Seconds spent in each of the five HR zones today.
    var zoneSeconds: [Double]?

    var strain: Double { EnergyMath.strainScore(trimp: trimp ?? 0) }
}

/// What the app has learned from days when both WHOOP and Apple Watch were
/// worn. Every field is optional: nothing is applied until it's been earned
/// from enough paired days.
struct CalibrationState: Codable, Equatable {
    /// Multiplier applied to our Keytel kcal to match the Watch's scale.
    var energyScale: Double?
    /// Our resting-HR proxy minus Apple's resting HR (bpm); subtracting it
    /// puts our readings on the Watch's scale.
    var restingHROffset: Double?
    /// Personal max HR learned from observed peaks, replacing the age formula.
    var personalMaxHR: Double?
    var pairedEnergyDays: Int = 0
    var pairedRHRDays: Int = 0
    var updatedAt: Date?

    var isActive: Bool { energyScale != nil || restingHROffset != nil || personalMaxHR != nil }
}

/// Heart stats for one workout session, captured between start and finish.
struct SessionHeartStats: Codable, Hashable {
    var avgHR: Int
    var maxHR: Int
    var activeKcal: Double
    /// Strain contributed by this session alone (0–21 scale).
    var strain: Double?
    /// Seconds in each of the five HR zones during the session.
    var zoneSeconds: [Double]?
}
