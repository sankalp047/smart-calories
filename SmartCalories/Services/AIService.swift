import Foundation
import Security

enum AIError: LocalizedError {
    case http(Int, String)
    case decoding(String)
    case emptyInput(String)
    case quota(String)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):
            code >= 500
                ? "The AI service is unavailable right now. Try again in a moment."
                : "AI request failed (\(code)). \(body.prefix(140))"
        case .decoding(let detail): "Couldn't read the AI response. \(detail)"
        case .emptyInput(let message): message
        case .quota(let message): message
        }
    }
}

/// Nutrition and training intelligence.
///
/// Deliberately holds **no API key**. Requests go to our own Cloud Function,
/// which owns the provider credential, enforces a per-device daily quota and
/// pins the system prompts server-side. An earlier build embedded the key in
/// the binary, where `strings` recovered it in seconds — this exists so that
/// can't happen again.
///
/// Note the division of labour for label scanning: OCR runs on-device in
/// `OCRService` (Vision), so photos never leave the phone — only the extracted
/// text is sent here to be structured.
struct AIService {

    /// Our Cloudflare Worker (see `worker/`). It owns the provider credential;
    /// this app never holds one. Redeploy with `cd worker && npx wrangler deploy`.
    private static let endpointURL = Secrets.backendBaseURL

    private var endpoint: URL { URL(string: Self.endpointURL)! }

    /// True once the placeholder above has been replaced, so the UI can give a
    /// clear message instead of a confusing network error.
    static var isConfigured: Bool { !endpointURL.contains("YOUR-SUBDOMAIN") }

    // MARK: - Public operations

    func parseNutritionLabel(ocrText: String) async throws -> Food {
        guard !ocrText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyInput(
                "No text was readable in that photo. Try again with the label flat and well lit.")
        }
        let json = try await callJSON(operation: "parseLabel",
                                      input: "OCR text:\n\"\"\"\n\(ocrText)\n\"\"\"")
        return try food(from: json, source: .label)
    }

    func lookupFood(_ query: String) async throws -> Food {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.emptyInput("Type a food to look up.")
        }
        // Fast path: on-device model. Free, private, works offline. Falls
        // through to the cloud if the device can't run it or the answer fails
        // the plausibility check.
        if let local = await OnDeviceAI.lookupFood(query) { return local }

        let json = try await callJSON(operation: "lookupFood", input: "Food: \"\(query)\"")
        return try food(from: json, source: .ai)
    }

    func suggestMeal(remainingKcal: Double, remainingProtein: Double?, goal: String) async throws -> String {
        if let local = await OnDeviceAI.suggestMeal(
            remainingKcal: remainingKcal, remainingProtein: remainingProtein, goal: goal) {
            return local
        }
        var input = "Calories left today: \(Int(remainingKcal)) kcal. Goal: \(goal)."
        if let remainingProtein, remainingProtein > 0 {
            input += " They could still use about \(Int(remainingProtein)) g of protein."
        }
        return try await callText(operation: "suggestMeal", input: input)
    }

    func weeklyInsight(summary: String) async throws -> String {
        if let local = await OnDeviceAI.weeklyInsight(summary: summary) { return local }
        return try await callText(operation: "weeklyInsight", input: summary)
    }

    func generateWorkout(goal: String, level: String, sex: String,
                         context: String, equipment: [String]?) async throws -> WorkoutPlan {
        var input = "Goal: \(goal). Experience level: \(level). Sex: \(sex). About them: \(context)."
        if let equipment, !equipment.isEmpty {
            input += " Available equipment: \(equipment.joined(separator: ", "))."
        }
        let json = try await callJSON(operation: "generateWorkout", input: input)
        return try WorkoutPlan(aiJSON: json, goal: goal)
    }

    // MARK: - Transport

    private func callJSON(operation: String, input: String) async throws -> [String: Any] {
        let content = try await call(operation: operation, input: input)
        guard let data = content.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AIError.decoding("Response wasn't valid JSON.") }
        return object
    }

    private func callText(operation: String, input: String) async throws -> String {
        try await call(operation: operation, input: input)
    }

    private func call(operation: String, input: String) async throws -> String {
        guard Self.isConfigured else {
            throw AIError.emptyInput(
                "AI isn't set up yet. Deploy the worker and set its URL in AIService.swift.")
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["operation": operation, "input": input])
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard status == 200 else {
            let message = (payload?["error"] as? String) ?? String(data: data, encoding: .utf8) ?? ""
            if status == 429 { throw AIError.quota(message) }
            throw AIError.http(status, message)
        }
        guard let content = payload?["content"] as? String else {
            throw AIError.decoding("Unexpected response shape.")
        }
        return content
    }

    // MARK: - Mapping

    private func food(from json: [String: Any], source: Food.Source) throws -> Food {
        func number(_ key: String) -> Double? {
            if let d = json[key] as? Double { return d }
            if let i = json[key] as? Int { return Double(i) }
            if let s = json[key] as? String { return Double(s) }
            return nil
        }
        guard let kcal = number("calories_per_100g"), kcal > 0 else {
            let notes = json["notes"] as? String
            throw AIError.emptyInput(
                notes?.isEmpty == false ? notes! : "Couldn't determine calories for that item.")
        }
        return Food(
            id: "\(source.rawValue)_\(UUID().uuidString.prefix(8))",
            name: (json["name"] as? String)?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? "Scanned item",
            category: source == .ai ? "AI lookup" : "Packaged",
            kcalPer100g: kcal,
            proteinPer100g: number("protein_per_100g"),
            fatPer100g: number("fat_per_100g"),
            carbsPer100g: number("carbs_per_100g"),
            fiberPer100g: number("fiber_per_100g"),
            sugarsPer100g: number("sugars_per_100g"),
            sodiumMgPer100g: number("sodium_mg_per_100g"),
            saturatedFatPer100g: number("saturated_fat_per_100g"),
            source: source
        )
    }
}

// MARK: - Device identity

/// A stable, anonymous per-install identifier used for server-side quotas.
/// Kept in the Keychain so it survives app updates, and carries no personal
/// information — it's a random UUID, not a hardware id.
enum DeviceIdentity {
    private static let account = "com.sankalpsingh.smartcalories.deviceId"

    static let current: String = {
        if let existing = read() { return existing }
        let fresh = UUID().uuidString
        write(fresh)
        return fresh
    }()

    private static func read() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    private static func write(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
