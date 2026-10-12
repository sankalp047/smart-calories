import Foundation

// Known-answer tests for EnergyMath. Values computed by hand from the
// published formulas, not by running the code — that's the point.

var failures = 0
func check(_ name: String, _ condition: Bool, _ detail: String = "") {
    print("  \(condition ? "ok  " : "FAIL") \(name) \(detail)")
    if !condition { failures += 1 }
}

print("keytel:")
// Male, HR 140, 80 kg, age 30:
// (-55.0969 + 0.6309*140 + 0.1988*80 + 0.2017*30) / 4.184 = 13.19 kcal/min
let male = EnergyMath.keytelKcalPerMinute(hr: 140, weightKg: 80, age: 30, isMale: true)
check("male 140 bpm ≈ 13.19 kcal/min", abs(male - 13.19) < 0.01, String(format: "got %.2f", male))

// Female, HR 140, 65 kg, age 30:
// (-20.4022 + 0.4472*140 - 0.1263*65 + 0.074*30) / 4.184 = 8.66 kcal/min
let female = EnergyMath.keytelKcalPerMinute(hr: 140, weightKg: 65, age: 30, isMale: false)
check("female 140 bpm ≈ 8.66 kcal/min", abs(female - 8.66) < 0.01, String(format: "got %.2f", female))

// Below the regression's range the raw value goes negative — must clamp to 0.
let rest = EnergyMath.keytelKcalPerMinute(hr: 55, weightKg: 55, age: 25, isMale: false)
check("negative regression clamps to 0", rest == 0, String(format: "got %.2f", rest))

print("gates and zones:")
// Age 30 → Tanaka max = 208 − 21 = 187; 50% gate = 93.5.
check("93 bpm below gate", !EnergyMath.isExerciseHeartRate(93, age: 30))
check("94 bpm above gate", EnergyMath.isExerciseHeartRate(94, age: 30))
check("zone 1 at 100 bpm", EnergyMath.zone(hr: 100, age: 30) == 1)
check("zone 2 at 120 bpm", EnergyMath.zone(hr: 120, age: 30) == 2)
check("zone 4 at 168 bpm", EnergyMath.zone(hr: 168, age: 30) == 4)
check("zone 5 at 170 bpm", EnergyMath.zone(hr: 170, age: 30) == 5)

print("rmssd:")
// RR [800, 810, 790, 805]: diffs 10, −20, 15 → √(725/3) = 15.55 ms
let rmssd = EnergyMath.rmssd(rrIntervalsMs: [800, 810, 790, 805])
check("known series ≈ 15.55 ms", rmssd.map { abs($0 - 15.55) < 0.01 } ?? false,
      rmssd.map { String(format: "got %.2f", $0) } ?? "got nil")
check("single interval returns nil", EnergyMath.rmssd(rrIntervalsMs: [800]) == nil)

print("strain (TRIMP):")
// 10 min at HR 150, rest 60, max 190, male:
// x = 90/130 = 0.6923; 0.64·e^(1.92·0.6923) = 2.418; ×x×10 min = 16.74
let trimp = EnergyMath.trimpIncrement(minutes: 10, hr: 150, restHR: 60, maxHR: 190, isMale: true)
check("10 min @150 bpm ≈ 16.74", abs(trimp - 16.74) < 0.05, String(format: "got %.2f", trimp))
check("resting HR contributes zero",
      EnergyMath.trimpIncrement(minutes: 10, hr: 60, restHR: 60, maxHR: 190, isMale: true) == 0)
check("degenerate max≤rest is zero",
      EnergyMath.trimpIncrement(minutes: 10, hr: 150, restHR: 190, maxHR: 190, isMale: true) == 0)
// strain(120) = 21·(1 − e⁻¹) = 13.27; strain(400) = 20.25
check("strain at τ ≈ 13.27", abs(EnergyMath.strainScore(trimp: 120) - 13.27) < 0.01,
      String(format: "got %.2f", EnergyMath.strainScore(trimp: 120)))
// At extreme trimp the exponential underflows and the score touches 21.0
// exactly — the invariant is that it can never exceed the scale.
check("strain never exceeds 21", EnergyMath.strainScore(trimp: 10_000) <= 21
      && EnergyMath.strainScore(trimp: 400) < 21)
check("zero trimp is zero strain", EnergyMath.strainScore(trimp: 0) == 0)

print("readiness:")
// Baseline morning, full sleep → 100.
check("at baseline + full sleep = 100",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: 480) == 100)
// +5 bpm elevated → −30.
check("elevated RHR docks 6/bpm",
      EnergyMath.readinessScore(restingHR: 60, baselineRestingHR: 55, sleepMinutes: 480) == 70)
// 6 h sleep = 25% shortfall → −10.
check("short sleep docks proportionally",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: 360) == 90)
// Better-than-baseline must not inflate past 100.
check("low RHR earns no bonus",
      EnergyMath.readinessScore(restingHR: 50, baselineRestingHR: 55, sleepMinutes: 480) == 100)
// Disaster morning clamps at 0, never negative.
check("clamps at zero",
      EnergyMath.readinessScore(restingHR: 80, baselineRestingHR: 55, sleepMinutes: 120) == 0)
// No sleep data: judge on RHR alone rather than guessing.
check("missing sleep is neutral",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: nil) == 100)

print("calibration — energy scale:")
// 7 pairs at ratio 1.2 plus one absurd 3.0-ratio day: the outlier is outside
// the [0.4, 2.5] bound and dropped; k = 1.2 shrunk by (7·1.2+6)/13 = 1.1077.
var pairs: [(ours: Double, watch: Double)] = Array(repeating: (500.0, 600.0), count: 7)
pairs.append((400.0, 1200.0))
let scale = CalibrationMath.energyScale(pairs: pairs)
check("outlier dropped, factor shrunk toward 1", scale.map { abs($0 - 1.1077) < 0.001 } ?? false,
      scale.map { String(format: "got %.4f", $0) } ?? "got nil")
// With 60 pairs the shrinkage weight fades: (60·1.2+6)/66 = 1.1818.
let many = CalibrationMath.energyScale(pairs: Array(repeating: (500.0, 600.0), count: 60))
check("more data earns more influence", many.map { abs($0 - 1.1818) < 0.001 } ?? false,
      many.map { String(format: "got %.4f", $0) } ?? "got nil")
check("4 pairs is not enough",
      CalibrationMath.energyScale(pairs: Array(repeating: (500.0, 600.0), count: 4)) == nil)
check("trivial days dropped",
      CalibrationMath.energyScale(pairs: Array(repeating: (50.0, 600.0), count: 10)) == nil)
// 30 pairs at ratio 2.4: shrunk = (30·2.4+6)/36 = 2.167 → clamped to 2.0.
check("clamps runaway factor",
      CalibrationMath.energyScale(pairs: Array(repeating: (200.0, 480.0), count: 30)) == 2.0)

print("calibration — resting HR offset:")
// Ours reads 4 above Apple consistently → offset 4.
let rhrPairs: [(ours: Double, apple: Double)] = [(58, 54), (59, 55), (57, 53), (60, 56), (58, 54)]
let offset = CalibrationMath.restingHROffset(pairs: rhrPairs)
check("finds +4 offset", offset == 4, offset.map { String(format: "got %.1f", $0) } ?? "nil")
check("needs 5 pairs", CalibrationMath.restingHROffset(pairs: Array(rhrPairs.prefix(4))) == nil)

print("calibration — personal max HR:")
// Age 30 formula = 187. Observed 195 twice → 195; a lone 214 spike ignored.
check("second-highest beats formula",
      CalibrationMath.personalMaxHR(observedDailyMaxes: [195, 196, 170, 165], age: 30) == 195)
// The 214 spike is rejected; second-highest 170 is below the formula's 187,
// so the formula floor wins — the spike must NOT become the max.
check("single spike is artifact",
      abs(CalibrationMath.personalMaxHR(observedDailyMaxes: [214, 170, 168, 165], age: 30) - 187) < 0.001)
check("never below formula",
      CalibrationMath.personalMaxHR(observedDailyMaxes: [150, 148, 145], age: 30) == 187 - 0.0)
check("empty falls back to formula",
      abs(CalibrationMath.personalMaxHR(observedDailyMaxes: [], age: 30) - 187) < 0.001)

print("calibration — blended baseline:")
// Ours [58,59,57] with offset +4 → [54,55,53]; Apple [54,54] → pooled median 54.
let blended = CalibrationMath.blendedRestingBaseline(
    ourRecent: [58, 59, 57], appleRecent: [54, 54], offset: 4)
check("blends across devices on one scale", blended == 54,
      blended.map { String(format: "got %.1f", $0) } ?? "nil")
check("too little data is nil",
      CalibrationMath.blendedRestingBaseline(ourRecent: [58], appleRecent: [54], offset: nil) == nil)

print("readiness with HRV:")
// 30% HRV suppression alone → 100 − 18 = 82.
check("HRV suppression docks 0.6/percent",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: 480,
                                hrvSDNN: 42, hrvBaseline: 60) == 82)
check("HRV above baseline earns no bonus",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: 480,
                                hrvSDNN: 80, hrvBaseline: 60) == 100)
check("nil HRV leaves score untouched",
      EnergyMath.readinessScore(restingHR: 55, baselineRestingHR: 55, sleepMinutes: 480) == 100)

print("personal max HR feeds zones:")
// Max 200 instead of 187: 168 bpm is 84% → zone 4 either way, but 178 is
// 89% of 200 (zone 4) vs 95% of 187 (zone 5).
check("override changes zone boundary",
      EnergyMath.zone(hr: 178, age: 30, maxHR: 200) == 4
      && EnergyMath.zone(hr: 178, age: 30) == 5)

print("sample archive (CSV core):")
// Good lines parse; the torn line from a crash and garbage values are
// skipped without poisoning the rest.
let csv = "100,72\n101,74\n102,999\nbroken\n103,80\n104,7"
let picked = HeartSampleStore.select(fromCSV: csv, afterTs: 0, limit: 10)
check("parses valid, skips torn/garbage", picked.map(\.ts) == [100, 101, 103],
      "got \(picked.map(\.ts))")
check("cursor excludes shipped samples",
      HeartSampleStore.select(fromCSV: csv, afterTs: 101, limit: 10).map(\.ts) == [103])
check("limit respected",
      HeartSampleStore.select(fromCSV: csv, afterTs: 0, limit: 2).count == 2)
check("day bucket is UTC", HeartSampleStore.dayName(forTs: 0) == "1970-01-01")

print("chart bucketing:")
// Samples at 0,30,60,90 s with bucket 60: two buckets [0,30]→(70,75) and
// [60,90]→(80,100); first avg 72.5, second min 80 max 100.
let raw = [(ts: 0, bpm: 70), (ts: 30, bpm: 75), (ts: 60, bpm: 80), (ts: 90, bpm: 100)]
let buckets = HeartSampleStore.bucketed(raw, bucketSeconds: 60)
check("two buckets from 4 samples", buckets.count == 2)
check("bucket mean is right", buckets.first.map { abs($0.avgBpm - 72.5) < 0.001 } ?? false)
check("envelope min/max kept",
      buckets.last.map { $0.minBpm == 80 && $0.maxBpm == 100 } ?? false)
check("empty in, empty out", HeartSampleStore.bucketed([], bucketSeconds: 60).isEmpty)
check("zero bucket width is safe", HeartSampleStore.bucketed(raw, bucketSeconds: 0).isEmpty)
// Adaptive width: 1-min window → 1 s buckets; 1-hour → 20 s; never zero.
check("adaptive width at 1 min", HeartSampleStore.adaptiveBucketSeconds(windowSeconds: 60) == 1)
check("adaptive width at 1 hour", HeartSampleStore.adaptiveBucketSeconds(windowSeconds: 3600) == 20)
check("adaptive width never zero", HeartSampleStore.adaptiveBucketSeconds(windowSeconds: 0) == 1)

print("intake audit:")
// Floor = 1800 + 0.10×2200 + 500 = 2520; adaptive 2200 → gap 320.
let bias = EnergyMath.unloggedIntakeLowerBound(
    adaptiveTDEE: 2200, bmr: 1800, meanLoggedIntake: 2200, meanSensorActiveKcal: 500)
check("detects 320 kcal gap", bias.map { abs($0 - 320) < 0.01 } ?? false,
      bias.map { String(format: "got %.0f", $0) } ?? "got nil")

// Gap of 100 is model noise, not signal — must stay silent.
let noise = EnergyMath.unloggedIntakeLowerBound(
    adaptiveTDEE: 2420, bmr: 1800, meanLoggedIntake: 2200, meanSensorActiveKcal: 500)
check("100 kcal gap suppressed", noise == nil)

// Accurate logger (adaptive above floor) must never be accused.
let honest = EnergyMath.unloggedIntakeLowerBound(
    adaptiveTDEE: 2900, bmr: 1800, meanLoggedIntake: 2200, meanSensorActiveKcal: 500)
check("no false accusation", honest == nil)

print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
