import SwiftUI

struct WorkoutsView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var selectedPlan: WorkoutPlan?
    @State private var showEquipment = false
    @State private var isGenerating = false
    @State private var errorMessage: String?
    @State private var showHistory = false

    private var recommended: WorkoutPlan { WorkoutCatalog.recommended(for: env.profile) }

    var body: some View {
        ScreenScaffold(title: "Train", subtitle: env.profile.map { "Built around \($0.goal.phrase)" }) {
            content
        } trailing: {
            CircleIconButton(icon: "clock.arrow.circlepath") { showHistory = true }
        }
        .screenBackground()
        .sheet(isPresented: $showHistory) { TrainingHistoryView() }
        .navigationDestinationCompat(item: $selectedPlan) { WorkoutDetailView(plan: $0) }
        .sheet(isPresented: $showEquipment) {
            EquipmentBuilderView { plan in selectedPlan = plan }
        }
    }

    @ViewBuilder
    private var content: some View {
        aiCard

        if let errorMessage {
            InlineMessage(kind: .error, text: errorMessage)
        }

        SectionHeader(title: "Recommended for you")
        PlanCard(plan: recommended, highlighted: true) { selectedPlan = recommended }

        SectionHeader(title: "All programs")
        VStack(spacing: 10) {
            ForEach(WorkoutCatalog.all.filter { $0.id != recommended.id }) { plan in
                PlanCard(plan: plan) { selectedPlan = plan }
            }
        }
    }

    private var aiCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("Want something built for you?")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Text("Generate a program around your goal and experience — or around the equipment your gym actually has.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PrimaryButton(title: "Generate a plan", icon: "wand.and.stars", isLoading: isGenerating) {
                Task { await generate() }
            }
            SecondaryButton(title: "Build from my gym's equipment", icon: "dumbbell.fill") {
                showEquipment = true
            }
        }
        .glassCard(tint: Theme.Palette.accent)
    }

    private func generate() async {
        isGenerating = true
        errorMessage = nil
        do {
            let profile = env.profile
            selectedPlan = try await env.ai.generateWorkout(
                goal: profile?.goal.label ?? "general fitness",
                level: levelString(profile),
                sex: profile?.sex.label ?? "unspecified",
                context: contextString(profile),
                equipment: nil
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isGenerating = false
    }
}

func levelString(_ profile: UserProfile?) -> String {
    switch profile?.activity {
    case .active, .veryActive: "advanced"
    case .moderate: "intermediate"
    default: "beginner"
    }
}

func contextString(_ profile: UserProfile?) -> String {
    guard let profile else { return "No profile provided." }
    return "Age \(profile.age), \(profile.sex.label), \(profile.activity.label.lowercased()) activity, BMI \(String(format: "%.0f", profile.bmi))."
}

// MARK: - Plan card

struct PlanCard: View {
    let plan: WorkoutPlan
    var highlighted: Bool = false
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(plan.name)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Text(plan.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    tag(plan.level.label, "chart.bar.fill")
                    tag("\(plan.daysPerWeek)×/week", "calendar")
                    tag(plan.goal.label, plan.goal.icon)
                }
            }
            .glassCard(tint: highlighted ? Theme.Palette.accent : nil)
        }
        .buttonStyle(PressableStyle())
    }

    private func tag(_ text: String, _ icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(Theme.Palette.textSecondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill(Theme.Palette.controlFill))
    }
}

// MARK: - Detail

struct WorkoutDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let plan: WorkoutPlan

    @State private var sendingDay: String?
    @State private var banner: (text: String, ok: Bool)?
    @State private var activeDay: WorkoutDay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(plan.name)
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(plan.summary)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.carbs)
                    Text(plan.guidance(for: env.profile))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .glassCard(tint: Theme.Palette.carbs)

                if let banner {
                    InlineMessage(kind: banner.ok ? .success : .error, text: banner.text)
                }

                ForEach(Array(plan.days.enumerated()), id: \.element.id) { index, day in
                    dayCard(index: index, day: day)
                }
            }
            .padding(16)
            .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
        }
        .fullScreenCover(item: $activeDay) { day in
            WorkoutSessionView(plan: plan, day: day)
        }
    }

    private func send(_ day: WorkoutDay) async {
        sendingDay = day.id
        defer { sendingDay = nil }

        // Schedule for the next full hour so it isn't placed in the past.
        let target = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        let result = await WatchWorkoutService.send(day: day, from: plan, at: target)

        switch result {
        case .scheduled(let name):
            banner = ("“\(name)” is on your Apple Watch — open the Workout app to start it.", true)
            Haptics.success()
        case .notAuthorized:
            banner = ("Allow Smart Calories to schedule workouts to use this.", false)
        case .unsupported:
            banner = ("Sending workouts needs iOS 17 or later.", false)
        case .failed(let message):
            banner = (message, false)
        }
    }

    private func dayCard(index: Int, day: WorkoutDay) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.Grad.accent))
                Text(day.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }

            Button {
                Haptics.tap()
                env.startSession(plan: plan, day: day)
                activeDay = day
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text("Start workout").font(.system(size: 13, weight: .bold, design: .rounded))
                }
                .foregroundStyle(Theme.Palette.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(Theme.Grad.accent))
            }
            .buttonStyle(PressableStyle())
            .padding(.bottom, 2)

            if WatchWorkoutService.isSupported {
                Button {
                    Task { await send(day) }
                } label: {
                    HStack(spacing: 7) {
                        if sendingDay == day.id {
                            ProgressView().controlSize(.mini).tint(Theme.Palette.accent)
                        } else {
                            Image(systemName: "applewatch")
                                .font(.system(size: 12, weight: .bold))
                        }
                        Text(sendingDay == day.id ? "Sending…" : "Send to Apple Watch")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Palette.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Theme.Palette.accent.opacity(0.13)))
                }
                .buttonStyle(PressableStyle())
                .disabled(sendingDay != nil)
                .padding(.bottom, 2)
            }

            ForEach(day.exercises) { exercise in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        Text(exercise.name)
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        Spacer(minLength: 8)
                        Text("\(exercise.sets) × \(exercise.reps)")
                            .font(.system(size: 12.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Palette.accent)
                            .fixedSize()
                    }
                    if !exercise.notes.isEmpty {
                        Text(exercise.notes)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .glassCard()
    }
}
