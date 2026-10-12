import AppIntents
import Foundation

/// Siri, Shortcuts, Spotlight and the Action button.
///
/// These run **outside** the app process — often while it isn't even launched —
/// so they can't touch `AppEnvironment`. Instead they read and write the same
/// JSON in `Store`, and the app reloads from disk when it next becomes active.
/// That keeps one source of truth without needing the app alive.

// MARK: - Shared access

enum IntentStore {

    static func loadDiary() -> [DiaryEntry] {
        Store.load([DiaryEntry].self, key: Store.Key.diary) ?? []
    }

    static func append(_ entry: DiaryEntry) {
        var diary = loadDiary()
        diary.append(entry)
        Store.save(diary, key: Store.Key.diary)
        refreshWidget()
    }

    static func addWater(_ ml: Double) -> Double {
        var log = Store.load([WaterEntry].self, key: Store.Key.water) ?? []
        let today = Calendar.current.startOfDay(for: Date())
        if let index = log.firstIndex(where: { Calendar.current.isDate($0.date, inSameDayAs: today) }) {
            log[index].ml = max(0, log[index].ml + ml)
        } else {
            log.append(WaterEntry(date: today, ml: max(0, ml)))
        }
        Store.save(log, key: Store.Key.water)
        return log.first { Calendar.current.isDate($0.date, inSameDayAs: today) }?.ml ?? 0
    }

    static var caloriesToday: Double {
        loadDiary()
            .filter { Calendar.current.isDateInToday($0.date) }
            .reduce(0) { $0 + $1.calories }
    }

    static var calorieGoal: Double {
        let settings = Store.load(AppSettings.self, key: Store.Key.settings)
        if let override = settings?.calorieGoalOverride { return Double(override) }
        guard let profile = Store.load(UserProfile.self, key: Store.Key.profile) else { return 2000 }
        let diary = loadDiary()
        let weights = Store.load([WeightEntry].self, key: Store.Key.weights) ?? []
        let energy = AdaptiveEnergy.estimate(profile: profile, diary: diary, weights: weights)
        return energy.isAdaptive
            ? Double(AdaptiveEnergy.target(for: profile, result: energy))
            : Double(profile.recommendedCalories)
    }

    static var favorites: [FavoriteFood] {
        Store.load([FavoriteFood].self, key: Store.Key.favorites) ?? []
    }

    /// Keep the widget honest after an out-of-app change.
    static func refreshWidget() {
        WidgetBridge.publish(
            eaten: caloriesToday,
            goal: calorieGoal,
            burned: Double(UserDefaults(suiteName: WidgetBridge.appGroup)?
                .integer(forKey: "calories_burned") ?? 0)
        )
    }
}

// MARK: - Log water

struct LogWaterIntent: AppIntent {
    static var title: LocalizedStringResource = "Log Water"
    static var description = IntentDescription("Add water to today's total.")
    /// Runs without bringing the app forward — the whole point of a quick log.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Amount (ml)", default: 250)
    var milliliters: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$milliliters) ml of water")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let total = IntentStore.addWater(Double(milliliters))
        return .result(dialog: "Logged \(milliliters) ml. That's \(Int(total)) ml today.")
    }
}

// MARK: - Calories remaining

struct CaloriesRemainingIntent: AppIntent {
    static var title: LocalizedStringResource = "Calories Remaining"
    static var description = IntentDescription("Check how many calories you have left today.")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let eaten = IntentStore.caloriesToday
        let goal = IntentStore.calorieGoal
        let remaining = goal - eaten

        let dialog: IntentDialog = remaining >= 0
            ? "You have \(Int(remaining)) calories left today. You've eaten \(Int(eaten)) of \(Int(goal))."
            : "You're \(Int(-remaining)) calories over your \(Int(goal)) target."
        return .result(dialog: dialog)
    }
}

// MARK: - Log a favourite

/// Favourites become a Siri-pickable list, so "log my usual breakfast" works.
struct FavoriteFoodEntity: AppEntity {
    let id: String
    let name: String
    let grams: Double
    let calories: Double

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Favourite Food"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(Int(grams)) g · \(Int(calories)) kcal")
    }

    static var defaultQuery = FavoriteFoodQuery()
}

struct FavoriteFoodQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [FavoriteFoodEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [FavoriteFoodEntity] {
        IntentStore.favorites.map {
            FavoriteFoodEntity(
                id: $0.food.id,
                name: $0.food.name,
                grams: $0.lastGrams,
                calories: $0.food.calories(forGrams: $0.lastGrams)
            )
        }
    }
}

struct LogFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Log a Favourite Food"
    static var description = IntentDescription("Quickly log one of your saved foods.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Food")
    var food: FavoriteFoodEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$food)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let favorite = IntentStore.favorites.first(where: { $0.food.id == food.id }) else {
            return .result(dialog: "I couldn't find that food in your favourites.")
        }
        let entry = DiaryEntry(food: favorite.food, grams: favorite.lastGrams)
        IntentStore.append(entry)

        let remaining = IntentStore.calorieGoal - IntentStore.caloriesToday
        return .result(
            dialog: "Logged \(favorite.food.name), \(Int(entry.calories)) calories. \(Int(remaining)) left today."
        )
    }
}

// MARK: - Siri phrases

struct SmartCaloriesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: CaloriesRemainingIntent(),
            phrases: [
                "How many calories do I have left in \(.applicationName)",
                "Calories remaining in \(.applicationName)",
                "\(.applicationName) calories left"
            ],
            shortTitle: "Calories Left",
            systemImageName: "flame.fill"
        )
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Add water to \(.applicationName)"
            ],
            shortTitle: "Log Water",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: LogFavoriteIntent(),
            phrases: [
                "Log a favourite in \(.applicationName)",
                "Log food in \(.applicationName)"
            ],
            shortTitle: "Log Favourite",
            systemImageName: "star.fill"
        )
    }
}
