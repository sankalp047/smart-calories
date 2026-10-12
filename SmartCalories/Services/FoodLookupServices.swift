import Foundation
import Vision
import UIKit

// MARK: - Barcode lookup

/// Resolves a scanned barcode against Open Food Facts (free, no key required).
struct OpenFoodFactsService {

    func lookup(barcode: String) async throws -> Food? {
        let fields = "product_name,brands,serving_quantity,nutriments"
        guard let url = URL(string:
            "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(fields)")
        else { return nil }

        var request = URLRequest(url: url)
        request.setValue("SmartCalories/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["status"] as? Int == 1,
              let product = root["product"] as? [String: Any]
        else { return nil }

        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        func value(_ key: String) -> Double? {
            if let d = nutriments[key] as? Double { return d }
            if let i = nutriments[key] as? Int { return Double(i) }
            if let s = nutriments[key] as? String { return Double(s) }
            return nil
        }

        // Without an energy value there's nothing useful to log.
        guard let kcal = value("energy-kcal_100g"), kcal > 0 else { return nil }

        let name = [product["brands"] as? String, product["product_name"] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces).nilIfEmpty }
            .joined(separator: " · ")

        return Food(
            id: "off_\(barcode)",
            name: name.nilIfEmpty ?? "Scanned product",
            category: "Packaged",
            kcalPer100g: kcal,
            proteinPer100g: value("proteins_100g"),
            fatPer100g: value("fat_100g"),
            carbsPer100g: value("carbohydrates_100g"),
            fiberPer100g: value("fiber_100g"),
            sugarsPer100g: value("sugars_100g"),
            // Open Food Facts reports sodium in grams.
            sodiumMgPer100g: value("sodium_100g").map { $0 * 1000 },
            saturatedFatPer100g: value("saturated-fat_100g"),
            source: .barcode
        )
    }
}

// MARK: - On-device OCR

/// Reads text from a nutrition-label photo using Vision — entirely on-device,
/// so label images never leave the phone. Only the extracted text is later sent
/// for structuring.
struct OCRService {

    enum OCRError: LocalizedError {
        case badImage
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .badImage: "That image couldn't be read."
            case .failed(let m): m
            }
        }
    }

    func recognizeText(in image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRError.badImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: OCRError.failed(error.localizedDescription))
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation] ?? []
                let text = observations
                    .compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false   // nutrition panels are mostly numbers

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(throwing: OCRError.failed(error.localizedDescription)) }
            }
        }
    }
}
