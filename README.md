# Smart Calories

Nutrition and body-composition tracking for iPhone, Apple Watch and the Home Screen.
Native SwiftUI, built as a ground-up replacement for a Flutter app of the same
product.

**64 Swift files · ~13,300 lines · zero third-party dependencies.**

Open `SmartCalories.xcodeproj` and run. iOS 26, watchOS 10.

```bash
cp SmartCalories/Services/Secrets.swift.example SmartCalories/Services/Secrets.swift
```

`Secrets.swift` holds the backend base URL and is gitignored. The backend is a thin
proxy — it structures OCR'd label text, exchanges Apple identity tokens for a session,
and ingests heart-rate samples — so any host implementing those routes works. Without
it the app builds; the features that need a network round-trip don't.

---

## Zero dependencies is the architecture, not a brag

Every import in this project is an Apple framework. No SPM packages, no CocoaPods,
no Carthage, no `Package.swift`. That constraint did most of the design work:

| Concern | The Flutter build | Here |
|---|---|---|
| Dependencies | 19 pub packages + 54 CocoaPods | **0** |
| State | `provider` + `ChangeNotifier` | `@Observable` (Observation) |
| Persistence | plugin-backed boxes | JSON in Application Support |
| Bluetooth | `flutter_blue_plus` | CoreBluetooth |
| OCR | Google ML Kit (bundled model) | Vision, on-device |
| Barcode | `mobile_scanner` | AVFoundation |
| Health | `health` plugin bridge | HealthKit directly |
| Charts | hand-drawn `CustomPaint` | Swift Charts |
| Build | `pod install`, dependency cycles | plain `xcodebuild` |

The downstream consequences are the interesting part. Choosing `@Observable` over
Combine means there is no publisher graph to reason about and views re-render
narrowly, because each view reads only the properties it touches. Choosing plain
JSON over Core Data means no managed-object contexts, no migrations, and a `Store`
layer small enough to read in one sitting — the trade is that it would not survive
hundreds of thousands of rows, which this product does not have.

`AppEnvironment` is the single shared observable. Nothing else is global.

Three targets share one `Shared/` folder: the app, a WidgetKit extension (Home
Screen widget + a Live Activity for live scale readings), and a watchOS app that
streams heart rate back to the phone over `WatchConnectivity`.

---

## Pairing a Bluetooth scale that documents nothing

Kitchen scales almost never implement the standard BLE Weight Scale profile. They
push weight over a vendor characteristic in an undocumented byte layout, and that
layout differs per manufacturer.

The usual approach is to hard-code one vendor and ship support for one scale. Instead
the decoder is **data**, not code:

```swift
struct ScaleDecoderConfig: Codable, Equatable {
    var weightOffset: Int        // where the weight field starts
    var weightLength: Int        // how wide it is
    var littleEndian: Bool
    var divisor: Double          // raw integer ÷ divisor = displayed value
    var defaultUnit: WeightUnit
    var signedTwosComplement: Bool
    // optional dedicated stability / unit flag bytes, when a scale exposes them
}
```

Which turns "support this scale" into "find six numbers." The app finds them itself.
It subscribes to *every* notifying characteristic it discovers, keeps a rolling log of
raw frames, and then asks the user for two known weights. `ScaleDecoder.solveTwoPoint`
brute-forces plausible field offsets, 2- and 3-byte widths, and both endiannesses,
keeping the candidate whose implied divisor agrees across both samples to within 3%:

```swift
let dA = Double(a) / valueA      // divisor implied by sample A
let dB = Double(b) / valueB      // divisor implied by sample B
guard abs(dA - dB) / dA <= 0.03 else { continue }
```

Two samples are enough because a wrong guess at offset or endianness produces two
*wildly* disagreeing divisors, while the correct one produces near-identical ones.
The derived divisor then snaps to the decimal factors scales actually use
(1, 10, 100, 1000). Ties prefer 2-byte fields, which are overwhelmingly more common.

A user pairs a scale the app has never seen in about twenty seconds, without touching
a byte by hand.

The shipped default was recovered from a physical Etekcity ESN00 — service `0x1910`,
characteristic `0x2C12`, big-endian `UInt16` at byte 7, in tenths of a gram. Verified
against a 38 g load: bytes `01 7C` = 0x017C = 380 → 38.0 g.

---

## Learning what maintenance calories actually are

Mifflin–St Jeor predicts the average person of your height, weight, age and sex. Real
individuals sit routinely 300+ kcal either side of it, and the formula never learns.

But energy balance is directly observable. If someone eats 2,400 kcal a day and their
weight holds, their true expenditure *is* 2,400 — whatever the equation claims. So the
app solves for it:

```
TDEE = mean daily intake − (weight change in kg × 7,700 kcal ⁄ days)
```

Three things keep that honest rather than noisy:

- **Only logged days count.** A skipped day isn't a zero-calorie day; averaging zeros
  in would manufacture a deficit. Days under 400 kcal are treated as partial and
  dropped.
- **Implausible results are rejected.** Outside 1,000–6,000 kcal it's a mistyped
  weight or a week of unlogged meals, not metabolism.
- **Confidence weighting.** Days logged, weigh-in count and span covered each
  saturate at 1, and the *weakest* dominates — a month of logging is still worthless
  with a single weigh-in. The result blends toward the formula when evidence is thin,
  so the number degrades gracefully instead of lying confidently.

### The 110 kcal/day bug

The first version fitted the weight trend to the exponentially-smoothed series,
which seemed obviously right: bodyweight swings ±1.5 kg on water and glycogen, so
smooth it first.

It was wrong, and a known-answer test is what caught it.

An EMA lags by construction. That lag flattens the fitted slope toward zero, which
understates the deficit, which hands back a maintenance figure that is too *low* —
about 110 kcal/day too low in the test scenario. Acted on, that compounds: a target
set 110 kcal under true maintenance stalls the very progress it's meant to produce.

The fix is that least squares is *already* a noise-robust, unbiased estimator on raw
weigh-ins. Smoothing before fitting doesn't reduce noise, it introduces bias. The EMA
stayed — but only for drawing a readable trend line, never for the slope.

```
Scenario: 2,500 kcal/day intake, 0.5 kg/week loss, ±0.4 kg water noise,
          weighed every other day for 28 days.
Physiology: 0.5 kg/week = 550 kcal/day deficit → true maintenance = 3,050 kcal.

Formula (Mifflin–St Jeor) : 2,836 kcal   ← underestimates by 214
Recovered from data       : 3,055 kcal   ← within 5 of the known answer
Confidence                : 100%
Weekly trend              : −0.50 kg
```

---

## Tests

The math has no UI and no app types, so it doesn't need a simulator. Each test is a
`main.swift` compiled directly against the sources it exercises:

```bash
cd Tests && ./run.sh
```

63 assertions across adaptive energy, heart-rate energy estimation, cross-device
calibration, readiness scoring, CSV sample archiving and chart bucketing. All
known-answer: every assertion states a value physiology or arithmetic says must come
out, not whatever the code happened to produce.

The cross-device calibration is worth a look (`CalibrationMath.swift`). Mapping a
chest-strap-derived energy estimate onto Apple Watch's scale is a regression where
*both* sides carry error, so ordinary least squares attenuates. It uses a trimmed
ratio-of-sums with MAD outlier screening and shrinkage toward 1.0 weighted `n/(n+6)`,
so a handful of odd days can't produce an extreme factor — the data has to earn its
influence.

---

## Privacy

- **Label scanning runs OCR on-device** via Vision. Only the extracted *text* is sent
  for structuring; the photo never leaves the phone.
- On-device language-model features are gated behind `canImport(FoundationModels)`
  *and* a runtime availability check, so the app degrades cleanly on hardware without
  Apple Intelligence rather than requiring it.
- All user data is stored locally as JSON in Application Support.
- Nutrition data: USDA SR28 (3,176 foods, bundled) and Open Food Facts for barcodes.

---

## Development affordance

Launch straight to any tab for UI review:

```bash
xcrun simctl spawn booted defaults write com.sankalpsingh.smartcalories startTab -string foods
```

Values: `today`, `foods`, `scale`, `workouts`, `health`. Delete the key to reset.
