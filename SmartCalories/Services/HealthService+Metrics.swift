import Foundation
import HealthKit

/// The KPI and calibration reads: daily series for cross-device pairing,
/// overnight vitals, and fitness markers. All best-effort — every value is
/// optional and a denial or absent device just leaves it nil.
extension HealthService {

    func refreshExtendedMetrics() async {
        let bpm = HKUnit.count().unitDivided(by: .minute())

        dailyActiveEnergy = await dailySeries(
            .activeEnergyBurned, unit: .kilocalorie(), days: 30, options: .cumulativeSum)
        dailyRestingHR = await dailySeries(
            .restingHeartRate, unit: bpm, days: 30, options: .discreteAverage)
        dailySDNN = await dailySeries(
            .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), days: 14,
            options: .discreteAverage)

        vo2Max = await latestQuantity(
            .vo2Max, unit: HKUnit(from: "ml/kg*min"), withinDays: 60)
        hrRecovery = await latestQuantity(
            .heartRateRecoveryOneMinute, unit: bpm, withinDays: 30)
        walkingHRAverage = await latestQuantity(
            .walkingHeartRateAverage, unit: bpm, withinDays: 7)
        respiratoryRate = await overnightAverage(.respiratoryRate, unit: bpm)

        // Wrist temperature is only meaningful as a deviation from the
        // wearer's own baseline — absolute skin temp varies person to person.
        let temps = await dailySeries(
            .appleSleepingWristTemperature, unit: .degreeCelsius(), days: 30,
            options: .discreteAverage)
        if let latest = temps.last, temps.count >= 8 {
            let priors = temps.dropLast().map(\.value).sorted()
            let median = priors[priors.count / 2]
            wristTempDeltaC = latest.value - median
        } else {
            wristTempDeltaC = nil
        }

        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        standMinutesToday = await sum(
            .appleStandTime, unit: .minute(), from: startOfToday, to: Date())
        flightsToday = Int(await sum(
            .flightsClimbed, unit: .count(), from: startOfToday, to: Date()))

        sleepStages = await stagesLastNight()
    }

    // MARK: - Series

    /// One value per day over the trailing window, via a single collection
    /// query rather than a query per day. Days with no data are omitted.
    private func dailySeries(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit, days: Int,
        options: HKStatisticsOptions
    ) async -> [DailyMetric] {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return [] }
        let cal = Calendar.current
        let anchor = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -(days - 1), to: anchor) else { return [] }
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: type, quantitySamplePredicate: predicate,
                options: options, anchorDate: anchor, intervalComponents: DateComponents(day: 1)
            )
            query.initialResultsHandler = { _, collection, _ in
                var series: [DailyMetric] = []
                collection?.enumerateStatistics(from: start, to: Date()) { stats, _ in
                    let quantity = options == .cumulativeSum
                        ? stats.sumQuantity() : stats.averageQuantity()
                    if let quantity {
                        series.append(DailyMetric(
                            date: stats.startDate, value: quantity.doubleValue(for: unit)))
                    }
                }
                continuation.resume(returning: series)
            }
            store.execute(query)
        }
    }

    /// Most recent single sample within the window — for slow-moving markers
    /// like VO₂max where "the latest measurement" is the right read.
    private func latestQuantity(
        _ id: HKQuantityTypeIdentifier, unit: HKUnit, withinDays days: Int
    ) async -> Double? {
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let start = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: Date(), options: [])

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: 1,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]
            ) { _, samples, _ in
                let value = (samples?.first as? HKQuantitySample)?
                    .quantity.doubleValue(for: unit)
                continuation.resume(returning: value)
            }
            store.execute(query)
        }
    }

    /// Average over the last-night window (6 pm → noon) — the read for
    /// vitals the Watch measures during sleep.
    private func overnightAverage(_ id: HKQuantityTypeIdentifier, unit: HKUnit) async -> Double? {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .hour, value: -6, to: startOfToday),
              let windowEnd = cal.date(byAdding: .hour, value: 12, to: startOfToday)
        else { return nil }
        guard let type = HKQuantityType.quantityType(forIdentifier: id) else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])

        return await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type, quantitySamplePredicate: predicate, options: .discreteAverage
            ) { _, stats, _ in
                continuation.resume(returning: stats?.averageQuantity()?.doubleValue(for: unit))
            }
            store.execute(query)
        }
    }

    /// Last night's stage breakdown from the same window sleepMinutesLastNight
    /// uses, bucketed by stage value.
    private func stagesLastNight() async -> SleepStages? {
        guard let type = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return nil }
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .hour, value: -6, to: startOfToday),
              let windowEnd = cal.date(byAdding: .hour, value: 12, to: startOfToday)
        else { return nil }
        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: [])

        let samples: [HKCategorySample] = await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                sortDescriptors: nil
            ) { _, results, _ in
                continuation.resume(returning: (results as? [HKCategorySample]) ?? [])
            }
            store.execute(query)
        }
        guard !samples.isEmpty else { return nil }

        var stages = SleepStages(remMinutes: 0, coreMinutes: 0, deepMinutes: 0, awakeMinutes: 0)
        var sawStages = false
        for sample in samples {
            let minutes = sample.endDate.timeIntervalSince(sample.startDate) / 60
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .asleepREM: stages.remMinutes += minutes; sawStages = true
            case .asleepCore: stages.coreMinutes += minutes; sawStages = true
            case .asleepDeep: stages.deepMinutes += minutes; sawStages = true
            case .awake: stages.awakeMinutes += minutes
            default: break
            }
        }
        // A source that only logs "asleep" gives no stage information —
        // return nil rather than an all-zero chart.
        return sawStages ? stages : nil
    }
}
