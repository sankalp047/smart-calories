import Foundation

enum Sex: String, Codable, CaseIterable, Identifiable {
    case male, female, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .male: "Male"
        case .female: "Female"
        case .other: "Other"
        }
    }
}

enum ActivityLevel: String, Codable, CaseIterable, Identifiable {
    case sedentary, light, moderate, active, veryActive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sedentary: "Sedentary"
        case .light: "Light"
        case .moderate: "Moderate"
        case .active: "Active"
        case .veryActive: "Very active"
        }
    }
    var detail: String {
        switch self {
        case .sedentary: "Little or no exercise"
        case .light: "Exercise 1–3 days a week"
        case .moderate: "Exercise 3–5 days a week"
        case .active: "Exercise 6–7 days a week"
        case .veryActive: "Hard exercise or physical job"
        }
    }
    /// Harris–Benedict style activity multiplier applied to BMR.
    var factor: Double {
        switch self {
        case .sedentary: 1.2
        case .light: 1.375
        case .moderate: 1.55
        case .active: 1.725
        case .veryActive: 1.9
        }
    }
}

enum FitnessGoal: String, Codable, CaseIterable, Identifiable {
    case lose, maintain, gain
    var id: String { rawValue }

    var label: String {
        switch self {
        case .lose: "Lose fat"
        case .maintain: "Maintain"
        case .gain: "Build muscle"
        }
    }
    var calorieDelta: Int {
        switch self {
        case .lose: -500
        case .maintain: 0
        case .gain: 300
        }
    }
    var icon: String {
        switch self {
        case .lose: "arrow.down.right.circle.fill"
        case .maintain: "equal.circle.fill"
        case .gain: "arrow.up.right.circle.fill"
        }
    }
    /// Gerund form, for sentences like "Built around building muscle".
    var phrase: String {
        switch self {
        case .lose: "losing fat"
        case .maintain: "maintaining your weight"
        case .gain: "building muscle"
        }
    }
}

/// The user's profile. Drives calorie targets, derived health metrics and
/// workout personalization.
struct UserProfile: Codable, Hashable {
    var heightCm: Double
    var weightKg: Double
    var age: Int
    var sex: Sex
    var activity: ActivityLevel
    var goal: FitnessGoal

    // MARK: - Energy

    /// Mifflin–St Jeor basal metabolic rate.
    var bmr: Double {
        let base = 10 * weightKg + 6.25 * heightCm - 5 * Double(age)
        switch sex {
        case .male: return base + 5
        case .female: return base - 161
        case .other: return base - 78   // midpoint of the sex constants
        }
    }

    /// Total daily energy expenditure (maintenance calories).
    var tdee: Double { bmr * activity.factor }

    /// Daily calorie target for the chosen goal, clamped to a safe range.
    var recommendedCalories: Int {
        min(max(Int((tdee + Double(goal.calorieDelta)).rounded()), 1200), 6000)
    }

    // MARK: - Body composition

    var bmi: Double {
        let m = heightCm / 100
        return weightKg / (m * m)
    }

    var bmiCategory: String {
        switch bmi {
        case ..<18.5: "Underweight"
        case ..<25: "Normal"
        case ..<30: "Overweight"
        default: "Obese"
        }
    }

    /// Estimated body fat % via the Deurenberg formula.
    var bodyFatPercent: Double {
        let sexFactor: Double = switch sex {
        case .male: 1.0
        case .female: 0.0
        case .other: 0.5
        }
        let bf = 1.20 * bmi + 0.23 * Double(age) - 10.8 * sexFactor - 5.4
        return min(max(bf, 3), 60)
    }

    var leanBodyMassKg: Double { weightKg * (1 - bodyFatPercent / 100) }

    private var heightM: Double { heightCm / 100 }
    var idealWeightMinKg: Double { 18.5 * heightM * heightM }
    var idealWeightMaxKg: Double { 24.9 * heightM * heightM }

    // MARK: - Heart rate zones (age-predicted)

    var maxHeartRate: Int { 220 - age }
    var fatBurnZone: ClosedRange<Int> {
        Int((Double(maxHeartRate) * 0.60).rounded())...Int((Double(maxHeartRate) * 0.70).rounded())
    }
    var cardioZone: ClosedRange<Int> {
        Int((Double(maxHeartRate) * 0.70).rounded())...Int((Double(maxHeartRate) * 0.85).rounded())
    }

    // MARK: - Targets

    /// ~35 ml of water per kg of bodyweight.
    var dailyWaterMl: Double { weightKg * 35 }

    var proteinTargetG: Int { Int((weightKg * (goal == .gain ? 1.8 : 1.4)).rounded()) }
    /// Rough split used for the macro rings: fat ~25% of calories, carbs the rest.
    var fatTargetG: Int { Int((Double(recommendedCalories) * 0.25 / 9).rounded()) }
    var carbTargetG: Int {
        let fromProtein = Double(proteinTargetG) * 4
        let fromFat = Double(fatTargetG) * 9
        return max(0, Int(((Double(recommendedCalories) - fromProtein - fromFat) / 4).rounded()))
    }

    static let placeholder = UserProfile(
        heightCm: 175, weightKg: 75, age: 30,
        sex: .male, activity: .moderate, goal: .maintain
    )
}
