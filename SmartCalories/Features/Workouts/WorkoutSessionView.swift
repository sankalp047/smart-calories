import SwiftUI

/// Live set logging for a training day.
///
/// The design goal is speed with sweaty hands between sets: the weight and rep
/// steppers carry over from the previous set, so a straight-sets workout is one
/// tap per set. What you did last time for each lift is shown inline, because
/// progression is meaningless without that reference in front of you.
struct WorkoutSessionView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let plan: WorkoutPlan
    let day: WorkoutDay

    /// Per-exercise entry state, carried between sets.
    @State private var weights: [String: Double] = [:]
    @State private var reps: [String: Int] = [:]
    @State private var confirmFinish = false
    @State private var prBanner: String?

    private var session: WorkoutSession? { env.activeSession }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    header
                    if let prBanner {
                        InlineMessage(kind: .success, text: prBanner)
                    }
                    ForEach(day.exercises) { exercise in
                        exerciseCard(exercise)
                    }
                    finishButton
                }
                .padding(16)
                .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle(day.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) {
                        env.discardSession()
                        dismiss()
                    }
                }
            }
            .alert("Finish this workout?", isPresented: $confirmFinish) {
                Button("Finish", role: .destructive) {
                    env.finishSession()
                    dismiss()
                }
                Button("Keep going", role: .cancel) {}
            } message: {
                Text("\(session?.sets.count ?? 0) sets logged.")
            }
            .onAppear {
                seedFromHistory()
                // Window the heart stream so finishSession can attach
                // avg/max HR and kcal to this session.
                env.heart.activate()
                env.heart.beginSessionWindow()
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.name)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("\(session?.sets.count ?? 0) sets")
                    .font(.numeric(24))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if let bpm = env.heart.bpm {
                liveHeartChip(bpm)
                Spacer()
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text("Volume")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text("\(Int(session?.totalVolume ?? 0)) kg")
                    .font(.numeric(24))
                    .foregroundStyle(Theme.Palette.accent)
                    .contentTransition(.numericText())
            }
        }
        .glassCard()
    }

    /// Live BPM with the training zone as color — the number a lifter
    /// glances at between sets to know when to go again.
    private func liveHeartChip(_ bpm: Int) -> some View {
        let zone = env.heart.zone ?? 1
        let tint: Color = switch zone {
        case 1: Theme.Palette.accent
        case 2: .teal
        case 3: Theme.Palette.carbs
        case 4: .orange
        default: .red
        }
        return VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(tint)
                    .symbolEffect(.pulse, options: .repeating)
                Text("\(bpm)")
                    .font(.numeric(24))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
            }
            Text("zone \(zone)")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
        }
    }

    private func exerciseCard(_ exercise: Exercise) -> some View {
        let logged = session?.sets(for: exercise.name) ?? []
        let weight = weights[exercise.name] ?? 20
        let repCount = reps[exercise.name] ?? defaultReps(for: exercise)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(exercise.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Target: \(exercise.sets) × \(exercise.reps)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                Text("\(logged.count)/\(exercise.sets)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(logged.count >= exercise.sets
                                     ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }

            // What happened last time — the reference point for progression.
            if let hint = env.strength.suggestion(for: exercise.name, targetReps: exercise.reps) {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.Palette.carbs)
                    Text(hint)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Sets already logged this session.
            if !logged.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(Array(logged.enumerated()), id: \.element.id) { index, set in
                        Text("\(index + 1)· \(StrengthHistory.formatWeight(set.weightKg))×\(set.reps)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.Palette.accent)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.Palette.accent.opacity(0.14)))
                    }
                }
            }

            // Entry row
            HStack(spacing: 10) {
                stepper(label: "kg", value: StrengthHistory.formatWeight(weight).replacingOccurrences(of: " kg", with: ""),
                        onMinus: { adjustWeight(exercise.name, by: -2.5) },
                        onPlus: { adjustWeight(exercise.name, by: 2.5) })
                stepper(label: "reps", value: "\(repCount)",
                        onMinus: { adjustReps(exercise.name, by: -1, exercise: exercise) },
                        onPlus: { adjustReps(exercise.name, by: 1, exercise: exercise) })
            }

            HStack(spacing: 8) {
                Button {
                    logSet(exercise: exercise, weight: weight, reps: repCount)
                } label: {
                    Text("Log set")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.onAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.Grad.accent))
                }
                .buttonStyle(PressableStyle())

                if !logged.isEmpty {
                    Button {
                        withAnimation(Theme.Motion.snappy) { env.removeLastSet(of: exercise.name) }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .frame(width: 44, height: 36)
                            .background(Capsule().fill(Theme.Palette.controlFill))
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .glassCard()
    }

    private func stepper(label: String, value: String,
                         onMinus: @escaping () -> Void, onPlus: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            Button(action: onMinus) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.textSecondary)

            VStack(spacing: 0) {
                Text(value)
                    .font(.numeric(17))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .frame(maxWidth: .infinity)

            Button(action: onPlus) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 34, height: 38)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.Palette.accent)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                .fill(Theme.Palette.controlFill)
        }
    }

    private var finishButton: some View {
        PrimaryButton(title: "Finish workout", icon: "checkmark",
                      enabled: !(session?.sets.isEmpty ?? true)) {
            confirmFinish = true
        }
    }

    // MARK: - Actions

    private func logSet(exercise: Exercise, weight: Double, reps repCount: Int) {
        env.logSet(exercise: exercise.name, reps: repCount, weightKg: weight)

        // Celebrate a genuine PR, checked against everything logged before now.
        let candidate = SetLog(exercise: exercise.name, reps: repCount, weightKg: weight)
        if candidate.countsForPR {
            let previousBest = env.strength.personalBest(for: exercise.name)?.estimatedOneRepMax ?? 0
            if candidate.estimatedOneRepMax > previousBest, previousBest > 0 {
                withAnimation(Theme.Motion.spring) {
                    prBanner = "New PR on \(exercise.name) — \(StrengthHistory.formatWeight(weight)) × \(repCount)."
                }
                Haptics.success()
            }
        }
    }

    private func adjustWeight(_ exercise: String, by delta: Double) {
        let current = weights[exercise] ?? 20
        weights[exercise] = max(0, current + delta)
        Haptics.tap()
    }

    private func adjustReps(_ exercise: String, by delta: Int, exercise target: Exercise) {
        let current = reps[exercise] ?? defaultReps(for: target)
        reps[exercise] = max(1, current + delta)
        Haptics.tap()
    }

    private func defaultReps(for exercise: Exercise) -> Int {
        StrengthHistory.upperBound(of: exercise.reps) ?? 8
    }

    /// Pre-fill each lift with what was used last time, so a repeat session is
    /// just "Log set" over and over.
    private func seedFromHistory() {
        for exercise in day.exercises {
            let last = env.strength.lastPerformance(of: exercise.name)
            if let heaviest = last.max(by: { $0.weightKg < $1.weightKg }) {
                weights[exercise.name] = heaviest.weightKg
                reps[exercise.name] = heaviest.reps
            } else {
                weights[exercise.name] = 20
                reps[exercise.name] = defaultReps(for: exercise)
            }
        }
    }
}

/// Simple wrapping row — set chips should flow onto multiple lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
