import Foundation
import HealthKit
import Observation

/// A day's activity, aggregated from HealthKit (Apple Watch / iPhone) with a
/// manual fallback so users without a wearable still get a complete picture.
struct DaySummary: Equatable {
    var date: Date = Date()
    var steps: Int = 0
    var activeEnergy: Double = 0
    var restingEnergy: Double = 0
    var exerciseMinutes: Double = 0
    var distanceMeters: Double = 0
    var restingHeartRate: Double?

    var totalEnergy: Double { activeEnergy + restingEnergy }
    var distanceKm: Double { distanceMeters / 1000 }
}

@MainActor
@Observable
final class HealthService {

    let store = HKHealthStore()   // shared with HealthService+Metrics

    private(set) var isAuthorized = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private(set) var today = DaySummary()
    private(set) var week: [DaySummary] = []

    /// Minutes actually asleep last night, from whatever wrote sleep to
    /// HealthKit (Apple Watch, WHOOP's app, Sleep Cycle, …). Nil when nothing
    /// recorded a night — never fabricated.
    private(set) var lastNightSleepMinutes: Double?

    /// Stage breakdown of last night, minutes. Only present when the source
    /// records stages (Apple Watch does).
    var sleepStages: SleepStages?

    // MARK: Cross-device & KPI series (Apple Watch via HealthKit)

    /// Daily Watch active energy / resting HR, ~30 days — the pairing data
    /// for cross-device calibration.
    var dailyActiveEnergy: [DailyMetric] = []
    var dailyRestingHR: [DailyMetric] = []
    /// Daily overnight HRV (SDNN, ms), ~14 days; last entry is the latest.
    var dailySDNN: [DailyMetric] = []

    var vo2Max: Double?
    var respiratoryRate: Double?
    /// Last night's wrist temperature vs the 30-day median, °C.
    var wristTempDeltaC: Double?
    var hrRecovery: Double?
    var walkingHRAverage: Double?
    var standMinutesToday: Double = 0
    var flightsToday: Int = 0

    struct DailyMetric: Identifiable, Equatable {
        var id: Date { date }
        let date: Date
        let value: Double
    }

    struct SleepStages: Equatable {
        var remMinutes: Double
        var coreMinutes: Double
        var deepMinutes: Double
        var awakeMinutes: Double
    }

    /// Manual activity entry, used when HealthKit isn't available/authorized.
    private(set) var manualActiveEnergy: Double = 0
    private(set) var manualSteps: Int = 0

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    private var readTypes: Set<HKObjectType> {
        var types = Set<HKObjectType>()
        if let t = HKQuantityType.quantityType(forIdentifier: .stepCount) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .appleExerciseTime) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) { types.insert(t) }
        if let t = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) { types.insert(t) }
        if let t = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(t) }
        // The KPI/calibration layer. Each is optional at runtime — a missing
        // type or a denial simply leaves its card empty.
        for id: HKQuantityTypeIdentifier in [
            .heartRateVariabilitySDNN, .vo2Max, .respiratoryRate,
            .appleSleepingWristTemperature, .heartRateRecoveryOneMinute,
            .walkingHeartRateAverage, .appleStandTime, .flightsClimbed
        ] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    /// Types we write back. Logging food here makes the app a good citizen of
    /// the ecosystem: the data shows up in Apple Health and any other app the
    /// user has authorised can read it.
    private var writeTypes: Set<HKSampleType> {
        var types = Set<HKSampleType>()
        for id: HKQuantityTypeIdentifier in [
            .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal,
            .dietaryCarbohydrates, .dietaryWater
        ] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        return types
    }

    // MARK: - Writing

    /// Mirror a logged food into Apple Health. Best-effort: a failure here must
    /// never block the user's own diary.
    func save(_ entry: DiaryEntry) async {
        guard isAvailable, isAuthorized else { return }

        var samples: [HKSample] = []
        func add(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit, _ value: Double?) {
            guard let value, value > 0, let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
            samples.append(
                HKQuantitySample(
                    type: type,
                    quantity: HKQuantity(unit: unit, doubleValue: value),
                    start: entry.date,
                    end: entry.date,
                    metadata: [HKMetadataKeyFoodType: entry.foodName]
                )
            )
        }

        add(.dietaryEnergyConsumed, .kilocalorie(), entry.calories)
        add(.dietaryProtein, .gram(), entry.protein)
        add(.dietaryFatTotal, .gram(), entry.fat)
        add(.dietaryCarbohydrates, .gram(), entry.carbs)

        guard !samples.isEmpty else { return }
        try? await store.save(samples)
    }

    func saveWater(ml: Double, at date: Date = Date()) async {
        guard isAvailable, isAuthorized, ml > 0,
              let type = HKQuantityType.quantityType(forIdentifier: .dietaryWater)
        else { return }
        let sample = HKQuantitySample(
            type: type,
            quantity: HKQuantity(unit: .literUnit(with: .milli), doubleValue: ml),
            start: date, end: date
        )
        try? await store.save(sample)
    }

    // MARK: - Authorization

    /// Restore authorization state on launch.
    ///
    /// HealthKit deliberately never reveals whether *read* access was granted —
    /// otherwise an app could infer a denial from missing data. So the most it
    /// will tell us is whether the permission sheet still needs showing.
    /// `.unnecessary` means the user has already been through it, which is
    /// exactly what we need to stop re-prompting on every launch.
    func restoreAuthorization() async {
        guard isAvailable else { return }
        let status = try? await store.statusForAuthorizationRequest(toShare: writeTypes, read: readTypes)
        guard status == .unnecessary else { return }
        isAuthorized = true
        await refresh()
    }

    func requestAuthorization() async {
        guard isAvailable else {
            errorMessage = "Health data isn't available on this device."
            return
        }
        do {
            try await store.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Manual fallback

    func setManual(steps: Int, activeEnergy: Double) {
        manualSteps = steps
        manualActiveEnergy = activeEnergy
        if !isAuthorized {
            today.steps = steps
            today.activeEnergy = activeEnergy
        }
    }

    // MARK: - Reads

    func refresh() async {
        guard isAvailable, isAuthorized else { return }
        isLoading = true
        defer { isLoading = false }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        today = await summary(from: startOfToday, to: Date())
        lastNightSleepMinutes = await sleepMinutesLastNight()
        await refreshExtendedMetrics()

        var days: [DaySummary] = []
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let dayStart = cal.date(byAdding: .day, value: -offset, to: startOfToday),
                  let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart)
            else { continue }
            var s = await summary(from: dayStart, to: min(dayEnd, Date()))
            s.date = dayStart
            days.append(s)
        }
        week = days
    }

    private func summary(from start: Date, to end: Date) async -> DaySummary {
        var summary = DaySummary(date: start)
        summary.steps = Int(await sum(.stepCount, unit: .count(), from: start, to: end))
        summary.activeEnergy = await sum(.activeEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        summary.restingEnergy = await sum(.basalEnergyBurned, unit: .kilocalorie(), from: start, to: end)
        summary.exerciseMinutes = await sum(.appleExerciseTime, unit: .minute(), from: start, to: end)
        summary.distanceMeters = await sum(.distanceWalkingRunning, unit: .meter(), from: start, to: end)
        summary.restingHeartRate = await average(.restingHeartRate,
                                                 unit: HKUnit.count().unitDivided(by: .minute()),
                                                 from: start, to: end)
        return summary
    }

    /// Total asleep time in the window from 6 pm yesterday to noon today —
    /// wide enough for shift sleepers, narrow enough to exclude naps from
    /// two nights ago. Overlapping samples (two sources recording the same
    /// night) are merged so the same hour isn't counted twice.
    private func sleepMinutesLastNight() async -> Double? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .hour, value: -6, to: startOfToday),
              let windowEnd = cal.date(byAdding: .hour, value: 12, to: startOfToday)
        else { return nil }

        let asleepValues = Set(
            HKCategoryValueSleepAnalysis.allAsleepValues.map(\.rawValue)
        )
        let predicate = HKQuery.predicateForSamples(
            withStart: windowStart, end: windowEnd, options: []
        )

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }

        let asleep = samples.filter { asleepValues.contains($0.value) }
        guard !asleep.isEmpty else { return nil }

        // Merge overlapping intervals before summing.
        var total: TimeInterval = 0
        var currentStart = asleep[0].startDate
        var currentEnd = asleep[0].endDate
        for sample in asleep.dropFirst() {
            if sample.startDate <= currentEnd {
                currentEnd = max(currentEnd, sample.endDate)
            } else {
                total += currentEnd.timeIntervalSince(currentStart)
                currentStart = sample.startDate
                currentEnd = sample.endDate
            }
        }
        total += currentEnd.timeIntervalSince(currentStart)
        return total / 60
    }

    func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                     from start: Date, to end: Date) async -> Double {
        await statistic(id, unit: unit, from: start, to: end, options: .cumulativeSum) { $0.sumQuantity() } ?? 0
    }

    private func average(_ id: HKQuantityTypeIdentifier, unit: HKUnit,
                         from start: Date, to end: Date) async -> Double? {
        await statistic(id, unit: unit, from: start, to: end, options: .discreteAverage) { $0.averageQuantity() }
    }

    private func statistic(
        _ id: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from start: Date,
        to end: Date,
        options: HKStatisticsOptions,
        extract: @escaping (HKStatistics) -> HKQuantity?
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: options
            ) { _, stats, _ in
                guard let stats, let quantity = extract(stats) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: quantity.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }
}
