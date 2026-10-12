import SwiftUI
import Charts

struct HealthView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showMetrics = false
    @State private var showWeight = false
    @State private var showManualEntry = false
    @State private var showWhoop = false
    @State private var showWatch = false
    @State private var showInsights = false
    @State private var manualSteps = ""
    @State private var manualEnergy = ""

    private var health: HealthService { env.health }

    var body: some View {
        ScreenScaffold(title: "Health", subtitle: "Energy in vs. energy out") {
            content
        } trailing: {
            CircleIconButton(icon: "chart.bar.xaxis") { showMetrics = true }
        }
        .screenBackground()
        .sheet(isPresented: $showMetrics) { MetricsView() }
        .sheet(isPresented: $showWeight) { WeightView() }
        .fullScreenCover(isPresented: $showWhoop) { WhoopDeviceView() }
        .fullScreenCover(isPresented: $showWatch) { AppleWatchView() }
        .fullScreenCover(isPresented: $showInsights) { InsightsView() }
        .alert("Enter today's activity", isPresented: $showManualEntry) {
            TextField("Steps", text: $manualSteps).keyboardType(.numberPad)
            TextField("Calories burned", text: $manualEnergy).keyboardType(.numberPad)
            Button("Save") {
                health.setManual(steps: Int(manualSteps) ?? 0,
                                 activeEnergy: Double(manualEnergy) ?? 0)
                WidgetBridge.publish(eaten: env.caloriesToday, goal: env.calorieGoal,
                                     burned: env.burnedToday)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this if you'd rather not connect Apple Health, or your tracker lives elsewhere.")
        }
        .task { await env.refreshHealth() }
        .refreshable { await env.refreshHealth() }
    }

    @ViewBuilder
    private var content: some View {
        balanceCard

        // The daily glance: strain and readiness, when the data exists.
        if env.heart.todayStrain >= 0.1 || env.readiness != nil {
            HStack(spacing: 10) {
                strainTile
                if let readiness = env.readiness { readinessTile(readiness) }
            }
        }

        adaptiveEnergyCard
        if let unlogged = env.unloggedIntakeEstimate {
            auditCard(unlogged)
        }
        weightCard
        if let sleepMinutes = health.lastNightSleepMinutes {
            sleepCard(sleepMinutes)
        }

        SectionHeader(title: "Devices")
        deviceRow(icon: "bolt.heart.fill", tint: Theme.Palette.alert,
                  title: "WHOOP",
                  subtitle: whoopSubtitle) { showWhoop = true }
        deviceRow(icon: "applewatch", tint: Theme.Palette.accent,
                  title: "Apple Watch",
                  subtitle: watchSubtitle) { showWatch = true }

        fullReportRow
    }

    private var whoopSubtitle: String {
        if let bpm = env.heart.bpm {
            if let battery = env.heart.batteryPercent {
                return "Live · \(bpm) bpm · battery \(battery)%"
            }
            return "Live · \(bpm) bpm"
        }
        if let latest = env.heart.dailySummaries.last,
           Calendar.current.isDateInToday(latest.date), latest.sampleCount > 0 {
            return "Today · \(Int(latest.activeKcal * (env.calibration.energyScale ?? 1))) kcal · strain \(String(format: "%.1f", latest.strain))"
        }
        return env.heart.state.label
    }

    private var watchSubtitle: String {
        guard health.isAuthorized else { return "Not connected" }
        return "\(health.today.steps) steps · \(Int(health.today.activeEnergy)) kcal"
    }

    private func deviceRow(icon: String, tint: Color, title: String,
                           subtitle: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(tint.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .glassCard(radius: Theme.Radius.md, padding: 13)
        }
        .buttonStyle(PressableStyle())
    }

    private var fullReportRow: some View {
        Button {
            Haptics.tap()
            showInsights = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 15, weight: .bold))
                Text("Full report — every KPI, one page")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.vertical, 15)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(Theme.Grad.accent)
            }
            .glow(Theme.Palette.accent, radius: 16, opacity: 0.3)
        }
        .buttonStyle(PressableStyle())
    }

    // MARK: - Intake audit

    /// The number no single-source app can produce: the weight trend and the
    /// heart sensor independently estimate expenditure, and a persistent gap
    /// between them is unlogged food made visible.
    private func auditCard(_ unlogged: Double) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.carbs)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text("Likely under-logging ~\(Int((unlogged / 50).rounded() * 50)) kcal/day")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Your weight trend implies you burn less than your heart data says you do — the gap is usually food that never got logged. Sauces, oils and bites while cooking are the usual suspects.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    // MARK: - Strain & readiness

    private var strainTile: some View {
        let strain = env.heart.todayStrain
        return VStack(alignment: .leading, spacing: 6) {
            Text("DAY STRAIN")
                .font(.eyebrow).kerning(1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(String(format: "%.1f", strain))
                    .font(.numeric(24))
                    .foregroundStyle(Theme.Palette.accent)
                    .contentTransition(.numericText())
                Text("/ 21")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ProgressView(value: strain, total: 21)
                .tint(Theme.Palette.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Palette.accent.opacity(0.08))
        }
    }

    /// Readiness 0–100, colored like a traffic light.
    private func readinessTile(_ readiness: Double) -> some View {
        let tint: Color = readiness >= 67 ? Theme.Palette.accent
            : readiness >= 34 ? Theme.Palette.carbs : .red
        let word = readiness >= 67 ? "Ready to push"
            : readiness >= 34 ? "Take it steady" : "Go easy today"
        return VStack(alignment: .leading, spacing: 6) {
            Text("READINESS")
                .font(.eyebrow).kerning(1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(Int(readiness))")
                    .font(.numeric(24))
                    .foregroundStyle(tint)
                Text("%")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Text(word)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(tint.opacity(0.08))
        }
    }

    // MARK: - Sleep

    private func sleepCard(_ minutes: Double) -> some View {
        let hours = Int(minutes) / 60
        let mins = Int(minutes) % 60
        return HStack(spacing: 12) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 16))
                .foregroundStyle(.indigo)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Color.indigo.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Last night")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("\(hours) h \(mins) min")
                    .font(.numeric(18))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Spacer()
            if minutes < 360 {
                Text("Short night — expect hunger to run high today.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(maxWidth: 140)
                    .multilineTextAlignment(.trailing)
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    // MARK: - Balance

    private var balanceCard: some View {
        let eaten = env.caloriesToday
        let burned = env.burnedToday
        let net = eaten - burned

        return VStack(spacing: 14) {
            Text("ENERGY BALANCE")
                .font(.eyebrow).kerning(1.2)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: 0) {
                balanceColumn("Eaten", eaten, Theme.Palette.accent, "fork.knife")
                Text("−").font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.Palette.textTertiary)
                balanceColumn("Burned", burned, Theme.Palette.burn, "flame.fill")
                Text("=").font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.Palette.textTertiary)
                balanceColumn("Net", net, net > env.calorieGoal ? Theme.Palette.alert : Theme.Palette.protein,
                              "equal.circle.fill")
            }

            Text(net > 0
                 ? "A surplus of \(Int(net)) kcal so far today."
                 : "A deficit of \(Int(-net)) kcal so far today.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .glassCard(radius: Theme.Radius.lg, padding: 20)
    }

    private func balanceColumn(_ label: String, _ value: Double, _ tint: Color, _ icon: String) -> some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
            Text("\(Int(value))")
                .font(.numeric(21))
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Adaptive energy

    /// Surfaces what the app has *learned* the user's maintenance calories are,
    /// versus what the textbook formula predicted.
    @ViewBuilder
    private var adaptiveEnergyCard: some View {
        if let energy = env.energy {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("Your real maintenance")
                        .font(.cardTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Spacer()
                    if energy.isAdaptive {
                        BadgePill(icon: "checkmark.seal.fill", text: "Learned",
                                  tint: Theme.Palette.accent)
                    }
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(energy.tdee))")
                        .font(.numeric(36))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .contentTransition(.numericText())
                    Text("kcal/day")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                if energy.isAdaptive {
                    let delta = energy.tdee - energy.formulaTDEE
                    Text(String(format: "%@%.0f kcal vs the standard formula (%.0f).",
                                delta >= 0 ? "+" : "", delta, energy.formulaTDEE))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }

                if let weekly = energy.weeklyChangeKg, energy.weighIns >= 2 {
                    HStack(spacing: 6) {
                        Image(systemName: weekly < 0 ? "arrow.down.right" : "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                        Text(String(format: "Trend: %@%.2f kg/week", weekly >= 0 ? "+" : "", weekly))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(weekly < 0 ? Theme.Palette.accent : Theme.Palette.carbs)
                }

                // Confidence, so the number is never presented as more certain
                // than the evidence behind it.
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Confidence")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Spacer()
                        Text("\(Int(energy.confidence * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                    ProgressCapsule(value: energy.confidence, total: 1, height: 5)
                }

                Text(energy.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .glassCard(tint: energy.isAdaptive ? Theme.Palette.accent : nil)
        }
    }

    // MARK: - Weight entry point

    private var weightCard: some View {
        Button {
            Haptics.tap()
            showWeight = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.stand")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.protein)
                    .frame(width: 38, height: 38)
                    .background(Circle().fill(Theme.Palette.protein.opacity(0.13)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Body weight")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(weightSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .glassCard(radius: Theme.Radius.md, padding: 13)
        }
        .buttonStyle(PressableStyle())
    }

    private var weightSubtitle: String {
        guard let latest = env.latestWeight else { return "Not logged yet — tap to add" }
        var text = String(format: "%.1f kg", latest.kg)
        if let change = env.weightChange, abs(change) >= 0.1 {
            text += String(format: " · %@%.1f kg overall", change > 0 ? "+" : "", change)
        }
        return text
    }
}
