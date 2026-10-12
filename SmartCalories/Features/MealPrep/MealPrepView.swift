import SwiftUI

/// Batch cooking calculator: total a multi-ingredient batch, then split it
/// across the portions it actually made.
struct MealPrepView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var showRecipes = false
    @State private var showSaveDialog = false
    @State private var recipeName = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if env.prepIngredients.isEmpty {
                        EmptyStateView(
                            icon: "takeoutbag.and.cup.and.straw.fill",
                            title: "Build a batch",
                            message: "Weigh each ingredient and tap “Add to meal prep”. Everything totals here, then splits across the portions you cooked."
                        )
                        .glassCard()
                    } else {
                        SectionHeader(title: "Ingredients")
                        ingredients
                        batchTotal
                        servingsStepper
                        perServing
                        actions
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("Meal prep")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showRecipes = true } label: { Image(systemName: "book.fill") }
                }
            }
            .sheet(isPresented: $showRecipes) { RecipesView() }
            .alert("Save as recipe", isPresented: $showSaveDialog) {
                TextField("Recipe name", text: $recipeName)
                Button("Save") {
                    guard !recipeName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    env.saveRecipe(name: recipeName)
                    recipeName = ""
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private var ingredients: some View {
        VStack(spacing: 8) {
            ForEach(env.prepIngredients) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(.rowTitle)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text("\(Int(item.grams)) g")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int(item.calories)) kcal")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Button {
                        withAnimation(Theme.Motion.spring) {
                            env.prepIngredients.removeAll { $0.id == item.id }
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
                .glassCard(radius: Theme.Radius.sm, padding: 12)
            }
        }
    }

    private var batchTotal: some View {
        VStack(spacing: 6) {
            Text("WHOLE BATCH").font(.eyebrow).kerning(1.2)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text("\(Int(env.prepTotalCalories))")
                .font(.numeric(34))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text("kcal · \(Int(env.prepTotalGrams)) g total")
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard()
    }

    private var servingsStepper: some View {
        HStack {
            Text("How many servings?")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            Button {
                Haptics.tap()
                env.prepServings = max(1, env.prepServings - 1)
            } label: {
                Image(systemName: "minus.circle.fill").font(.system(size: 24))
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            .buttonStyle(.plain)
            Text("\(env.prepServings)")
                .font(.numeric(22))
                .foregroundStyle(Theme.Palette.textPrimary)
                .frame(minWidth: 38)
                .contentTransition(.numericText())
            Button {
                Haptics.tap()
                env.prepServings = min(99, env.prepServings + 1)
            } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 24))
                    .foregroundStyle(Theme.Palette.accent)
            }
            .buttonStyle(.plain)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    private var perServing: some View {
        VStack(spacing: 5) {
            Text("PER SERVING").font(.eyebrow).kerning(1.2)
                .foregroundStyle(Theme.Palette.onAccent.opacity(0.65))
            Text("\(Int(env.prepPerServingCalories))")
                .font(.numeric(46, .heavy))
                .foregroundStyle(Theme.Palette.onAccent)
                .contentTransition(.numericText())
            Text("kcal · \(Int(env.prepPerServingGrams)) g")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.onAccent.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous)
                .fill(Theme.Grad.accent)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            PrimaryButton(title: "Log one serving", icon: "plus") {
                let servings = Double(max(1, env.prepServings))
                env.log(DiaryEntry(
                    foodId: "mealprep_\(UUID().uuidString.prefix(6))",
                    foodName: "Meal prep serving",
                    grams: env.prepPerServingGrams,
                    calories: env.prepPerServingCalories,
                    protein: env.prepTotalProtein / servings,
                    fat: env.prepTotalFat / servings,
                    carbs: env.prepTotalCarbs / servings
                ))
            }
            HStack(spacing: 10) {
                SecondaryButton(title: "Save recipe", icon: "bookmark.fill") {
                    showSaveDialog = true
                }
                SecondaryButton(title: "Clear", icon: "trash") {
                    withAnimation(Theme.Motion.spring) {
                        env.prepIngredients.removeAll()
                        env.prepServings = 1
                    }
                }
            }
        }
    }
}

// MARK: - Saved recipes

struct RecipesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if env.recipes.isEmpty {
                        EmptyStateView(icon: "book.closed.fill",
                                       title: "No recipes yet",
                                       message: "Build a batch in meal prep and save it — then it's one tap forever after.")
                            .glassCard()
                    } else {
                        ForEach(env.recipes) { recipe in
                            recipeCard(recipe)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("My recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
    }

    private func recipeCard(_ recipe: Recipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(recipe.name)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("\(Int(recipe.perServingCalories)) kcal/serving · \(recipe.servings) servings")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Button {
                    withAnimation(Theme.Motion.spring) { env.deleteRecipe(recipe) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                SecondaryButton(title: "Log serving", icon: "plus") {
                    env.log(DiaryEntry(
                        foodId: "recipe_\(recipe.id)",
                        foodName: "\(recipe.name) (1 serving)",
                        grams: recipe.perServingGrams,
                        calories: recipe.perServingCalories,
                        protein: recipe.perServingProtein,
                        fat: recipe.perServingFat,
                        carbs: recipe.perServingCarbs
                    ))
                }
                SecondaryButton(title: "Edit in prep", icon: "square.and.pencil") {
                    env.loadIntoPrep(recipe)
                    dismiss()
                }
            }
        }
        .glassCard()
    }
}
