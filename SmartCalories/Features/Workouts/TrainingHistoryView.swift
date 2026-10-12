import SwiftUI
import Charts

/// Training history and personal bests — the memory the training side of the
/// app was missing. Without it, generated plans have no continuity.
struct TrainingHistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    /// Every exercise ever logged, ranked by how recently it was trained.
    private var exercises: [String] {
        var seen = Set<String>()
        return env.recentSessions
            .flatMap(\.exercisesPerformed)
            .compactMap { seen.insert($0).inserted ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if env.sessions.isEmpty {
                        EmptyStateView(
                            icon: "figure.strengthtraining.traditional",
                            title: "No sessions yet",
                            message: "Start a workout from any plan and log your sets — your PRs and progression show up here."
                        )
                        .glassCard()
                    } else {
                        summary
                        volumeChart

                        SectionHeader(title: "Personal bests")
                        VStack(spacing: 8) {
                            ForEach(exercises.prefix(12), id: \.self) { exercise in
                                prRow(exercise)
                            }
                        }

                        SectionHeader(title: "Sessions")
                        VStack(spacing: 8) {
                            ForEach(env.recentSessions) { session in
                                sessionRow(session)
                            }
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Training")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private var summary: some View {
        HStack(spacing: 10) {
            StatTile(label: "Sessions", value: "\(env.sessions.count)",
                     icon: "figure.strengthtraining.traditional", tint: Theme.Palette.accent)
            StatTile(label: "Total volume",
                     value: "\(Int(env.sessions.reduce(0) { $0 + $1.totalVolume } / 1000))",
                     unit: "t", icon: "scalemass.fill", tint: Theme.Palette.protein)
        }
    }

    /// Volume per session is the clearest single signal of whether training is
    /// actually progressing over time.
    private var volumeChart: some View {
        Chart(env.recentSessions.prefix(14).reversed()) { session in
            BarMark(
                x: .value("Date", session.startedAt, unit: .day),
                y: .value("Volume", session.totalVolume)
            )
            .foregroundStyle(Theme.Grad.accent)
            .cornerRadius(5)
        }
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
        .frame(height: 150)
        .glassCard()
    }

    private func prRow(_ exercise: String) -> some View {
        let best = env.strength.personalBest(for: exercise)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(exercise)
                    .font(.rowTitle)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                if let best {
                    Text("\(StrengthHistory.formatWeight(best.weightKg)) × \(best.reps)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            Spacer(minLength: 0)
            if let best {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(best.estimatedOneRepMax))")
                        .font(.numeric(16))
                        .foregroundStyle(Theme.Palette.accent)
                    Text("est. 1RM")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .glassCard(radius: Theme.Radius.sm, padding: 12)
    }

    private func sessionSubtitle(_ session: WorkoutSession) -> String {
        var parts = ["\(session.startedAt.formatted(.dateTime.month().day()))",
                     "\(session.sets.count) sets"]
        if let heart = session.heart {
            parts.append("♥ \(heart.avgHR) avg")
            parts.append("\(Int(heart.activeKcal)) kcal")
            if let strain = heart.strain {
                parts.append("strain \(String(format: "%.1f", strain))")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Five-segment bar of session time per HR zone, easy zone → red zone.
    @ViewBuilder
    private func zoneBar(_ zoneSeconds: [Double]) -> some View {
        let total = zoneSeconds.reduce(0, +)
        if total >= 60, zoneSeconds.count == 5 {
            let tints: [Color] = [Theme.Palette.accent, .teal, Theme.Palette.carbs, .orange, .red]
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(0..<5, id: \.self) { zone in
                            if zoneSeconds[zone] > 0 {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(tints[zone])
                                    .frame(width: max(3, geo.size.width * zoneSeconds[zone] / total))
                            }
                        }
                    }
                }
                .frame(height: 6)
                Text("Time in zones")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.top, 6)
        }
    }

    private func sessionRow(_ session: WorkoutSession) -> some View {
        DisclosureGroup {
            VStack(spacing: 6) {
                ForEach(session.exercisesPerformed, id: \.self) { exercise in
                    let sets = session.sets(for: exercise)
                    HStack(alignment: .top) {
                        Text(exercise)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer(minLength: 8)
                        Text(sets.map { "\(StrengthHistory.formatWeight($0.weightKg))×\($0.reps)" }
                                .joined(separator: ", "))
                            .font(.system(size: 11, design: .rounded))
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if let zones = session.heart?.zoneSeconds {
                    zoneBar(zones)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.dayTitle)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(sessionSubtitle(session))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                Text("\(Int(session.totalVolume)) kg")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .tint(Theme.Palette.textTertiary)
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }
}
