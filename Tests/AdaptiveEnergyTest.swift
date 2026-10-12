import Foundation

// Scenario: someone eats a steady 2,500 kcal/day and loses 0.5 kg/week.
// Physiology says 0.5 kg/week = 3850 kcal/week = 550 kcal/day of deficit.
// So their TRUE maintenance must be 2500 + 550 = 3050 kcal — well above what
// the formula would guess. This is exactly what the estimator should recover.

let now = Date()
let cal = Calendar.current
var diary: [DiaryEntry] = []
var weights: [WeightEntry] = []

for dayBack in stride(from: 27, through: 0, by: -1) {
    let day = cal.date(byAdding: .day, value: -dayBack, to: now)!
    diary.append(DiaryEntry(foodId: "x", foodName: "Food", grams: 500,
                            calories: 2500, date: day))
    // 0.5 kg/week loss, weighed every other day, with ±0.4 kg water noise
    if dayBack % 2 == 0 {
        let weeks = Double(27 - dayBack) / 7.0
        let noise = [0.35, -0.28, 0.12, -0.4, 0.22, -0.15][(27 - dayBack) % 6]
        weights.append(WeightEntry(date: day, kg: 85.0 - 0.5 * weeks + noise))
    }
}

let profile = UserProfile(heightCm: 180, weightKg: 85, age: 30,
                          sex: .male, activity: .moderate, goal: .lose)
let r = AdaptiveEnergy.estimate(profile: profile, diary: diary, weights: weights, asOf: now)

print("Formula (Mifflin–St Jeor) says : \(Int(r.formulaTDEE)) kcal")
print("Observed from real data        : \(r.observedTDEE.map { String(Int($0)) } ?? "nil") kcal")
print("Blended estimate               : \(Int(r.tdee)) kcal")
print("Confidence                     : \(Int(r.confidence * 100))%")
print("Weekly trend                   : \(r.weeklyChangeKg.map { String(format: "%.2f kg", $0) } ?? "nil")")
print("Days logged / weigh-ins        : \(r.daysLogged) / \(r.weighIns)")
print("New daily target               : \(AdaptiveEnergy.target(for: profile, result: r)) kcal")

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print((ok ? "  ok   " : "  FAIL ") + name + " " + detail); if !ok { failures += 1 }
}
print("\nassertions:")
check("recovers ~3050 kcal despite noise",
      (r.observedTDEE ?? 0) > 2975 && (r.observedTDEE ?? 0) < 3125,
      "got \(r.observedTDEE.map { String(Int($0)) } ?? "nil")")
check("detects ~-0.5 kg/week trend",
      (r.weeklyChangeKg ?? 0) < -0.44 && (r.weeklyChangeKg ?? 0) > -0.58,
      String(format: "got %.2f", r.weeklyChangeKg ?? 0))
check("high confidence with 28d of data", r.confidence > 0.9)
check("exceeds the formula (which underestimates here)", r.tdee > r.formulaTDEE)
check("target applies the deficit", AdaptiveEnergy.target(for: profile, result: r) == min(max(Int((r.tdee - 500).rounded()), 1200), 6000))

// Sparse data must fall back to the formula rather than inventing a number.
let sparse = AdaptiveEnergy.estimate(
    profile: profile,
    diary: Array(diary.suffix(3)),
    weights: Array(weights.suffix(1)),
    asOf: now)
print("\nsparse-data safety:")
check("falls back to formula", sparse.observedTDEE == nil && Int(sparse.tdee) == Int(sparse.formulaTDEE))
check("reports zero confidence", sparse.confidence == 0)
check("is not marked adaptive", !sparse.isAdaptive)

print("\n\(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")")
exit(failures == 0 ? 0 : 1)
