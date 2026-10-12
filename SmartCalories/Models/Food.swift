import Foundation

/// A food item. Values are per 100 g of edible portion (USDA SR28 convention),
/// which lets one formula serve dataset foods, barcode lookups and AI results.
struct Food: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let category: String
    let kcalPer100g: Double
    var proteinPer100g: Double?
    var fatPer100g: Double?
    var carbsPer100g: Double?
    var fiberPer100g: Double?
    var sugarsPer100g: Double?
    var sodiumMgPer100g: Double?
    var saturatedFatPer100g: Double?

    /// Provenance, so the UI can be honest about where numbers came from.
    var source: Source = .dataset

    enum Source: String, Codable {
        case dataset, barcode, label, ai, custom

        var label: String {
            switch self {
            case .dataset: "USDA"
            case .barcode: "Barcode"
            case .label: "Label scan"
            case .ai: "AI estimate"
            case .custom: "Custom"
            }
        }
        var icon: String {
            switch self {
            case .dataset: "checkmark.seal.fill"
            case .barcode: "barcode.viewfinder"
            case .label: "doc.text.viewfinder"
            case .ai: "sparkles"
            case .custom: "square.and.pencil"
            }
        }
    }

    // MARK: - Portion math

    func calories(forGrams g: Double) -> Double { kcalPer100g / 100 * g }

    private func scaled(_ per100: Double?, _ g: Double) -> Double? {
        per100.map { $0 / 100 * g }
    }

    func protein(forGrams g: Double) -> Double? { scaled(proteinPer100g, g) }
    func fat(forGrams g: Double) -> Double? { scaled(fatPer100g, g) }
    func carbs(forGrams g: Double) -> Double? { scaled(carbsPer100g, g) }
    func fiber(forGrams g: Double) -> Double? { scaled(fiberPer100g, g) }
    func sugars(forGrams g: Double) -> Double? { scaled(sugarsPer100g, g) }
    func sodiumMg(forGrams g: Double) -> Double? { scaled(sodiumMgPer100g, g) }
    func saturatedFat(forGrams g: Double) -> Double? { scaled(saturatedFatPer100g, g) }

    var hasMicros: Bool {
        fiberPer100g != nil || sugarsPer100g != nil
            || sodiumMgPer100g != nil || saturatedFatPer100g != nil
    }
}

// MARK: - Diary

/// One logged portion of food.
struct DiaryEntry: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    let foodId: String
    let foodName: String
    let grams: Double
    let calories: Double
    let date: Date
    var protein: Double?
    var fat: Double?
    var carbs: Double?
    var meal: Meal = .other

    enum Meal: String, Codable, CaseIterable, Identifiable {
        case breakfast, lunch, dinner, snack, other
        var id: String { rawValue }

        var label: String {
            switch self {
            case .breakfast: "Breakfast"
            case .lunch: "Lunch"
            case .dinner: "Dinner"
            case .snack: "Snack"
            case .other: "Other"
            }
        }
        var icon: String {
            switch self {
            case .breakfast: "sunrise.fill"
            case .lunch: "sun.max.fill"
            case .dinner: "moon.stars.fill"
            case .snack: "carrot.fill"
            case .other: "fork.knife"
            }
        }

        /// Best guess from the time of day, so logging needs one less tap.
        static func inferred(from date: Date = Date()) -> Meal {
            switch Calendar.current.component(.hour, from: date) {
            case 4..<11: .breakfast
            case 11..<16: .lunch
            case 16..<22: .dinner
            default: .snack
            }
        }
    }

    init(food: Food, grams: Double, date: Date = Date(), meal: Meal? = nil) {
        self.foodId = food.id
        self.foodName = food.name
        self.grams = grams
        self.calories = food.calories(forGrams: grams)
        self.date = date
        self.protein = food.protein(forGrams: grams)
        self.fat = food.fat(forGrams: grams)
        self.carbs = food.carbs(forGrams: grams)
        self.meal = meal ?? .inferred(from: date)
    }

    init(foodId: String, foodName: String, grams: Double, calories: Double,
         date: Date = Date(), protein: Double? = nil, fat: Double? = nil,
         carbs: Double? = nil, meal: Meal? = nil) {
        self.foodId = foodId
        self.foodName = foodName
        self.grams = grams
        self.calories = calories
        self.date = date
        self.protein = protein
        self.fat = fat
        self.carbs = carbs
        self.meal = meal ?? .inferred(from: date)
    }
}

// MARK: - Weight

struct WeightEntry: Identifiable, Hashable, Codable {
    var id: String { Self.dayKey(date) }
    let date: Date
    let kg: Double

    static func dayKey(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Favorites & recipes

/// One day's water intake, accumulated as the user adds glasses.
struct WaterEntry: Identifiable, Hashable, Codable {
    var id: String { WeightEntry.dayKey(date) }
    let date: Date
    var ml: Double
}

struct FavoriteFood: Identifiable, Hashable, Codable {
    var id: String { food.id }
    let food: Food
    var lastGrams: Double
}

struct RecipeIngredient: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    let name: String
    let grams: Double
    let calories: Double
    var protein: Double?
    var fat: Double?
    var carbs: Double?
}

struct Recipe: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var ingredients: [RecipeIngredient]
    var servings: Int

    var totalCalories: Double { ingredients.reduce(0) { $0 + $1.calories } }
    var totalGrams: Double { ingredients.reduce(0) { $0 + $1.grams } }
    var totalProtein: Double { ingredients.reduce(0) { $0 + ($1.protein ?? 0) } }
    var totalFat: Double { ingredients.reduce(0) { $0 + ($1.fat ?? 0) } }
    var totalCarbs: Double { ingredients.reduce(0) { $0 + ($1.carbs ?? 0) } }

    private func per(_ total: Double) -> Double { servings > 0 ? total / Double(servings) : total }
    var perServingCalories: Double { per(totalCalories) }
    var perServingGrams: Double { per(totalGrams) }
    var perServingProtein: Double { per(totalProtein) }
    var perServingFat: Double { per(totalFat) }
    var perServingCarbs: Double { per(totalCarbs) }
}
