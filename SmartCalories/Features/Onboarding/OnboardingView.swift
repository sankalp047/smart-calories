import SwiftUI

/// First-run flow: a welcome moment, then a short profile questionnaire that
/// resolves into a personalized calorie target.
struct OnboardingView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var step = 0
    @State private var useMetric = true
    @State private var sex: Sex = .male
    @State private var activity: ActivityLevel = .moderate
    @State private var goal: FitnessGoal = .maintain
    @State private var age = 30.0
    @State private var heightCm = 175.0
    @State private var weightKg = 75.0

    private var draft: UserProfile {
        UserProfile(heightCm: heightCm, weightKg: weightKg, age: Int(age),
                    sex: sex, activity: activity, goal: goal)
    }

    var body: some View {
        ZStack {
            Theme.Grad.screen.ignoresSafeArea()

            VStack(spacing: 0) {
                if step > 0 { progressBar }

                TabView(selection: $step) {
                    welcome.tag(0)
                    basicsStep.tag(1)
                    bodyStep.tag(2)
                    goalStep.tag(3)
                    summaryStep.tag(4)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(Theme.Motion.spring, value: step)

                controls
            }
        }
    }

    // MARK: - Chrome

    private var progressBar: some View {
        HStack(spacing: 6) {
            ForEach(1..<5) { index in
                Capsule()
                    .fill(index <= step ? Theme.Palette.accent : Theme.Palette.controlFill)
                    .frame(height: 4)
                    .animation(Theme.Motion.spring, value: step)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
    }

    private var controls: some View {
        VStack(spacing: 10) {
            PrimaryButton(
                title: step == 0 ? "Get started" : (step == 4 ? "Start tracking" : "Continue"),
                icon: step == 4 ? "checkmark" : nil
            ) {
                if step == 4 {
                    finish()
                } else {
                    withAnimation(Theme.Motion.spring) { step += 1 }
                }
            }
            if step > 0 {
                Button("Back") {
                    withAnimation(Theme.Motion.spring) { step -= 1 }
                }
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
    }

    private func finish() {
        var settings = env.settings
        settings.hasCompletedOnboarding = true
        settings.calorieGoalOverride = nil
        env.settings = settings
        env.saveProfile(draft)
        Haptics.success()
    }

    // MARK: - Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.16))
                    .frame(width: 150, height: 150)
                    .blur(radius: 22)
                Image(systemName: "scalemass.fill")
                    .font(.system(size: 62, weight: .medium))
                    .foregroundStyle(Theme.Grad.accent)
            }

            VStack(spacing: 10) {
                Text("Smart Calories")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text("Weigh it. Scan it.\nKnow exactly what you eat.")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            VStack(spacing: 12) {
                featureRow("scalemass", "Live weight from your scale",
                           "Calories update as you pour.")
                featureRow("barcode.viewfinder", "Scan anything",
                           "Barcodes, labels, or just ask AI.")
                featureRow("heart.fill", "Balance in, balance out",
                           "Apple Health keeps both sides honest.")
            }
            .padding(.top, 8)

            Spacer()
        }
        .padding(.horizontal, 28)
    }

    private func featureRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.Palette.accent.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Spacer()
        }
    }

    private var basicsStep: some View {
        stepScaffold(title: "About you", subtitle: "This sets your calorie target and tailors your training.") {
            VStack(alignment: .leading, spacing: 22) {
                labeled("Sex") {
                    Picker("", selection: $sex) {
                        ForEach(Sex.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                labeled("Age") {
                    valueStepper(value: $age, range: 13...100, step: 1, format: "%.0f", unit: "years")
                }

                labeled("Units") {
                    Picker("", selection: $useMetric) {
                        Text("Metric").tag(true)
                        Text("Imperial").tag(false)
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var bodyStep: some View {
        stepScaffold(title: "Your measurements", subtitle: "Used for BMR, body composition and heart-rate zones.") {
            VStack(alignment: .leading, spacing: 26) {
                labeled(useMetric ? "Height (cm)" : "Height (ft/in)") {
                    if useMetric {
                        valueStepper(value: $heightCm, range: 120...220, step: 1, format: "%.0f", unit: "cm")
                    } else {
                        let totalInches = heightCm / 2.54
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(Int(totalInches / 12))′ \(Int(totalInches.truncatingRemainder(dividingBy: 12)))″")
                                .font(.numeric(30))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Slider(value: $heightCm, in: 120...220, step: 1)
                                .tint(Theme.Palette.accent)
                        }
                    }
                }

                labeled(useMetric ? "Weight (kg)" : "Weight (lb)") {
                    if useMetric {
                        valueStepper(value: $weightKg, range: 35...250, step: 0.5, format: "%.1f", unit: "kg")
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("\(Int((weightKg * 2.20462).rounded())) lb")
                                .font(.numeric(30))
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Slider(value: $weightKg, in: 35...250, step: 0.5)
                                .tint(Theme.Palette.accent)
                        }
                    }
                }
            }
        }
    }

    private var goalStep: some View {
        stepScaffold(title: "Your goal", subtitle: "We'll adjust your daily calories to match.") {
            VStack(spacing: 12) {
                ForEach(FitnessGoal.allCases) { option in
                    selectableRow(
                        title: option.label,
                        subtitle: option.calorieDelta == 0
                            ? "Hold your current weight"
                            : (option.calorieDelta < 0 ? "A \(abs(option.calorieDelta)) kcal daily deficit"
                                                       : "A \(option.calorieDelta) kcal daily surplus"),
                        icon: option.icon,
                        selected: goal == option
                    ) { goal = option }
                }

                Text("How active are you?")
                    .font(.eyebrow)
                    .kerning(1.1)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)

                ForEach(ActivityLevel.allCases) { level in
                    selectableRow(
                        title: level.label,
                        subtitle: level.detail,
                        icon: "figure.walk",
                        selected: activity == level
                    ) { activity = level }
                }
            }
        }
    }

    private var summaryStep: some View {
        stepScaffold(title: "You're all set", subtitle: "Here's the plan we built from your profile.") {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("DAILY TARGET")
                        .font(.eyebrow).kerning(1.2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Text("\(draft.recommendedCalories)")
                        .font(.numeric(56, .heavy))
                        .foregroundStyle(Theme.Grad.accent)
                    Text("kcal per day")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .glassCard(radius: Theme.Radius.lg, padding: 22)

                HStack(spacing: 10) {
                    StatTile(label: "Maintenance", value: "\(Int(draft.tdee))", unit: "kcal",
                             icon: "flame.fill", tint: Theme.Palette.burn)
                    StatTile(label: "BMI", value: String(format: "%.1f", draft.bmi),
                             icon: "figure", tint: Theme.Palette.protein)
                }
                HStack(spacing: 10) {
                    StatTile(label: "Protein target", value: "\(draft.proteinTargetG)", unit: "g",
                             icon: "circle.hexagongrid.fill", tint: Theme.Palette.protein)
                    StatTile(label: "Water", value: String(format: "%.1f", draft.dailyWaterMl / 1000),
                             unit: "L", icon: "drop.fill", tint: Color(hex: 0x38BDF8))
                }
            }
        }
    }

    // MARK: - Building blocks

    private func stepScaffold<C: View>(title: String, subtitle: String,
                                       @ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                .padding(.top, 20)

                content()
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.eyebrow).kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }

    private func valueStepper(value: Binding<Double>, range: ClosedRange<Double>,
                              step: Double, format: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(String(format: format, value.wrappedValue))
                    .font(.numeric(30))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            Slider(value: value, in: range, step: step)
                .tint(Theme.Palette.accent)
        }
    }

    private func selectableRow(title: String, subtitle: String, icon: String,
                               selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            withAnimation(Theme.Motion.snappy) { action() }
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.textTertiary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(selected ? Theme.Palette.accent.opacity(0.16)
                                                       : Theme.Palette.controlFill))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(selected ? Theme.Palette.accent : Theme.Palette.hairline)
            }
            .padding(13)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(selected ? Theme.Palette.accent.opacity(0.09) : Theme.Palette.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                            .strokeBorder(selected ? Theme.Palette.accent.opacity(0.45)
                                                   : Theme.Palette.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(PressableStyle())
    }
}
