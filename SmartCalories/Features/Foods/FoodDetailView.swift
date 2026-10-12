import SwiftUI

/// Live weigh + log screen. Weight comes from the connected scale in real time,
/// with a manual fallback so the flow never dead-ends.
struct FoodDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let food: Food

    @State private var manualMode = false
    @State private var manualGrams = ""
    @State private var meal: DiaryEntry.Meal = .inferred()
    @State private var didLog = false

    /// Grams currently driving the calculation.
    private var grams: Double {
        if manualMode || !env.scale.isConnected {
            return Double(manualGrams) ?? 0
        }
        return env.scale.grams
    }

    private var calories: Double { food.calories(forGrams: grams) }
    private var isLive: Bool { env.scale.isConnected && !manualMode }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header
                weightCard
                caloriesCard
                macros
                nutritionTable
                actions
            }
            .padding(16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .screenBackground()
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.tap()
                    env.toggleFavorite(food, grams: grams)
                } label: {
                    Image(systemName: env.isFavorite(food) ? "star.fill" : "star")
                        .foregroundStyle(env.isFavorite(food) ? Theme.Palette.carbs : Theme.Palette.textSecondary)
                }
            }
        }
        .onAppear {
            env.scale.activate()
            if !env.scale.isConnected { manualMode = true }
        }
        // Live Activity: while a connected scale is driving the number, mirror
        // it to the Lock Screen. Cooking means hands full and phone on the
        // counter — this is exactly when a glanceable readout earns its place.
        .onChange(of: isLive) { _, live in
            if live {
                ScaleLiveActivity.start(food: food, grams: grams)
            } else {
                ScaleLiveActivity.end()
            }
        }
        .onChange(of: env.scale.grams) { _, _ in
            guard isLive else { return }
            ScaleLiveActivity.update(
                grams: grams, calories: calories,
                isStable: env.scale.reading?.isStable ?? false)
        }
        .onDisappear { ScaleLiveActivity.end() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(food.name)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Image(systemName: food.source.icon).font(.system(size: 10, weight: .bold))
                Text(food.source.label)
                Text("·")
                Text(food.category)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.Palette.textTertiary)
        }
    }

    private var weightCard: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLive ? Theme.Palette.accent : Theme.Palette.textTertiary)
                        .frame(width: 7, height: 7)
                        .glow(isLive ? Theme.Palette.accent : .clear, radius: 5, opacity: 0.9)
                    Text(isLive ? "Live from scale" : "Manual entry")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isLive ? Theme.Palette.accent : Theme.Palette.textSecondary)
                }
                Spacer()
                Button(manualMode ? "Use scale" : "Enter by hand") {
                    Haptics.tap()
                    withAnimation(Theme.Motion.snappy) { manualMode.toggle() }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.accent)
            }

            if manualMode || !env.scale.isConnected {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField("0", text: $manualGrams)
                        .keyboardType(.decimalPad)
                        .font(.numeric(52, .heavy))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text("g")
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            } else {
                VStack(spacing: 3) {
                    Text(env.scale.reading?.display ?? "0")
                        .font(.numeric(58, .heavy))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .contentTransition(.numericText())
                        .animation(Theme.Motion.snappy, value: env.scale.grams)
                    Text(env.scale.reading?.unit.label ?? "g")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }

            if !env.scale.isConnected && !manualMode {
                Text("No scale connected — open the Scale tab to pair one.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .glassCard(radius: Theme.Radius.lg, padding: 20)
    }

    private var caloriesCard: some View {
        VStack(spacing: 4) {
            Text("CALORIES FOR \(Int(grams)) G")
                .font(.eyebrow).kerning(1.2)
                .foregroundStyle(Theme.Palette.onAccent.opacity(0.65))
            Text("\(Int(calories))")
                .font(.numeric(52, .heavy))
                .foregroundStyle(Theme.Palette.onAccent)
                .contentTransition(.numericText())
                .animation(Theme.Motion.snappy, value: calories)
            Text("kcal")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.onAccent.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Grad.accent)
        }
        .glow(Theme.Palette.accent, radius: 26, opacity: 0.35)
    }

    private var macros: some View {
        HStack(spacing: 10) {
            macroTile("Protein", food.protein(forGrams: grams), Theme.Palette.protein)
            macroTile("Carbs", food.carbs(forGrams: grams), Theme.Palette.carbs)
            macroTile("Fat", food.fat(forGrams: grams), Theme.Palette.fat)
        }
    }

    private func macroTile(_ label: String, _ value: Double?, _ tint: Color) -> some View {
        VStack(spacing: 5) {
            Text(value.map { "\(Int($0.rounded()))g" } ?? "—")
                .font(.numeric(19))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(tint.opacity(0.11))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1)
                }
        }
    }

    private var nutritionTable: some View {
        VStack(spacing: 0) {
            row("Energy", "\(Int(food.kcalPer100g)) kcal", isFirst: true)
            row("Protein", gram(food.proteinPer100g))
            row("Carbs", gram(food.carbsPer100g))
            row("Fat", gram(food.fatPer100g))
            if let sat = food.saturatedFatPer100g {
                row("— saturated", gram(sat))
            }
            row("Fiber", gram(food.fiberPer100g))
            row("Sugars", gram(food.sugarsPer100g))
            if let sodium = food.sodiumMgPer100g {
                row("Sodium", "\(Int(sodium)) mg")
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
        .overlay(alignment: .topTrailing) {
            Text("per 100 g")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .padding(12)
        }
    }

    private func gram(_ v: Double?) -> String {
        v.map { String(format: "%.1f g", $0) } ?? "—"
    }

    private func row(_ label: String, _ value: String, isFirst: Bool = false) -> some View {
        VStack(spacing: 0) {
            if !isFirst {
                Divider().overlay(Theme.Palette.hairline)
            }
            HStack {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            .padding(.vertical, 9)
        }
    }

    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(DiaryEntry.Meal.allCases.filter { $0 != .other }) { option in
                    FilterChip(title: option.label, selected: meal == option) { meal = option }
                }
            }

            PrimaryButton(
                title: didLog ? "Logged" : "Log \(Int(calories)) kcal",
                icon: didLog ? "checkmark" : "plus",
                enabled: grams > 0
            ) {
                env.log(DiaryEntry(food: food, grams: grams, meal: meal))
                withAnimation(Theme.Motion.spring) { didLog = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { dismiss() }
            }

            SecondaryButton(title: "Add to meal prep", icon: "takeoutbag.and.cup.and.straw.fill") {
                env.prepIngredients.append(
                    RecipeIngredient(
                        name: food.name, grams: grams, calories: calories,
                        protein: food.protein(forGrams: grams),
                        fat: food.fat(forGrams: grams),
                        carbs: food.carbs(forGrams: grams)
                    )
                )
                Haptics.success()
                dismiss()
            }
            .disabled(grams <= 0)
            .opacity(grams > 0 ? 1 : 0.4)
        }
    }
}
