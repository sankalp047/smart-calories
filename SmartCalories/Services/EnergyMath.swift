import Foundation

/// Pure math for heart-rate-derived energy and the intake audit.
///
/// Kept free of app types (no UserProfile, no services) so the whole file
/// compiles standalone in Tests/run.sh and the formulas can be verified
/// against known answers — the AdaptiveEnergy slope bug taught us that a
/// clean build proves nothing about the numbers.
enum EnergyMath {

    // MARK: - Calories from heart rate

    /// Energy expenditure during exercise from heart rate, per Keytel et al.
    /// (2005), the standard regression for HR-based estimation without a
    /// VO2max measurement. Returns kcal/minute.
    ///
    /// Only valid while HR is genuinely elevated by exercise — at rest the
    /// regression goes negative, which is why callers must gate on
    /// `isExerciseHeartRate` rather than feeding it every sample.
    static func keytelKcalPerMinute(hr: Double, weightKg: Double, age: Double, isMale: Bool) -> Double {
        let kj: Double
        if isMale {
            kj = -55.0969 + 0.6309 * hr + 0.1988 * weightKg + 0.2017 * age
        } else {
            kj = -20.4022 + 0.4472 * hr - 0.1263 * weightKg + 0.0740 * age
        }
        return max(0, kj / 4.184)
    }

    /// Age-predicted maximum heart rate (Tanaka, more accurate than 220−age).
    static func predictedMaxHR(age: Double) -> Double {
        208 - 0.7 * age
    }

    /// The gate for calorie accumulation: ≥50% of max HR.
    /// Below that the Keytel regression is outside its calibration range.
    /// `maxHR` overrides the age formula once a personal max is learned.
    static func isExerciseHeartRate(_ hr: Double, age: Double, maxHR: Double? = nil) -> Bool {
        hr >= 0.5 * (maxHR ?? predictedMaxHR(age: age))
    }

    /// Training zone (1–5) for the live UI, by fraction of max HR.
    static func zone(hr: Double, age: Double, maxHR: Double? = nil) -> Int {
        let fraction = hr / (maxHR ?? predictedMaxHR(age: age))
        switch fraction {
        case ..<0.6: return 1
        case ..<0.7: return 2
        case ..<0.8: return 3
        case ..<0.9: return 4
        default: return 5
        }
    }

    // MARK: - Heart rate variability

    /// RMSSD over a series of RR intervals in milliseconds — the standard
    /// short-window HRV metric. Needs at least 2 intervals.
    ///
    /// Only meaningful at rest; callers gate collection on a calm heart rate.
    static func rmssd(rrIntervalsMs: [Double]) -> Double? {
        guard rrIntervalsMs.count >= 2 else { return nil }
        var sumSquares = 0.0
        for i in 1..<rrIntervalsMs.count {
            let d = rrIntervalsMs[i] - rrIntervalsMs[i - 1]
            sumSquares += d * d
        }
        return (sumSquares / Double(rrIntervalsMs.count - 1)).squareRoot()
    }

    // MARK: - Training load (strain)

    /// Banister TRIMP increment for `minutes` spent at heart rate `hr`.
    ///
    /// TRIMP weights time by *relative* intensity — fraction of heart-rate
    /// reserve — with an exponential bonus for the top end, so ten hard
    /// minutes count far more than thirty easy ones. This is the published
    /// model WHOOP's proprietary strain descends from.
    static func trimpIncrement(
        minutes: Double, hr: Double, restHR: Double, maxHR: Double, isMale: Bool
    ) -> Double {
        guard maxHR > restHR, minutes > 0 else { return 0 }
        let x = max(0, min(1, (hr - restHR) / (maxHR - restHR)))
        guard x > 0 else { return 0 }
        let weight = isMale ? 0.64 * exp(1.92 * x) : 0.86 * exp(1.67 * x)
        return minutes * x * weight
    }

    /// Map accumulated TRIMP onto the familiar 0–21 scale, saturating
    /// logarithmically — like the original, going from 17 to 18 is much
    /// harder than going from 3 to 4. τ=120 puts a solid one-hour session
    /// around 13 and a brutal double day near 20.
    static func strainScore(trimp: Double) -> Double {
        21 * (1 - exp(-max(0, trimp) / 120))
    }

    // MARK: - Readiness

    /// 0–100 from this morning's resting HR against its baseline, docked for
    /// short sleep — and, when the Apple Watch provides overnight HRV (SDNN),
    /// docked for HRV suppression too. Deliberately *not* called recovery:
    /// each input is only used when genuinely measured.
    ///
    /// HRV enters as *percentage* below the personal baseline: SDNN varies
    /// hugely between people (20–100+ ms), so absolute deltas would mean
    /// nothing, but a 30% drop below your own baseline is signal for anyone.
    /// Like resting HR, above-baseline HRV earns no bonus — readiness caps
    /// at 100 and only measured stress subtracts.
    static func readinessScore(
        restingHR: Double, baselineRestingHR: Double,
        sleepMinutes: Double?, sleepNeedMinutes: Double = 480,
        hrvSDNN: Double? = nil, hrvBaseline: Double? = nil
    ) -> Double {
        // Six points per bpm above baseline; a lower-than-baseline morning
        // is good news but doesn't earn bonus points.
        var score = 100.0 - max(0, restingHR - baselineRestingHR) * 6
        if let sleepMinutes {
            let shortfall = max(0, sleepNeedMinutes - sleepMinutes) / sleepNeedMinutes
            score -= shortfall * 40
        }
        if let hrvSDNN, let hrvBaseline, hrvBaseline > 0 {
            let suppression = max(0, (hrvBaseline - hrvSDNN) / hrvBaseline)
            score -= suppression * 60          // 30% below baseline → −18
        }
        return max(0, min(100, score))
    }

    // MARK: - Intake audit

    /// Estimated daily *unlogged* intake, from two independent views of TDEE.
    ///
    /// The adaptive estimator derives TDEE from `intake − Δweight`; if the
    /// user under-logs by B kcal/day, that estimate is low by exactly B. An
    /// independent floor on true TDEE is BMR + thermic effect (~10% of what
    /// was logged) + sensor-measured exercise energy — a floor because NEAT
    /// is invisible to a heart-rate sensor. The gap between the floor and the
    /// adaptive figure is therefore a *lower bound* on unlogged intake.
    ///
    /// Returns nil unless the gap is big enough to be signal (≥150 kcal)
    /// rather than model noise.
    static func unloggedIntakeLowerBound(
        adaptiveTDEE: Double,
        bmr: Double,
        meanLoggedIntake: Double,
        meanSensorActiveKcal: Double
    ) -> Double? {
        let floorTDEE = bmr + 0.10 * meanLoggedIntake + meanSensorActiveKcal
        let gap = floorTDEE - adaptiveTDEE
        return gap >= 150 ? gap : nil
    }
}
