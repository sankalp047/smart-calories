import SwiftUI
import Charts

// MARK: - Weight tracking

struct WeightView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var showEntry = false
    @State private var entryText = ""
    @State private var useMetric = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    summary

                    if env.weights.count >= 2 {
                        SectionHeader(title: "Trend")
                        trendChart
                    }

                    PrimaryButton(title: "Log today's weight", icon: "plus") {
                        entryText = env.latestWeight.map { String(format: "%.1f", $0.kg) } ?? ""
                        showEntry = true
                    }

                    if env.weights.isEmpty {
                        EmptyStateView(
                            icon: "figure.stand",
                            title: "No weigh-ins yet",
                            message: "Log your weight regularly and your calorie target updates with you."
                        )
                        .glassCard()
                    } else {
                        SectionHeader(title: "History")
                        VStack(spacing: 8) {
                            ForEach(env.weights.reversed()) { entry in
                                HStack {
                                    Text(entry.date, format: .dateTime.month().day().year())
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.Palette.textSecondary)
                                    Spacer()
                                    Text(String(format: "%.1f kg", entry.kg))
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                }
                                .glassCard(radius: Theme.Radius.sm, padding: 12)
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .alert("Log weight", isPresented: $showEntry) {
                TextField(useMetric ? "kg" : "lb", text: $entryText).keyboardType(.decimalPad)
                Button("Save") {
                    guard let value = Double(entryText), value > 0 else { return }
                    env.logWeight(useMetric ? value : value * 0.45359237)
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            StatTile(label: "Current",
                     value: env.latestWeight.map { String(format: "%.1f", $0.kg) } ?? "—",
                     unit: "kg", icon: "scalemass.fill", tint: Theme.Palette.accent)
            StatTile(label: "Change",
                     value: env.weightChange.map { String(format: "%@%.1f", $0 > 0 ? "+" : "", $0) } ?? "—",
                     unit: "kg", icon: "arrow.up.arrow.down",
                     tint: (env.weightChange ?? 0) > 0 ? Theme.Palette.alert : Theme.Palette.accent)
        }
    }

    /// Y range fitted to the data rather than to zero.
    ///
    /// Body weight moves by a kilo or two against an absolute value of
    /// seventy-plus, so a zero-based axis renders every real trend as a flat
    /// line. The padding is proportional to the observed spread, with a floor
    /// so that a genuinely stable week doesn't get magnified into noise.
    private var yDomain: ClosedRange<Double> {
        let kgs = env.weights.map(\.kg)
        guard let lo = kgs.min(), let hi = kgs.max() else { return 0...100 }
        let pad = max((hi - lo) * 0.25, 0.5)
        return (lo - pad)...(hi + pad)
    }

    private var trendChart: some View {
        Chart(env.weights) { entry in
            // AreaMark's implicit baseline is zero, which would drag the
            // domain back down however the scale is configured — so anchor it
            // explicitly to the bottom of the fitted range.
            AreaMark(x: .value("Date", entry.date),
                     yStart: .value("kg", yDomain.lowerBound),
                     yEnd: .value("kg", entry.kg))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(colors: [Theme.Palette.accent.opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .bottom)
                )
            LineMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.Grad.accent)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
            PointMark(x: .value("Date", entry.date), y: .value("kg", entry.kg))
                .foregroundStyle(Theme.Palette.accent)
        }
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.month().day())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(height: 170)
        .glassCard()
    }
}

// MARK: - Derived metrics

struct MetricsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let profile = env.profile {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        SectionHeader(title: "Body composition")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            StatTile(label: "BMI · \(profile.bmiCategory)",
                                     value: String(format: "%.1f", profile.bmi),
                                     icon: "figure", tint: Theme.Palette.protein)
                            StatTile(label: "Body fat (est.)",
                                     value: String(format: "%.1f", profile.bodyFatPercent),
                                     unit: "%", icon: "percent", tint: Theme.Palette.carbs)
                            StatTile(label: "Lean mass",
                                     value: String(format: "%.1f", profile.leanBodyMassKg),
                                     unit: "kg", icon: "figure.strengthtraining.traditional",
                                     tint: Theme.Palette.accent)
                            StatTile(label: "Ideal range",
                                     value: "\(Int(profile.idealWeightMinKg))–\(Int(profile.idealWeightMaxKg))",
                                     unit: "kg", icon: "target", tint: Theme.Palette.fat)
                        }

                        SectionHeader(title: "Energy & nutrition")
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                                            GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            StatTile(label: "BMR", value: "\(Int(profile.bmr))", unit: "kcal",
                                     icon: "bed.double.fill", tint: Theme.Palette.textSecondary)
                            StatTile(label: "Maintenance", value: "\(Int(profile.tdee))", unit: "kcal",
                                     icon: "flame.fill", tint: Theme.Palette.burn)
                            StatTile(label: "Protein target", value: "\(profile.proteinTargetG)", unit: "g",
                                     icon: "circle.hexagongrid.fill", tint: Theme.Palette.protein)
                            StatTile(label: "Water target",
                                     value: String(format: "%.1f", profile.dailyWaterMl / 1000),
                                     unit: "L", icon: "drop.fill", tint: Color(hex: 0x38BDF8))
                        }

                        SectionHeader(title: "Heart-rate zones")
                        zones(profile)

                        Text("Estimates from standard formulas (Mifflin–St Jeor, Deurenberg, 220−age). Targets to train toward, not medical measurements.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .padding(16)
                    .padding(.bottom, 24)
                } else {
                    EmptyStateView(icon: "person.crop.circle.badge.questionmark",
                                   title: "No profile yet",
                                   message: "Complete your profile to see derived metrics.")
                        .padding(30)
                }
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Metrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func zones(_ profile: UserProfile) -> some View {
        VStack(spacing: 10) {
            zoneRow("Maximum", "\(profile.maxHeartRate) bpm", Theme.Palette.alert)
            Divider().overlay(Theme.Palette.hairline)
            zoneRow("Fat burn (60–70%)",
                    "\(profile.fatBurnZone.lowerBound)–\(profile.fatBurnZone.upperBound) bpm",
                    Theme.Palette.accent)
            zoneRow("Cardio (70–85%)",
                    "\(profile.cardioZone.lowerBound)–\(profile.cardioZone.upperBound) bpm",
                    Theme.Palette.burn)
        }
        .glassCard()
    }

    private func zoneRow(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 8, height: 8)
            Text(label).font(.system(size: 13)).foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
    }
}
