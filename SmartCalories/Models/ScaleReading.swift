import Foundation

/// Unit shown on the scale's own display. Kitchen scales cycle these with a
/// UNIT button; volume modes assume water vs. milk density.
enum WeightUnit: String, Codable, CaseIterable, Identifiable {
    case grams, ounces, milliliters, milkMilliliters
    var id: String { rawValue }

    var label: String {
        switch self {
        case .grams: "g"
        case .ounces: "oz"
        case .milliliters: "ml"
        case .milkMilliliters: "ml milk"
        }
    }

    /// Multiplier to convert a display value into grams.
    var gramsPerUnit: Double {
        switch self {
        case .grams: 1
        case .ounces: 28.349523125
        case .milliliters: 1.0        // water ≈ 1 g/ml
        case .milkMilliliters: 1.03   // milk ≈ 1.03 g/ml
        }
    }

    /// Decimal places the scale typically shows for this unit.
    var fractionDigits: Int { self == .grams ? 0 : 1 }
}

/// One decoded weight sample.
struct ScaleReading: Equatable {
    let value: Double
    let unit: WeightUnit
    let isStable: Bool
    let isNegative: Bool
    let timestamp: Date
    let rawFrame: [UInt8]

    var signedValue: Double { isNegative ? -value : value }

    /// Normalized to grams so calorie math only ever deals in one unit.
    var grams: Double { signedValue * unit.gramsPerUnit }

    var display: String {
        String(format: "%.\(unit.fractionDigits)f", signedValue)
    }
}

/// Every knob needed to interpret a raw BLE weight frame.
///
/// The scale's protocol is not publicly documented, so rather than hard-coding
/// one vendor's layout, the app carries a *configurable* decoder that the
/// calibration flow solves for. That's what makes it work across scales.
struct ScaleDecoderConfig: Codable, Equatable {
    var label: String = "Default"
    /// Byte index where the weight field starts.
    var weightOffset: Int = 0
    /// Width of the weight field in bytes.
    var weightLength: Int = 2
    var littleEndian: Bool = true
    /// Raw integer ÷ divisor = displayed value (e.g. tenths of a gram → 10).
    var divisor: Double = 10
    var defaultUnit: WeightUnit = .grams
    var signedTwosComplement: Bool = true
    /// Optional dedicated flag bytes, when a scale exposes them.
    var stableOffset: Int?
    var stableMask: UInt8 = 0x01
    var unitOffset: Int?
    var unitMap: [String: WeightUnit] = [:]

    /// Recovered from a physical Etekcity ESN00 (service 0x1910, characteristic
    /// 0x2C12): big-endian UInt16 at byte 7, in tenths of a gram. Verified
    /// against a 38 g load → bytes `01 7C` = 0x017C = 380 → 38.0 g.
    /// Any other scale is handled by re-running calibration.
    static let esn00 = ScaleDecoderConfig(
        label: "Etekcity ESN00",
        weightOffset: 7,
        weightLength: 2,
        littleEndian: false,
        divisor: 10,
        defaultUnit: .grams,
        signedTwosComplement: true
    )
}

enum ScaleDecoder {

    /// Decode one BLE notification payload into a reading.
    static func decode(_ bytes: [UInt8], config c: ScaleDecoderConfig) -> ScaleReading? {
        guard c.weightLength > 0,
              c.weightOffset >= 0,
              bytes.count >= c.weightOffset + c.weightLength,
              c.divisor != 0
        else { return nil }

        var raw = extractSigned(bytes, offset: c.weightOffset,
                                length: c.weightLength, littleEndian: c.littleEndian,
                                signed: c.signedTwosComplement)

        var negative = false
        if raw < 0 {
            negative = true
            raw = -raw
        }

        var unit = c.defaultUnit
        if let uo = c.unitOffset, uo < bytes.count,
           let mapped = c.unitMap[String(bytes[uo])] {
            unit = mapped
        }

        var stable = false
        if let so = c.stableOffset, so < bytes.count {
            stable = (bytes[so] & c.stableMask) != 0
        }

        return ScaleReading(
            value: abs(Double(raw) / c.divisor),
            unit: unit,
            isStable: stable,
            isNegative: negative,
            timestamp: Date(),
            rawFrame: bytes
        )
    }

    /// Solve the frame layout from two captured frames at two known displayed
    /// weights. This is what lets a user pair an unknown scale in ~20 seconds
    /// without touching a single byte by hand.
    ///
    /// Brute-forces plausible offset/width/endianness combinations and keeps the
    /// candidate whose implied divisor is most consistent across both samples.
    static func solveTwoPoint(
        frameA: [UInt8], valueA: Double,
        frameB: [UInt8], valueB: Double,
        unit: WeightUnit
    ) -> ScaleDecoderConfig? {
        guard valueA > 0, valueB > 0, valueA != valueB else { return nil }
        let maxLen = min(frameA.count, frameB.count)

        var best: ScaleDecoderConfig?
        var bestError = Double.infinity

        for length in [2, 3] {
            guard length <= maxLen else { continue }
            for offset in 0...(maxLen - length) {
                for littleEndian in [false, true] {
                    let a = extractSigned(frameA, offset: offset, length: length,
                                          littleEndian: littleEndian, signed: true)
                    let b = extractSigned(frameB, offset: offset, length: length,
                                          littleEndian: littleEndian, signed: true)
                    guard a > 0, b > 0 else { continue }

                    // Both samples must imply the same scale factor.
                    let dA = Double(a) / valueA
                    let dB = Double(b) / valueB
                    let relativeError = abs(dA - dB) / dA
                    guard relativeError <= 0.03 else { continue }

                    // Prefer 2-byte fields on ties; they're overwhelmingly common.
                    let error = relativeError + (length == 2 ? 0 : 0.001)
                    guard error < bestError else { continue }

                    bestError = error
                    best = ScaleDecoderConfig(
                        label: "Calibrated (\(unit.label))",
                        weightOffset: offset,
                        weightLength: length,
                        littleEndian: littleEndian,
                        divisor: niceDivisor((Double(a) + Double(b)) / (valueA + valueB)),
                        defaultUnit: unit,
                        signedTwosComplement: true
                    )
                }
            }
        }
        return best
    }

    // MARK: - Bit twiddling

    private static func extractSigned(
        _ bytes: [UInt8], offset: Int, length: Int,
        littleEndian: Bool, signed: Bool
    ) -> Int {
        guard offset >= 0, length > 0, bytes.count >= offset + length else { return 0 }
        var raw = 0
        if littleEndian {
            for i in stride(from: length - 1, through: 0, by: -1) {
                raw = (raw << 8) | Int(bytes[offset + i])
            }
        } else {
            for i in 0..<length {
                raw = (raw << 8) | Int(bytes[offset + i])
            }
        }
        if signed {
            let bits = length * 8
            let signBit = 1 << (bits - 1)
            if raw >= signBit { raw -= (1 << bits) }
        }
        return raw
    }

    /// Snap a derived divisor to the common decimal factors scales actually use.
    private static func niceDivisor(_ d: Double) -> Double {
        for candidate in [1.0, 10.0, 100.0, 1000.0] where abs(d - candidate) / candidate < 0.1 {
            return candidate
        }
        return (d * 100).rounded() / 100
    }
}
