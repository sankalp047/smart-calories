import SwiftUI
import Charts

/// The full report: every KPI the app can compute, one scrolling page.
/// Organised as narrative sections — energy, weight, training, heart,
/// nutrition — each opening with its headline number and backing it with a
/// chart. Cards render only when their data exists; nothing is fabricated.
struct InsightsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    heroRow

                    SectionHeader(title: "Energy")
                    energySection

                    if env.weights.count >= 2 {
                        SectionHeader(title: "Weight")
                        weightSection
                    }

                    if !env.sessions.isEmpty {
                        SectionHeader(title: "Training")
                        trainingSection
                    }

                    if heartSectionHasData {
                        SectionHeader(title: "Heart")
                        heartSection
                    }

                    SectionHeader(title: "Nutrition")
                    nutritionSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Full report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await env.refreshHealth() }
        }
    }

    // MARK: - Hero

    private var heroRow: some View {
        HStack(spacing: 10) {
            heroTile("Calories left", "\(Int(max(0, env.remainingToday)))",
                     "of \(Int(env.calorieGoal))", Theme.Palette.accent)
            if env.heart.todayStrain >= 0.1 {
                heroTile("Strain", String(format: "%.1f", env.heart.todayStrain),
                         "of 21", Theme.Palette.burn)
            }
            if let readiness = env.readiness {
                heroTile("Readiness", "\(Int(readiness))%",
                         readiness >= 67 ? "push" : readiness >= 34 ? "steady" : "easy",
                         readiness >= 67 ? Theme.Palette.accent
                            : readiness >= 34 ? Theme.Palette.carbs : Theme.Palette.alert)
            }
        }
    }

    private func heroTile(_ label: String, _ value: String, _ sub: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased()).font(.eyebrow).kerning(0.8)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(value).font(.numeric(22)).foregroundStyle(tint)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(sub).font(.system(size: 10))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .glassCard(radius: Theme.Radius.md, padding: 12)
    }

    // MARK: - Energy

    private var energySection: some View {
        VStack(spacing: 10) {
            if let energy = env.energy, energy.isAdaptive, let profile = env.profile {
                kpiRow("Real maintenance", "\(Int(energy.tdee)) kcal",
                       String(format: "%+d vs the formula · %.0f%% confidence",
                              Int(energy.tdee - profile.tdee), energy.confidence * 100),
                       "brain.head.profile", Theme.Palette.accent)
            }
            if let unlogged = env.unloggedIntakeEstimate {
                kpiRow("Unlogged intake", "~\(Int((unlogged / 50).rounded() * 50)) kcal/day",
                       "weight trend vs heart data — usually oils and bites",
                       "exclamationmark.magnifyingglass", Theme.Palette.carbs)
            }
            intakeChart
        }
    }

    private func kpiRow(_ title: String, _ value: String, _ detail: String,
                        _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(Circle().fill(tint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Text(value).font(.numeric(18))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail).font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .glassCard(radius: Theme.Radius.md, padding: 13)
    }

    /// 14 days of intake vs the goal line — adherence at a glance.
    private var intakeChart: some View {
        let days = (0..<14).compactMap { offset -> (date: Date, kcal: Double)? in
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())
            else { return nil }
            let kcal = env.calories(on: day)
            return kcal > 0 ? (Calendar.current.startOfDay(for: day), kcal) : nil
        }
        return Chart {
            ForEach(days, id: \.date) { day in
                BarMark(x: .value("Date", day.date, unit: .day),
                        y: .value("kcal", day.kcal))
                    .foregroundStyle(day.kcal <= env.calorieGoal * 1.05
                                     ? AnyShapeStyle(Theme.Grad.accent)
                                     : AnyShapeStyle(Theme.Palette.alert.opacity(0.75)))
                    .cornerRadius(4)
            }
            RuleMark(y: .value("Goal", env.calorieGoal))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Theme.Palette.textTertiary)
                .annotation(position: .topTrailing) {
                    Text("goal").font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(height: 140)
        .glassCard()
    }

    // MARK: - Weight

    private var weightSection: some View {
        let recent = env.weights.suffix(30)
        let slope = weeklyRate
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                if let current = env.weights.last {
                    heroTile("Current", String(format: "%.1f kg", current.kg),
                             "latest weigh-in", Theme.Palette.protein)
                }
                if let slope {
                    heroTile("Trend", String(format: "%+.2f kg/wk", slope),
                             slope < 0 ? "losing" : slope > 0 ? "gaining" : "holding",
                             abs(slope) < 1.1 ? Theme.Palette.accent : Theme.Palette.carbs)
                }
                if let projected = projectedIn30Days {
                    heroTile("In 30 days", String(format: "%.1f kg", projected),
                             "at this rate", Theme.Palette.textSecondary)
                }
            }
            Chart(Array(recent)) { entry in
                LineMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Theme.Grad.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                PointMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                    .foregroundStyle(Theme.Palette.accent)
                    .symbolSize(20)
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel(format: .dateTime.month(.narrow).day())
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks { _ in
                    AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                    AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .frame(height: 140)
            .glassCard()
        }
    }

    /// kg/week over the last 28 days of weigh-ins, least squares on raw data —
    /// the same discipline as AdaptiveEnergy: never fit the smoothed series.
    private var weeklyRate: Double? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -28, to: Date()) ?? Date()
        let recent = env.weights.filter { $0.date >= cutoff }
        guard recent.count >= 5, let first = recent.first else { return nil }
        let points = recent.map {
            (x: $0.date.timeIntervalSince(first.date) / 86_400, y: $0.kg)
        }
        let n = Double(points.count)
        let sumX = points.reduce(0) { $0 + $1.x }
        let sumY = points.reduce(0) { $0 + $1.y }
        let sumXY = points.reduce(0) { $0 + $1.x * $1.y }
        let sumXX = points.reduce(0) { $0 + $1.x * $1.x }
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > 0.0001 else { return nil }
        return ((n * sumXY - sumX * sumY) / denominator) * 7
    }

    private var projectedIn30Days: Double? {
        guard let slope = weeklyRate, let current = env.weights.last?.kg else { return nil }
        return current + slope / 7 * 30
    }

    // MARK: - Training

    private var trainingSection: some View {
        let last14 = env.recentSessions.filter {
            $0.startedAt >= (Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date())
        }
        let volume = last14.reduce(0) { $0 + $1.totalVolume }
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                heroTile("Sessions", "\(last14.count)", "last 14 days", Theme.Palette.accent)
                heroTile("Volume", volume >= 10_000
                            ? String(format: "%.1f t", volume / 1000)
                            : "\(Int(volume)) kg",
                         "last 14 days", Theme.Palette.protein)
                if let top = topPR {
                    heroTile(top.exercise, "\(Int(top.estimatedOneRepMax))",
                             "est. 1RM", Theme.Palette.burn)
                }
            }
            if totalZoneSeconds.reduce(0, +) >= 300 {
                zoneDistributionCard
            }
        }
    }

    private var topPR: SetLog? {
        let exercises = Set(env.sessions.flatMap(\.sets).map(\.exercise))
        return exercises
            .compactMap { env.strength.personalBest(for: $0) }
            .max { $0.estimatedOneRepMax < $1.estimatedOneRepMax }
    }

    private var totalZoneSeconds: [Double] {
        env.heart.dailySummaries.suffix(14)
            .compactMap(\.zoneSeconds)
            .reduce([Double](repeating: 0, count: 5)) { acc, zones in
                zip(acc, zones).map(+)
            }
    }

    private var zoneDistributionCard: some View {
        let zones = totalZoneSeconds
        let total = max(1, zones.reduce(0, +))
        let tints: [Color] = [Theme.Palette.accent, .teal, Theme.Palette.carbs, .orange, Theme.Palette.alert]
        return VStack(alignment: .leading, spacing: 8) {
            Text("Time in zones — 14 days")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(0..<5, id: \.self) { zone in
                        if zones[zone] > 0 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(tints[zone])
                                .frame(width: max(3, geo.size.width * zones[zone] / total))
                        }
                    }
                }
            }
            .frame(height: 10)
            HStack(spacing: 12) {
                ForEach(0..<5, id: \.self) { zone in
                    if zones[zone] >= 60 {
                        HStack(spacing: 4) {
                            Circle().fill(tints[zone]).frame(width: 6, height: 6)
                            Text("Z\(zone + 1) \(Int(zones[zone] / 60))m")
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                    }
                }
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    // MARK: - Heart

    private var heartSectionHasData: Bool {
        env.heart.dailySummaries.count >= 3 || env.health.dailyRestingHR.count >= 3
    }

    private var heartSection: some View {
        HStack(spacing: 10) {
            if let latest = env.heart.dailySummaries.last, latest.minHR < 250 {
                heroTile("Resting HR", "\(latest.minHR)", "WHOOP, today", Theme.Palette.alert)
            } else if let rhr = env.health.dailyRestingHR.last?.value {
                heroTile("Resting HR", "\(Int(rhr))", "Watch, today", Theme.Palette.alert)
            }
            if let sdnn = env.health.dailySDNN.last?.value {
                heroTile("HRV", "\(Int(sdnn)) ms", "overnight", Theme.Palette.protein)
            }
            if let maxHR = env.calibration.personalMaxHR {
                heroTile("Max HR", "\(Int(maxHR))", "observed", Theme.Palette.burn)
            } else if let vo2 = env.health.vo2Max {
                heroTile("VO₂ max", String(format: "%.0f", vo2), "ml/kg·min", Theme.Palette.accent)
            }
        }
    }

    // MARK: - Nutrition

    private var nutritionSection: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                heroTile("Protein today", "\(Int(env.proteinToday))g",
                         "of \(env.profile?.proteinTargetG ?? 0)g",
                         env.proteinToday >= Double(env.profile?.proteinTargetG ?? 0)
                            ? Theme.Palette.accent : Theme.Palette.protein)
                heroTile("Water", "\(Int(env.waterToday)) ml",
                         "of \(Int(env.waterTarget))", .teal)
                heroTile("Streak", "\(env.streak)",
                         env.streak == 1 ? "day" : "days", Theme.Palette.burn)
            }
            proteinChart
        }
    }

    /// Protein hit-rate over 14 days — the macro that actually decides body
    /// composition, judged against the profile target.
    private var proteinChart: some View {
        let target = Double(env.profile?.proteinTargetG ?? 0)
        let days = (0..<14).compactMap { offset -> (date: Date, grams: Double)? in
            guard let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())
            else { return nil }
            let grams = env.entries(on: day).reduce(0) { $0 + ($1.protein ?? 0) }
            return grams > 0 ? (Calendar.current.startOfDay(for: day), grams) : nil
        }
        return Chart {
            ForEach(days, id: \.date) { day in
                BarMark(x: .value("Date", day.date, unit: .day),
                        y: .value("g", day.grams))
                    .foregroundStyle(day.grams >= target
                                     ? AnyShapeStyle(Theme.Palette.protein)
                                     : AnyShapeStyle(Theme.Palette.protein.opacity(0.35)))
                    .cornerRadius(4)
            }
            if target > 0 {
                RuleMark(y: .value("Target", target))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(height: 130)
        .glassCard()
    }
}
