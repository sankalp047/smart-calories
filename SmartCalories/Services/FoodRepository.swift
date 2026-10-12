import Foundation
import Observation

/// Loads the bundled USDA dataset and provides ranked search.
/// Parsing happens off the main thread; results are published back on it.
@MainActor
@Observable
final class FoodRepository {

    private(set) var foods: [Food] = []
    private(set) var isLoaded = false
    /// Categories ordered by how many foods they contain (most useful first).
    private(set) var categories: [String] = []

    func load() async {
        guard !isLoaded else { return }
        let parsed = await Task.detached(priority: .userInitiated) {
            Self.parseBundledCSV()
        }.value

        foods = parsed
        categories = Self.rankedCategories(from: parsed)
        isLoaded = true
    }

    // MARK: - Search

    /// Ranked, case-insensitive search. Prefix and word-boundary matches float
    /// to the top, and shorter names win ties so the plain form of a food
    /// ("Rice, white") outranks a long branded variant.
    func search(_ query: String, category: String? = nil, limit: Int = 80) -> [Food] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        let pool = category.map { cat in foods.filter { $0.category == cat } } ?? foods

        guard !q.isEmpty else {
            return Array(pool.sorted { $0.name < $1.name }.prefix(limit))
        }

        var scored: [(food: Food, score: Int)] = []
        scored.reserveCapacity(256)

        for food in pool {
            let name = food.name.lowercased()
            guard let range = name.range(of: q) else { continue }
            let idx = name.distance(from: name.startIndex, to: range.lowerBound)

            var score = idx
            if idx == 0 { score -= 1000 }                       // prefix match
            else if name[name.index(before: range.lowerBound)] == " " { score -= 100 }  // word start
            score += name.count / 20                            // prefer concise names
            scored.append((food, score))
        }

        return scored
            .sorted { $0.score != $1.score ? $0.score < $1.score : $0.food.name < $1.food.name }
            .prefix(limit)
            .map(\.food)
    }

    func food(withId id: String) -> Food? { foods.first { $0.id == id } }

    // MARK: - CSV parsing

    private nonisolated static func parseBundledCSV() -> [Food] {
        guard let url = Bundle.main.url(forResource: "foods", withExtension: "csv"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return [] }

        var result: [Food] = []
        result.reserveCapacity(3200)

        // Split on any newline flavour. Note: `split(separator: "\n")` would find
        // nothing here — the dataset uses CRLF, and Swift treats "\r\n" as a
        // single grapheme cluster that doesn't equal "\n".
        let lines = text.split(whereSeparator: \.isNewline)

        // Columns: id, name, category, kcal/100g, kcal/g, protein, fat, carbs, fiber, sugars
        for line in lines.dropFirst() {
            let cols = splitCSVLine(String(line))
            guard cols.count >= 5, let kcal = Double(cols[3]) else { continue }

            result.append(
                Food(
                    id: cols[0],
                    name: cols[1],
                    category: cols[2],
                    kcalPer100g: kcal,
                    proteinPer100g: cols.count > 5 ? Double(cols[5]) : nil,
                    fatPer100g: cols.count > 6 ? Double(cols[6]) : nil,
                    carbsPer100g: cols.count > 7 ? Double(cols[7]) : nil,
                    fiberPer100g: cols.count > 8 ? Double(cols[8]) : nil,
                    sugarsPer100g: cols.count > 9 ? Double(cols[9]) : nil,
                    source: .dataset
                )
            )
        }
        return result
    }

    /// Minimal RFC-4180 splitter — food names contain commas inside quotes.
    private nonisolated static func splitCSVLine(_ line: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var iterator = line.makeIterator()

        while let ch = iterator.next() {
            switch ch {
            case "\"":
                inQuotes.toggle()
            case "," where !inQuotes:
                fields.append(current)
                current = ""
            case "\r":
                continue
            default:
                current.append(ch)
            }
        }
        fields.append(current)
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private nonisolated static func rankedCategories(from foods: [Food]) -> [String] {
        var counts: [String: Int] = [:]
        for f in foods where !f.category.isEmpty {
            counts[f.category, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}
