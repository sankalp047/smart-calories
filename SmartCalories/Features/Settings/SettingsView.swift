import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var showProfileEditor = false
    @State private var goalText = ""
    @State private var showGoalEditor = false
    @State private var notificationsAuthorized = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    profileCard
                    appearanceCard
                    goalCard
                    remindersCard
                    aiCard
                    aboutCard
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showProfileEditor) { ProfileEditorView() }
            .alert("Daily calorie goal", isPresented: $showGoalEditor) {
                TextField("kcal", text: $goalText).keyboardType(.numberPad)
                Button("Use this") {
                    if let value = Int(goalText), value > 0 {
                        env.settings.calorieGoalOverride = value
                        env.saveSettings()
                    }
                }
                Button("Reset to calculated") {
                    env.settings.calorieGoalOverride = nil
                    env.saveSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Leave this on the calculated target unless you have a reason to override it.")
            }
            .task { notificationsAuthorized = await env.notifications.authorizationStatus() == .authorized }
        }
    }

    // MARK: - Cards

    /// Light / dark / follow-the-system. The segmented control animates the
    /// whole app because every palette token is a dynamic color.
    private var appearanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("APPEARANCE").font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(spacing: 8) {
                ForEach(Appearance.allCases) { option in
                    Button {
                        Haptics.tap()
                        withAnimation(Theme.Motion.snappy) {
                            env.settings.appearance = option
                            env.saveSettings()
                        }
                    } label: {
                        let selected = (env.settings.appearance ?? .system) == option
                        VStack(spacing: 5) {
                            Image(systemName: option.icon)
                                .font(.system(size: 15, weight: .semibold))
                            Text(option.label)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(selected ? Theme.Palette.onAccent : Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(selected ? AnyShapeStyle(Theme.Grad.accent)
                                               : AnyShapeStyle(Theme.Palette.controlFill))
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
        }
        .glassCard()
    }

    private var profileCard: some View {
        Button {
            Haptics.tap()
            showProfileEditor = true
        } label: {
            HStack(spacing: 13) {
                Image(systemName: "person.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.Palette.onAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.Grad.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your profile")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    if let p = env.profile {
                        Text("\(Int(p.heightCm)) cm · \(String(format: "%.1f", p.weightKg)) kg · \(p.age) · \(p.goal.label)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
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

    private var goalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DAILY TARGET").font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(env.calorieGoal))")
                    .font(.numeric(34))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("kcal")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Button("Change") {
                    goalText = "\(Int(env.calorieGoal))"
                    showGoalEditor = true
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            }
            Text(env.settings.calorieGoalOverride == nil
                 ? "Calculated from your profile and goal."
                 : "Manually overridden.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .glassCard()
    }

    private var remindersCard: some View {
        @Bindable var environment = env
        return VStack(alignment: .leading, spacing: 12) {
            Text("REMINDERS").font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)

            if !notificationsAuthorized {
                Button {
                    Task {
                        notificationsAuthorized = await env.notifications.requestAuthorization()
                        if notificationsAuthorized { env.rescheduleCheckIn() }
                    }
                } label: {
                    Text("Enable notifications")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
            }

            Toggle(isOn: $environment.settings.mealRemindersEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Meal logging").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Nudges at breakfast, lunch and dinner")
                        .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .tint(Theme.Palette.accent)

            Toggle(isOn: $environment.settings.goalCheckInEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Evening check-in").font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("How you're tracking against your goal")
                        .font(.system(size: 11)).foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .tint(Theme.Palette.accent)
        }
        .glassCard()
        .onChange(of: env.settings) { _, _ in
            env.saveSettings()
            env.rescheduleCheckIn()
        }
    }

    private var aiCard: some View {
        let onDevice = OnDeviceAI.availability
        return VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 7) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("AI & PRIVACY").font(.eyebrow).kerning(1.1)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }

            // Which engine is actually answering, so the behaviour isn't a
            // mystery — on-device is free, private and works offline.
            HStack(spacing: 9) {
                Image(systemName: onDevice.isAvailable ? "cpu.fill" : "cloud.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(onDevice.isAvailable ? Theme.Palette.accent : Theme.Palette.protein)
                VStack(alignment: .leading, spacing: 1) {
                    Text(onDevice.isAvailable ? "On-device intelligence" : "Cloud intelligence")
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(onDevice.isAvailable
                         ? "Apple Intelligence — nothing leaves your phone"
                         : onDevice.reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(11)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill((onDevice.isAvailable ? Theme.Palette.accent : Theme.Palette.protein)
                        .opacity(0.10))
            }

            Text("Label photos are read on your device and never uploaded — only the extracted text is sent. When a request does go to the cloud it runs through our own server, so no API credentials are ever stored in the app.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard()
    }

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SMART CALORIES").font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("Nutrition data from the USDA National Nutrient Database (SR28) and Open Food Facts. Label text is read entirely on device.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }
}

// MARK: - Profile editing

struct ProfileEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var age = 30.0
    @State private var heightCm = 175.0
    @State private var weightKg = 75.0
    @State private var sex: Sex = .male
    @State private var activity: ActivityLevel = .moderate
    @State private var goal: FitnessGoal = .maintain

    private var draft: UserProfile {
        UserProfile(heightCm: heightCm, weightKg: weightKg, age: Int(age),
                    sex: sex, activity: activity, goal: goal)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("Sex") {
                        Picker("", selection: $sex) {
                            ForEach(Sex.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    field("Age · \(Int(age)) years") {
                        Slider(value: $age, in: 13...100, step: 1).tint(Theme.Palette.accent)
                    }
                    field("Height · \(Int(heightCm)) cm") {
                        Slider(value: $heightCm, in: 120...220, step: 1).tint(Theme.Palette.accent)
                    }
                    field("Weight · \(String(format: "%.1f", weightKg)) kg") {
                        Slider(value: $weightKg, in: 35...250, step: 0.5).tint(Theme.Palette.accent)
                    }
                    field("Goal") {
                        Picker("", selection: $goal) {
                            ForEach(FitnessGoal.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                    field("Activity") {
                        Picker("", selection: $activity) {
                            ForEach(ActivityLevel.allCases) { Text($0.label).tag($0) }
                        }.pickerStyle(.menu).tint(Theme.Palette.accent)
                    }

                    VStack(spacing: 4) {
                        Text("NEW DAILY TARGET").font(.eyebrow).kerning(1.2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text("\(draft.recommendedCalories) kcal")
                            .font(.numeric(30))
                            .foregroundStyle(Theme.Grad.accent)
                            .contentTransition(.numericText())
                    }
                    .frame(maxWidth: .infinity)
                    .glassCard()

                    PrimaryButton(title: "Save changes", icon: "checkmark") {
                        env.saveProfile(draft)
                        dismiss()
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Edit profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .onAppear {
                guard let p = env.profile else { return }
                age = Double(p.age); heightCm = p.heightCm; weightKg = p.weightKg
                sex = p.sex; activity = p.activity; goal = p.goal
            }
        }
    }

    private func field<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased()).font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
