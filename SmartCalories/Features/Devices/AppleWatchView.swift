import SwiftUI
import Charts

/// The Apple Watch hub: everything HealthKit provides — activity, sleep with
/// stages, and the overnight vitals WHOOP broadcast can't carry.
struct AppleWatchView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    private var health: HealthService { env.health }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if !health.isAuthorized {
                        connectCard
                    } else {
                        activityGrid
                        if health.lastNightSleepMinutes != nil { sleepCard }
                        vitalsSection
                        if health.dailySDNN.count >= 3 {
                            SectionHeader(title: "Overnight HRV — 14 days")
                            hrvChart
                        }
                        if health.dailyRestingHR.count >= 3 {
                            SectionHeader(title: "Resting heart rate — 30 days")
                            restingChart
                        }
                        fitnessSection
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Apple Watch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await env.refreshHealth() }
            .refreshable { await env.refreshHealth() }
        }
    }

    // MARK: - Connect

    private var connectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "applewatch")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Connect Apple Health")
                    .font(.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Text("Steps, energy, sleep stages, HRV, VO₂ max and overnight vitals — and it powers the cross-device calibration with your WHOOP.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            PrimaryButton(title: "Grant access", icon: "person.text.rectangle") {
                Task { await health.requestAuthorization() }
            }
        }
        .glassCard()
    }

    // MARK: - Activity

    private var activityGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                StatTile(label: "Active energy", value: "\(Int(health.today.activeEnergy))",
                         unit: "kcal", icon: "flame.fill", tint: Theme.Palette.burn)
                StatTile(label: "Steps", value: "\(health.today.steps)",
                         icon: "figure.walk", tint: Theme.Palette.accent)
            }
            HStack(spacing: 10) {
                StatTile(label: "Exercise", value: "\(Int(health.today.exerciseMinutes))",
                         unit: "min", icon: "figure.run", tint: Theme.Palette.protein)
                StatTile(label: "Stand", value: "\(Int(health.standMinutesToday))",
                         unit: "min", icon: "figure.stand", tint: Theme.Palette.carbs)
            }
            HStack(spacing: 10) {
                StatTile(label: "Distance", value: String(format: "%.1f", health.today.distanceKm),
                         unit: "km", icon: "location.fill", tint: Theme.Palette.accent)
                StatTile(label: "Flights", value: "\(health.flightsToday)",
                         icon: "figure.stairs", tint: Theme.Palette.fat)
            }
        }
    }

    // MARK: - Sleep

    private var sleepCard: some View {
        let minutes = health.lastNightSleepMinutes ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.indigo)
                    Text("Last night")
                        .font(.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Text("\(Int(minutes) / 60) h \(Int(minutes) % 60) min")
                    .font(.numeric(18))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            if let stages = health.sleepStages {
                stagesBar(stages)
                HStack(spacing: 14) {
                    stageLegend("Deep", stages.deepMinutes, Color(hex: 0x3730A3))
                    stageLegend("Core", stages.coreMinutes, Color(hex: 0x6366F1))
                    stageLegend("REM", stages.remMinutes, Color(hex: 0x38BDF8))
                    if stages.awakeMinutes >= 1 {
                        stageLegend("Awake", stages.awakeMinutes, Theme.Palette.carbs)
                    }
                }
            }
        }
        .glassCard()
    }

    private func stagesBar(_ stages: HealthService.SleepStages) -> some View {
        let total = max(1, stages.deepMinutes + stages.coreMinutes + stages.remMinutes + stages.awakeMinutes)
        let segments: [(Double, Color)] = [
            (stages.deepMinutes, Color(hex: 0x3730A3)),
            (stages.coreMinutes, Color(hex: 0x6366F1)),
            (stages.remMinutes, Color(hex: 0x38BDF8)),
            (stages.awakeMinutes, Theme.Palette.carbs),
        ]
        return GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    if segment.0 > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(segment.1)
                            .frame(width: max(3, geo.size.width * segment.0 / total))
                    }
                }
            }
        }
        .frame(height: 10)
    }

    private func stageLegend(_ label: String, _ minutes: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 7, height: 7)
            Text("\(label) \(Int(minutes))m")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    // MARK: - Vitals

    private var vitalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Overnight vitals")
            HStack(spacing: 10) {
                if let sdnn = health.dailySDNN.last?.value {
                    StatTile(label: "HRV", value: "\(Int(sdnn))", unit: "ms",
                             icon: "waveform.path.ecg", tint: Theme.Palette.protein)
                }
                if let rhr = health.dailyRestingHR.last?.value {
                    StatTile(label: "Resting HR", value: "\(Int(rhr))", unit: "bpm",
                             icon: "heart.fill", tint: Theme.Palette.alert)
                }
            }
            HStack(spacing: 10) {
                if let rr = health.respiratoryRate {
                    StatTile(label: "Respiratory", value: String(format: "%.1f", rr),
                             unit: "br/min", icon: "lungs.fill", tint: .teal)
                }
                if let temp = health.wristTempDeltaC {
                    StatTile(label: "Wrist temp", value: String(format: "%+.1f", temp),
                             unit: "°C", icon: "thermometer.variable",
                             tint: abs(temp) > 0.5 ? Theme.Palette.carbs : Theme.Palette.accent)
                }
            }
        }
    }

    // MARK: - Fitness markers

    private var fitnessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Fitness markers")
            HStack(spacing: 10) {
                if let vo2 = health.vo2Max {
                    StatTile(label: "VO₂ max", value: String(format: "%.1f", vo2),
                             unit: "ml/kg·min", icon: "lungs.fill", tint: Theme.Palette.accent)
                }
                if let recovery = health.hrRecovery {
                    StatTile(label: "HR recovery", value: "\(Int(recovery))", unit: "bpm",
                             icon: "arrow.down.heart.fill", tint: Theme.Palette.protein)
                }
                if let walking = health.walkingHRAverage {
                    StatTile(label: "Walking HR", value: "\(Int(walking))", unit: "bpm",
                             icon: "figure.walk.motion", tint: Theme.Palette.carbs)
                }
            }
            if health.vo2Max == nil && health.hrRecovery == nil && health.walkingHRAverage == nil {
                Text("VO₂ max and heart-rate recovery appear after outdoor walks or workouts with the Watch.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    // MARK: - Charts

    private var hrvChart: some View {
        Chart(health.dailySDNN) { day in
            LineMark(x: .value("Date", day.date, unit: .day),
                     y: .value("SDNN", day.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.Palette.protein)
            AreaMark(x: .value("Date", day.date, unit: .day),
                     yStart: .value("SDNN", health.dailySDNN.map(\.value).min() ?? 0),
                     yEnd: .value("SDNN", day.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.Palette.protein.opacity(0.25), .clear],
                                   startPoint: .top, endPoint: .bottom))
        }
        .chartYScale(domain: .automatic(includesZero: false))
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

    private var restingChart: some View {
        Chart(health.dailyRestingHR) { day in
            LineMark(x: .value("Date", day.date, unit: .day),
                     y: .value("RHR", day.value))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.Palette.alert.opacity(0.85))
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
        .frame(height: 130)
        .glassCard()
    }
}
