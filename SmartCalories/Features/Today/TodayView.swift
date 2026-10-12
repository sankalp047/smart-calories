import SwiftUI

struct TodayView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var showSettings = false
    @State private var showHistory = false
    @State private var aiSheet: AISheetRequest?

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Late night"
        }
    }

    var body: some View {
        ScreenScaffold(title: greeting, subtitle: Date().formatted(.dateTime.weekday(.wide).month().day())) {
            content
        } trailing: {
            HStack(spacing: 8) {
                CircleIconButton(icon: "clock.arrow.circlepath") { showHistory = true }
                CircleIconButton(icon: "gearshape.fill") { showSettings = true }
            }
        }
        .screenBackground()
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .sheet(item: $aiSheet) { AIResultSheet(request: $0) }
        .task { await env.refreshHealth() }
        .refreshable { await env.refreshHealth() }
    }

    @ViewBuilder
    private var content: some View {
        if env.streak > 0 {
            BadgePill(icon: "flame.fill", text: "\(env.streak)-day logging streak")
        }

        CalorieRing(eaten: env.caloriesToday, goal: env.calorieGoal, burned: env.burnedToday)

        macros
        water
        insight
        quickActions

        SectionHeader(title: "Today's food",
                      action: env.todayEntries.isEmpty ? nil : { showHistory = true },
                      actionLabel: "History")
        diaryList
    }

    // MARK: - Macros

    private var macros: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Macros").font(.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if let p = env.profile {
                    Text("\(Int(env.proteinToday))/\(p.proteinTargetG)g protein")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            MacroBar(label: "Protein", grams: env.proteinToday,
                     target: env.profile.map { Double($0.proteinTargetG) },
                     tint: Theme.Palette.protein)
            MacroBar(label: "Carbs", grams: env.carbsToday,
                     target: env.profile.map { Double($0.carbTargetG) },
                     tint: Theme.Palette.carbs)
            MacroBar(label: "Fat", grams: env.fatToday,
                     target: env.profile.map { Double($0.fatTargetG) },
                     tint: Theme.Palette.fat)
        }
        .glassCard()
    }

    // MARK: - Water

    private var water: some View {
        let target = env.waterTarget
        let current = env.waterToday
        return VStack(spacing: 12) {
            HStack {
                HStack(spacing: 7) {
                    Image(systemName: "drop.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(hex: 0x38BDF8))
                    Text("Water").font(.cardTitle).foregroundStyle(Theme.Palette.textPrimary)
                }
                Spacer()
                Text("\(Int(current)) / \(Int(target)) ml")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .contentTransition(.numericText())
            }

            ProgressCapsule(value: current, total: target, tint: Color(hex: 0x38BDF8))

            HStack(spacing: 8) {
                ForEach([250, 500], id: \.self) { amount in
                    Button {
                        withAnimation(Theme.Motion.spring) { env.addWater(Double(amount)) }
                    } label: {
                        Text("+\(amount) ml")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Color(hex: 0x38BDF8))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Color(hex: 0x38BDF8).opacity(0.14)))
                    }
                    .buttonStyle(PressableStyle())
                }
                Button {
                    withAnimation(Theme.Motion.spring) { env.addWater(-250) }
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 42, height: 34)
                        .background(Capsule().fill(Theme.Palette.controlFill))
                }
                .buttonStyle(PressableStyle())
                .disabled(current <= 0)
            }
        }
        .glassCard()
    }

    // MARK: - Status insight

    private var insight: some View {
        let eaten = env.caloriesToday
        let goal = env.calorieGoal
        let goalType = env.profile?.goal ?? .maintain

        let (icon, tint, title, detail): (String, Color, String, String) = {
            if eaten <= 0 {
                return ("sparkles", Theme.Palette.textSecondary, "Nothing logged yet",
                        "Your target today is \(Int(goal)) kcal.")
            }
            if goalType == .gain {
                return eaten >= goal - 100
                    ? ("checkmark.circle.fill", Theme.Palette.accent, "On track to build",
                       "You've hit your surplus for the day.")
                    : ("arrow.up.circle.fill", Theme.Palette.carbs, "Eat a bit more",
                       "\(Int(goal - eaten)) kcal to reach your building target.")
            }
            if eaten <= goal + 50 {
                return ("checkmark.circle.fill", Theme.Palette.accent, "On track",
                        goalType == .lose ? "Comfortably inside your deficit."
                                          : "Right around your target.")
            }
            return ("exclamationmark.triangle.fill", Theme.Palette.alert, "Over your target",
                    "\(Int(eaten - goal)) kcal above plan today.")
        }()

        return HStack(spacing: 13) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(detail).font(.system(size: 12.5))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .glassCard(tint: tint)
    }

    // MARK: - Quick actions

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickAction("sparkles", "What should\nI eat?") {
                let remainingProtein = env.profile.map { Double($0.proteinTargetG) - env.proteinToday }
                aiSheet = AISheetRequest(
                    title: "What should I eat?",
                    icon: "fork.knife",
                    run: { ai in
                        try await ai.suggestMeal(
                            remainingKcal: max(0, env.remainingToday),
                            remainingProtein: remainingProtein,
                            goal: env.profile?.goal.label ?? "general fitness"
                        )
                    }
                )
            }
            quickAction("chart.line.uptrend.xyaxis", "Weekly\ninsight") {
                aiSheet = AISheetRequest(
                    title: "Your week",
                    icon: "chart.line.uptrend.xyaxis",
                    run: { ai in
                        try await ai.weeklyInsight(summary: weekSummary())
                    }
                )
            }
        }
    }

    private func quickAction(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .glassCard(radius: Theme.Radius.md, padding: 14)
        }
        .buttonStyle(PressableStyle())
    }

    private func copyLabel(_ day: Date) -> String {
        Calendar.current.isDateInYesterday(day)
            ? "yesterday's food"
            : day.formatted(.dateTime.weekday(.wide)) + "'s food"
    }

    private func weekSummary() -> String {
        var text = "Daily calorie goal: \(Int(env.calorieGoal)) kcal.\nLast 7 days:\n"
        let cal = Calendar.current
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let entries = env.entries(on: day)
            let kcal = Int(env.calories(on: day))
            let protein = Int(entries.reduce(0) { $0 + ($1.protein ?? 0) })
            text += "\(day.formatted(.dateTime.month().day())): \(kcal) kcal, \(protein)g protein, \(entries.count) items\n"
        }
        return text
    }

    // MARK: - Diary

    @ViewBuilder
    private var diaryList: some View {
        let entries = env.todayEntries
        if entries.isEmpty {
            VStack(spacing: 12) {
                EmptyStateView(
                    icon: "fork.knife",
                    title: "Nothing logged yet",
                    message: "Search a food, scan a barcode, or put something on your scale to get started."
                )
                if let previous = env.previousLoggedDay() {
                    SecondaryButton(title: "Copy \(copyLabel(previous))", icon: "doc.on.doc") {
                        withAnimation(Theme.Motion.spring) { env.copyDay(previous) }
                    }
                }
            }
            .glassCard()
        } else {
            VStack(spacing: 8) {
                ForEach(DiaryEntry.Meal.allCases) { meal in
                    let mealEntries = entries.filter { $0.meal == meal }
                    if !mealEntries.isEmpty {
                        mealSection(meal, mealEntries)
                    }
                }
            }
        }
    }

    private func mealSection(_ meal: DiaryEntry.Meal, _ entries: [DiaryEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: meal.icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.Palette.accent)
                Text(meal.label)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                Text("\(Int(entries.reduce(0) { $0 + $1.calories })) kcal")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }

            ForEach(entries) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.foodName)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text("\(Int(entry.grams)) g · \(entry.date.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int(entry.calories))")
                        .font(.numeric(15))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Button {
                        withAnimation(Theme.Motion.spring) { env.delete(entry) }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }
        }
        .glassCard(radius: Theme.Radius.md)
    }
}

// MARK: - AI sheet plumbing

struct AISheetRequest: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let run: (AIService) async throws -> String
}

/// Presents a streamed-in AI answer with proper loading and failure states.
struct AIResultSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let request: AISheetRequest

    @State private var text: String?
    @State private var error: String?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if isLoading {
                        VStack(spacing: 14) {
                            ProgressView().tint(Theme.Palette.accent)
                            Text("Thinking…")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else if let error {
                        InlineMessage(kind: .error, text: error)
                    } else if let text {
                        Text(text)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassCard()
                    }
                }
                .padding(16)
            }
            .screenBackground()
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { Task { await load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            text = try await request.run(env.ai)
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}
