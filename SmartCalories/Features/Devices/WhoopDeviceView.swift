import SwiftUI
import Charts

/// The WHOOP hub: live connection, everything derived from the band's HR
/// stream, and what the cross-device calibration has learned about it.
struct WhoopDeviceView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Archive counters, read once per appearance — status() touches disk,
    /// so it must not run on every render.
    @State private var archiveToday = 0
    @State private var archivePending = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    liveHero

                    if env.heart.todayStrain >= 0.1 || env.readiness != nil {
                        HStack(spacing: 10) {
                            strainTile
                            if let readiness = env.readiness { readinessTile(readiness) }
                        }
                    }

                    if let latest = env.heart.dailySummaries.last, latest.sampleCount > 0 {
                        todayRow(latest)
                    }

                    SectionHeader(title: "Heart rate")
                    HeartRateHistoryCard()

                    if restingDays.count >= 3 {
                        SectionHeader(title: "Resting heart rate — 14 days")
                        restingChart
                    }
                    if strainDays.count >= 2 {
                        SectionHeader(title: "Strain — 14 days")
                        strainChart
                    }

                    calibrationCard
                    archiveLine
                    honestyFooter
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("WHOOP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .onAppear {
                env.heart.activate()
                let status = env.heart.samples.status()
                archiveToday = status.today
                archivePending = status.pending
            }
        }
    }

    // MARK: - Live hero

    private var liveHero: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(env.heart.isConnected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .frame(width: 7, height: 7)
                        .glow(env.heart.isConnected ? Theme.Palette.accent : .clear, radius: 5, opacity: 0.9)
                    Text(env.heart.isConnected
                         ? (env.heart.connectedName ?? "Connected")
                         : env.heart.state.label)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(env.heart.isConnected
                                         ? Theme.Palette.accent : Theme.Palette.textSecondary)
                }
                Spacer()
                if let battery = env.heart.batteryPercent {
                    batteryBadge(battery)
                }
                if env.heart.isConnected {
                    Button("Disconnect") { env.heart.disconnect() }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            if let bpm = env.heart.bpm {
                VStack(spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(.red)
                            .symbolEffect(.pulse, options: .repeating)
                        Text("\(bpm)")
                            .font(.numeric(56, .heavy))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .contentTransition(.numericText())
                    }
                    if let zone = env.heart.zone {
                        Text("Zone \(zone)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(zoneTint(zone))
                    }
                }
                .frame(maxWidth: .infinity)
            } else if env.heart.isConnected {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Connected — waiting for heart rate. Keep the WHOOP app's Broadcast Heart Rate screen open.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                connectFlow
            }
        }
        .glassCard(radius: Theme.Radius.lg, padding: 18)
    }

    private var connectFlow: some View {
        VStack(spacing: 10) {
            Text("Turn on Broadcast Heart Rate in the WHOOP app (More → Broadcast Heart Rate), then search.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(env.heart.discovered) { device in
                Button { env.heart.connect(device) } label: {
                    HStack(spacing: 6) {
                        if device.advertisesHeartRate {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 10)).foregroundStyle(.red)
                        }
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer()
                        Text("\(device.rssi) dB")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    .padding(.vertical, 6)
                }
            }
            if env.heart.state == .scanning, env.heart.discovered.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.Palette.accent)
                    Text("Searching…")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            SecondaryButton(
                title: env.heart.state == .scanning ? "Stop searching" : "Find my WHOOP",
                icon: "dot.radiowaves.left.and.right"
            ) {
                env.heart.activate()
                env.heart.state == .scanning ? env.heart.stopScan() : env.heart.startScan()
            }
        }
    }

    // MARK: - Tiles

    private var strainTile: some View {
        let strain = env.heart.todayStrain
        return VStack(alignment: .leading, spacing: 6) {
            Text("DAY STRAIN").font(.eyebrow).kerning(1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", strain))
                    .font(.numeric(24)).foregroundStyle(Theme.Palette.accent)
                    .contentTransition(.numericText())
                Text("/ 21").font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ProgressView(value: strain, total: 21).tint(Theme.Palette.accent)
        }
        .glassCard(radius: Theme.Radius.md, padding: 12)
    }

    private func readinessTile(_ readiness: Double) -> some View {
        let tint: Color = readiness >= 67 ? Theme.Palette.accent
            : readiness >= 34 ? Theme.Palette.carbs : Theme.Palette.alert
        let word = readiness >= 67 ? "Ready to push"
            : readiness >= 34 ? "Take it steady" : "Go easy today"
        return VStack(alignment: .leading, spacing: 6) {
            Text("READINESS").font(.eyebrow).kerning(1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(readiness))").font(.numeric(24)).foregroundStyle(tint)
                Text("%").font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text(word).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
        }
        .glassCard(radius: Theme.Radius.md, padding: 12)
    }

    private func todayRow(_ latest: DailyHeartSummary) -> some View {
        HStack(spacing: 10) {
            StatTile(label: "Active", value: "\(Int(latest.activeKcal * (env.calibration.energyScale ?? 1)))",
                     unit: "kcal", icon: "flame.fill", tint: Theme.Palette.burn)
            if latest.minHR < 250 {
                StatTile(label: "Resting", value: "\(latest.minHR)", unit: "bpm",
                         icon: "heart.fill", tint: Theme.Palette.alert)
            }
            if let rmssd = latest.restRMSSD {
                StatTile(label: "HRV", value: "\(Int(rmssd))", unit: "ms",
                         icon: "waveform.path.ecg", tint: Theme.Palette.protein)
            }
        }
    }

    // MARK: - Charts

    private var restingDays: [DailyHeartSummary] {
        Array(env.heart.dailySummaries.suffix(14).filter { $0.minHR < 250 })
    }
    private var strainDays: [DailyHeartSummary] {
        Array(env.heart.dailySummaries.suffix(14).filter { ($0.trimp ?? 0) > 0 })
    }

    private var restingChart: some View {
        Chart(restingDays) { day in
            LineMark(x: .value("Date", day.date, unit: .day),
                     y: .value("Resting", day.minHR))
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Theme.Palette.alert.opacity(0.85))
            PointMark(x: .value("Date", day.date, unit: .day),
                      y: .value("Resting", day.minHR))
                .foregroundStyle(Theme.Palette.alert)
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

    private var strainChart: some View {
        Chart(strainDays) { day in
            BarMark(x: .value("Date", day.date, unit: .day),
                    y: .value("Strain", day.strain))
                .foregroundStyle(Theme.Grad.accent)
                .cornerRadius(4)
        }
        .chartYScale(domain: 0...21)
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 7, 14, 21]) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.hairline)
                AxisValueLabel().foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .frame(height: 130)
        .glassCard()
    }

    // MARK: - Calibration

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "scope")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.protein)
                Text("Cross-device calibration")
                    .font(.cardTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            if env.calibration.isActive {
                VStack(alignment: .leading, spacing: 7) {
                    if let scale = env.calibration.energyScale {
                        calibrationRow(
                            "Energy factor",
                            String(format: "×%.2f", scale),
                            "from \(env.calibration.pairedEnergyDays) days worn with your Watch")
                    }
                    if let offset = env.calibration.restingHROffset {
                        calibrationRow(
                            "Resting-HR offset",
                            String(format: "%+.0f bpm", -offset),
                            "aligns WHOOP readings to Apple's scale")
                    }
                    if let maxHR = env.calibration.personalMaxHR {
                        calibrationRow(
                            "Personal max HR",
                            "\(Int(maxHR)) bpm",
                            "observed — replaces the age formula in zones")
                    }
                }
            } else {
                Text("Wear your WHOOP and Apple Watch together for about a week. The app learns how their numbers relate and corrects WHOOP-only days automatically.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .glassCard()
    }

    private func calibrationRow(_ label: String, _ value: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail).font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.protein)
        }
    }

    /// Where the raw stream stands: what's archived today and what still
    /// waits for upload. The user should never wonder whether data is safe.
    @ViewBuilder
    private var archiveLine: some View {
        if archiveToday > 0 || archivePending > 0 {
            HStack(spacing: 6) {
                Image(systemName: archivePending == 0
                      ? "checkmark.icloud.fill" : "icloud.and.arrow.up")
                    .font(.system(size: 11))
                    .foregroundStyle(archivePending == 0
                                     ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(archivePending == 0
                     ? "Raw stream: \(archiveToday) samples today · all backed up"
                     : "Raw stream: \(archiveToday) samples today · \(archivePending) awaiting upload")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    private var honestyFooter: some View {
        Text("Broadcast mode carries live heart rate only. HRV, SpO₂, skin temperature and sleep stay inside WHOOP's own app — pair an Apple Watch to fill those in here.")
            .font(.system(size: 10.5))
            .foregroundStyle(Theme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }

    /// Band battery from the standard Battery Service. Amber under 30,
    /// red under 15 — the thresholds where a WHOOP starts dropping overnight
    /// coverage.
    private func batteryBadge(_ percent: Int) -> some View {
        let tint: Color = percent <= 15 ? Theme.Palette.alert
            : percent <= 30 ? Theme.Palette.carbs : Theme.Palette.accent
        let icon = percent <= 12 ? "battery.0percent"
            : percent <= 37 ? "battery.25percent"
            : percent <= 62 ? "battery.50percent"
            : percent <= 87 ? "battery.75percent" : "battery.100percent"
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
            Text("\(percent)%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(tint.opacity(0.12)))
    }

    private func zoneTint(_ zone: Int) -> Color {
        switch zone {
        case 1: Theme.Palette.accent
        case 2: .teal
        case 3: Theme.Palette.carbs
        case 4: .orange
        default: Theme.Palette.alert
        }
    }
}
