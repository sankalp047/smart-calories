import Foundation

enum WorkoutLevel: String, Codable, CaseIterable, Identifiable {
    case beginner, intermediate, advanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .beginner: "Beginner"
        case .intermediate: "Intermediate"
        case .advanced: "Advanced"
        }
    }
}

struct Exercise: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    let name: String
    let sets: Int
    let reps: String
    var notes: String = ""
}

struct WorkoutDay: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    let title: String
    let exercises: [Exercise]
}

struct WorkoutPlan: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    let name: String
    let summary: String
    let goal: FitnessGoal
    let level: WorkoutLevel
    let daysPerWeek: Int
    let days: [WorkoutDay]
    var isGenerated: Bool = false

    /// Coaching note tailored to the user's profile.
    func guidance(for profile: UserProfile?) -> String {
        guard let profile else {
            return "Aim for 2–4 sessions a week and add a rep or a little weight whenever a set starts to feel easy."
        }
        let protein = Int((profile.weightKg * (goal == .gain ? 1.8 : 1.4)).rounded())
        switch profile.goal {
        case .gain:
            return "Progressive overload is the whole game — add reps or load every week. Eat around \(profile.recommendedCalories) kcal and roughly \(protein) g of protein a day to actually build."
        case .lose:
            return "Keep rest short and stay near \(profile.recommendedCalories) kcal. Lifting is what preserves muscle in a deficit, so hold protein around \(protein) g a day."
        case .maintain:
            return "Train consistently and keep intake near \(profile.recommendedCalories) kcal with about \(protein) g of protein a day."
        }
    }
}

// MARK: - AI decoding

extension WorkoutPlan {
    init(aiJSON json: [String: Any], goal goalString: String) throws {
        let levelRaw = (json["level"] as? String ?? "beginner").lowercased()
        let level = WorkoutLevel(rawValue: levelRaw) ?? .beginner

        var parsedDays: [WorkoutDay] = []
        for rawDay in (json["days"] as? [[String: Any]] ?? []) {
            var exercises: [Exercise] = []
            for rawEx in (rawDay["exercises"] as? [[String: Any]] ?? []) {
                let sets = (rawEx["sets"] as? Int) ?? Int(rawEx["sets"] as? Double ?? 3)
                exercises.append(
                    Exercise(
                        name: rawEx["name"] as? String ?? "Exercise",
                        sets: max(1, sets),
                        reps: String(describing: rawEx["reps"] ?? "—"),
                        notes: rawEx["notes"] as? String ?? ""
                    )
                )
            }
            parsedDays.append(WorkoutDay(title: rawDay["title"] as? String ?? "Day",
                                         exercises: exercises))
        }
        guard !parsedDays.isEmpty else {
            throw AIError.decoding("The plan came back without any days.")
        }

        let matchedGoal = FitnessGoal.allCases.first {
            goalString.lowercased().contains($0.label.lowercased())
        } ?? .maintain

        self.init(
            name: json["name"] as? String ?? "Your plan",
            summary: json["summary"] as? String ?? "Personalized for your goal and equipment.",
            goal: matchedGoal,
            level: level,
            daysPerWeek: (json["daysPerWeek"] as? Int) ?? parsedDays.count,
            days: parsedDays,
            isGenerated: true
        )
    }
}

// MARK: - Curated library

enum WorkoutCatalog {

    static let all: [WorkoutPlan] = [foundations, heavyDuty, ultimate, circuit, bodyweight]

    /// Match a plan to the user's goal, with activity level as a proxy for
    /// training experience.
    static func recommended(for profile: UserProfile?) -> WorkoutPlan {
        guard let profile else { return foundations }
        let level: WorkoutLevel = switch profile.activity {
        case .sedentary, .light: .beginner
        case .moderate: .intermediate
        case .active, .veryActive: .advanced
        }
        return all.min { a, b in
            score(a, profile.goal, level) < score(b, profile.goal, level)
        } ?? foundations
    }

    private static func score(_ plan: WorkoutPlan, _ goal: FitnessGoal, _ level: WorkoutLevel) -> Int {
        var s = plan.goal == goal ? 0 : 10
        s += abs(levelIndex(plan.level) - levelIndex(level))
        return s
    }
    private static func levelIndex(_ l: WorkoutLevel) -> Int {
        switch l { case .beginner: 0; case .intermediate: 1; case .advanced: 2 }
    }

    // MARK: Plans

    static let foundations = WorkoutPlan(
        id: "foundations",
        name: "Full-Body Foundations",
        summary: "Three full-body days a week — the highest-return starting point for a new lifter.",
        goal: .gain, level: .beginner, daysPerWeek: 3,
        days: [
            WorkoutDay(title: "Day A", exercises: [
                Exercise(name: "Goblet Squat", sets: 3, reps: "8–12"),
                Exercise(name: "Push-up (or Bench Press)", sets: 3, reps: "8–12"),
                Exercise(name: "Dumbbell Row", sets: 3, reps: "10–12"),
                Exercise(name: "Plank", sets: 3, reps: "30–45s")
            ]),
            WorkoutDay(title: "Day B", exercises: [
                Exercise(name: "Romanian Deadlift", sets: 3, reps: "8–12"),
                Exercise(name: "Overhead Press", sets: 3, reps: "8–12"),
                Exercise(name: "Lat Pulldown", sets: 3, reps: "10–12"),
                Exercise(name: "Dead Bug", sets: 3, reps: "10 / side")
            ]),
            WorkoutDay(title: "Day C", exercises: [
                Exercise(name: "Walking Lunge", sets: 3, reps: "10 / leg"),
                Exercise(name: "Incline Dumbbell Press", sets: 3, reps: "10–12"),
                Exercise(name: "Seated Cable Row", sets: 3, reps: "10–12"),
                Exercise(name: "Hanging Knee Raise", sets: 3, reps: "10–15")
            ])
        ]
    )

    static let heavyDuty = WorkoutPlan(
        id: "heavy_duty",
        name: "Heavy Duty — Mentzer HIT",
        summary: "Mike Mentzer's high-intensity method: one all-out set per exercise taken to muscular failure, with long recovery between sessions.",
        goal: .gain, level: .advanced, daysPerWeek: 3,
        days: [
            WorkoutDay(title: "Day 1 — Chest & Back", exercises: [
                Exercise(name: "Incline Press", sets: 1, reps: "6–10 to failure",
                         notes: "One working set. Take it to genuine positive failure."),
                Exercise(name: "Pec Deck → Incline Press", sets: 1, reps: "to failure",
                         notes: "Pre-exhaust superset — no rest between the two."),
                Exercise(name: "Close-grip Pulldown", sets: 1, reps: "6–10 to failure"),
                Exercise(name: "Bent-over Barbell Row", sets: 1, reps: "6–10 to failure"),
                Exercise(name: "Deadlift", sets: 1, reps: "5–8", notes: "One hard set, form first.")
            ]),
            WorkoutDay(title: "Day 2 — Legs", exercises: [
                Exercise(name: "Leg Extension → Leg Press", sets: 1, reps: "to failure",
                         notes: "Pre-exhaust the quads, then press immediately."),
                Exercise(name: "Leg Curl", sets: 1, reps: "8–12 to failure"),
                Exercise(name: "Standing Calf Raise", sets: 1, reps: "10–15 to failure")
            ]),
            WorkoutDay(title: "Day 3 — Delts & Arms", exercises: [
                Exercise(name: "Lateral Raise", sets: 1, reps: "8–12 to failure"),
                Exercise(name: "Bent-over Lateral Raise", sets: 1, reps: "8–12 to failure"),
                Exercise(name: "Barbell Curl", sets: 1, reps: "6–10 to failure"),
                Exercise(name: "Triceps Pushdown → Dips", sets: 1, reps: "to failure")
            ])
        ]
    )

    static let ultimate = WorkoutPlan(
        id: "ultimate_bodybuilding",
        name: "Ultimate Bodybuilding",
        summary: "A five-day split built on heavy compound lifts with intensity-raising supersets for maximum hypertrophy.",
        goal: .gain, level: .advanced, daysPerWeek: 5,
        days: [
            WorkoutDay(title: "Chest", exercises: [
                Exercise(name: "Barbell Bench Press", sets: 4, reps: "6–10", notes: "Main compound."),
                Exercise(name: "Incline DB Press → Cable Flye", sets: 3, reps: "10–12", notes: "Superset."),
                Exercise(name: "Weighted Dips", sets: 3, reps: "8–12")
            ]),
            WorkoutDay(title: "Back", exercises: [
                Exercise(name: "Deadlift", sets: 4, reps: "5–8", notes: "Heavy compound."),
                Exercise(name: "Weighted Pull-up → Barbell Row", sets: 3, reps: "8–12", notes: "Superset."),
                Exercise(name: "Seated Cable Row", sets: 3, reps: "10–12")
            ]),
            WorkoutDay(title: "Legs", exercises: [
                Exercise(name: "Back Squat", sets: 4, reps: "6–10", notes: "Main compound."),
                Exercise(name: "Romanian Deadlift → Leg Curl", sets: 3, reps: "10–12", notes: "Superset."),
                Exercise(name: "Leg Press", sets: 3, reps: "12–15"),
                Exercise(name: "Calf Raise", sets: 4, reps: "15–20")
            ]),
            WorkoutDay(title: "Shoulders", exercises: [
                Exercise(name: "Overhead Press", sets: 4, reps: "6–10", notes: "Main compound."),
                Exercise(name: "Lateral Raise → Rear Delt Flye", sets: 4, reps: "12–15", notes: "Superset."),
                Exercise(name: "Barbell Shrug", sets: 3, reps: "10–12")
            ]),
            WorkoutDay(title: "Arms", exercises: [
                Exercise(name: "Barbell Curl → Skullcrusher", sets: 4, reps: "8–12", notes: "Superset."),
                Exercise(name: "Hammer Curl → Rope Pushdown", sets: 3, reps: "10–12", notes: "Superset."),
                Exercise(name: "Preacher Curl", sets: 3, reps: "10–12")
            ])
        ]
    )

    static let circuit = WorkoutPlan(
        id: "fatloss_circuit",
        name: "Fat-Loss Circuit",
        summary: "Fast-paced circuits that burn calories while keeping the muscle you already built.",
        goal: .lose, level: .intermediate, daysPerWeek: 4,
        days: [
            WorkoutDay(title: "Circuit A — 3 rounds", exercises: [
                Exercise(name: "Kettlebell Swing", sets: 3, reps: "15"),
                Exercise(name: "Goblet Squat", sets: 3, reps: "15"),
                Exercise(name: "Push-up", sets: 3, reps: "12"),
                Exercise(name: "Mountain Climbers", sets: 3, reps: "30s")
            ]),
            WorkoutDay(title: "Circuit B — 3 rounds", exercises: [
                Exercise(name: "Dumbbell Thruster", sets: 3, reps: "12"),
                Exercise(name: "Reverse Lunge", sets: 3, reps: "12 / leg"),
                Exercise(name: "Renegade Row", sets: 3, reps: "10"),
                Exercise(name: "Burpees", sets: 3, reps: "10")
            ])
        ]
    )

    static let bodyweight = WorkoutPlan(
        id: "home_bodyweight",
        name: "Home — No Equipment",
        summary: "Bodyweight only, anywhere. Built for staying consistent when you can't get to a gym.",
        goal: .maintain, level: .beginner, daysPerWeek: 4,
        days: [
            WorkoutDay(title: "Lower", exercises: [
                Exercise(name: "Bodyweight Squat", sets: 3, reps: "15–20"),
                Exercise(name: "Glute Bridge", sets: 3, reps: "15"),
                Exercise(name: "Reverse Lunge", sets: 3, reps: "12 / leg"),
                Exercise(name: "Wall Sit", sets: 3, reps: "30–45s")
            ]),
            WorkoutDay(title: "Upper", exercises: [
                Exercise(name: "Push-up", sets: 3, reps: "AMRAP"),
                Exercise(name: "Pike Push-up", sets: 3, reps: "8–12"),
                Exercise(name: "Superman", sets: 3, reps: "15"),
                Exercise(name: "Plank", sets: 3, reps: "30–60s")
            ])
        ]
    )

    /// Equipment the user can pick from when generating a gym-constrained plan.
    static let equipmentOptions: [(name: String, icon: String)] = [
        ("Barbell", "figure.strengthtraining.traditional"),
        ("Dumbbells", "dumbbell.fill"),
        ("Bench", "chair.lounge.fill"),
        ("Squat Rack", "square.split.bottomrightquarter.fill"),
        ("Smith Machine", "rectangle.split.3x1.fill"),
        ("Cable Machine", "cable.connector"),
        ("Lat Pulldown", "arrow.down.to.line"),
        ("Seated Row", "figure.rower"),
        ("Leg Press", "figure.seated.side"),
        ("Leg Curl", "figure.flexibility"),
        ("Leg Extension", "figure.seated.seatbelt"),
        ("Pec Deck", "arrow.left.and.right"),
        ("Pull-up Bar", "figure.play"),
        ("Dip Station", "parallelogram"),
        ("Kettlebells", "bag.fill"),
        ("Resistance Bands", "waveform.path"),
        ("Treadmill", "figure.run"),
        ("Rowing Machine", "figure.rower"),
        ("Bodyweight only", "figure.stand")
    ]
}
