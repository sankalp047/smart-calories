import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device intelligence via Apple's Foundation Models framework.
///
/// This runs the ~3B model behind Apple Intelligence directly on the phone:
/// no API key, no server round-trip, no per-request cost, and it works on a
/// plane. For a nutrition app that's close to ideal — the questions are small,
/// frequent, and personal.
///
/// It is deliberately *not* a replacement for the cloud model. A 3B model is
/// less reliable at strict structured output than a large hosted one, and it
/// only exists on Apple Intelligence hardware (iPhone 15 Pro and newer, iOS 26+).
/// So `AIService` treats this as a fast path and falls back to the Worker when
/// it's unavailable or returns something unusable.
enum OnDeviceAI {

    enum Availability: Equatable {
        case available
        case unsupportedOS
        case deviceNotEligible
        case intelligenceNotEnabled
        case modelNotReady

        var isAvailable: Bool { self == .available }

        /// Plain-language explanation for the UI.
        var reason: String {
            switch self {
            case .available: "Running on your device"
            case .unsupportedOS: "Needs iOS 26 or later"
            case .deviceNotEligible: "This iPhone doesn't support Apple Intelligence"
            case .intelligenceNotEnabled: "Turn on Apple Intelligence in Settings"
            case .modelNotReady: "The model is still downloading"
            }
        }
    }

    static var availability: Availability {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *) else { return .unsupportedOS }
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .intelligenceNotEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
        #else
        return .unsupportedOS
        #endif
    }

    // MARK: - Operations

    /// Estimate nutrition for a named food, entirely on-device.
    /// Returns nil when unavailable so the caller can fall back to the cloud.
    static func lookupFood(_ query: String) async -> Food? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), availability.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
            You are a nutrition database. Give typical values per 100 g of the \
            edible portion, using realistic USDA-like numbers. Respect the \
            cooked or raw state the user specifies. Do not invent precision you \
            don't have.
            """)
            let response = try await session.respond(
                to: "Nutrition facts for: \(query)",
                generating: GeneratedNutrition.self
            )
            return response.content.toFood()
        } catch {
            // Guardrails, context overflow, or an unusable answer — let the
            // caller decide whether to try the cloud.
            return nil
        }
        #else
        return nil
        #endif
    }

    /// Short coaching text. Failure returns nil so the caller can fall back.
    static func respond(instructions: String, prompt: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, *), availability.isAvailable else { return nil }
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    static func suggestMeal(remainingKcal: Double, remainingProtein: Double?, goal: String) async -> String? {
        var prompt = "Calories left today: \(Int(remainingKcal)) kcal. Goal: \(goal)."
        if let remainingProtein, remainingProtein > 0 {
            prompt += " About \(Int(remainingProtein)) g of protein still to hit."
        }
        return await respond(
            instructions: """
            You are a friendly nutrition coach. Suggest 2-3 specific, realistic \
            meals or snacks that fit the remaining calories and support the \
            user's goal. Keep it short — a simple list with a rough calorie \
            estimate each. Plain text, no headings.
            """,
            prompt: prompt
        )
    }

    static func weeklyInsight(summary: String) async -> String? {
        await respond(
            instructions: """
            You are a supportive nutrition coach. From this week of food logging, \
            give 2-4 short, specific, encouraging observations and one concrete \
            tip for next week. Plain text, concise, no headings.
            """,
            prompt: summary
        )
    }
}

// MARK: - Structured output

#if canImport(FoundationModels)

/// Type-safe structured generation. The `@Generable` macro derives a schema the
/// model is constrained to fill, which removes the whole class of "the model
/// returned prose instead of JSON" failures that plague hand-rolled prompting.
@available(iOS 26.0, *)
@Generable
struct GeneratedNutrition {
    @Guide(description: "A clean, specific name for the food")
    var name: String

    @Guide(description: "Calories (kcal) per 100 g of edible portion")
    var caloriesPer100g: Double

    @Guide(description: "Grams of protein per 100 g")
    var proteinPer100g: Double

    @Guide(description: "Grams of fat per 100 g")
    var fatPer100g: Double

    @Guide(description: "Grams of carbohydrate per 100 g")
    var carbsPer100g: Double

    @Guide(description: "How confident this estimate is, from 0 to 1")
    var confidence: Double
}

@available(iOS 26.0, *)
extension GeneratedNutrition {
    /// Convert to the app's food model, rejecting implausible output. A small
    /// model will occasionally hallucinate a number an order of magnitude off;
    /// nothing above ~900 kcal/100 g is physically possible (pure fat is 884).
    func toFood() -> Food? {
        guard caloriesPer100g > 0, caloriesPer100g <= 900 else { return nil }
        return Food(
            id: "ondevice_\(UUID().uuidString.prefix(8))",
            name: name.trimmingCharacters(in: .whitespaces).isEmpty ? "Food" : name,
            category: "On-device estimate",
            kcalPer100g: caloriesPer100g,
            proteinPer100g: max(0, proteinPer100g),
            fatPer100g: max(0, fatPer100g),
            carbsPer100g: max(0, carbsPer100g),
            source: .ai
        )
    }
}

#endif
