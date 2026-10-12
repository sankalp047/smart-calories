import SwiftUI

struct FoodSearchView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var query = ""
    @State private var category: String?
    @State private var selectedFood: Food?
    @State private var showBarcode = false
    @State private var showLabelScan = false
    @State private var showMealPrep = false
    @State private var aiLoading = false
    @State private var aiError: String?

    private var results: [Food] {
        env.foods.search(query, category: category)
    }

    var body: some View {
        ScreenScaffold(title: "Foods",
                       subtitle: env.foods.isLoaded ? "\(env.foods.foods.count) foods · scan or ask AI" : "Loading database…") {
            content
        } trailing: {
            HStack(spacing: 8) {
                CircleIconButton(icon: "barcode.viewfinder") { showBarcode = true }
                CircleIconButton(icon: "text.viewfinder") { showLabelScan = true }
                CircleIconButton(icon: "takeoutbag.and.cup.and.straw.fill") { showMealPrep = true }
            }
        }
        .screenBackground()
        .navigationDestinationCompat(item: $selectedFood) { FoodDetailView(food: $0) }
        .sheet(isPresented: $showBarcode) {
            BarcodeScannerScreen { food in selectedFood = food }
        }
        .sheet(isPresented: $showLabelScan) {
            LabelScanScreen { food in selectedFood = food }
        }
        .sheet(isPresented: $showMealPrep) { MealPrepView() }
    }

    @ViewBuilder
    private var content: some View {
        searchField

        if !env.favorites.isEmpty && query.isEmpty {
            SectionHeader(title: "Quick add")
            favoritesStrip
        }

        if !env.foods.categories.isEmpty {
            categoryChips
        }

        if let aiError {
            InlineMessage(kind: .error, text: aiError)
        }

        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            askAICard
        }

        if !env.foods.isLoaded {
            ProgressView().tint(Theme.Palette.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 40)
        } else if results.isEmpty {
            EmptyStateView(
                icon: "magnifyingglass",
                title: "No matches",
                message: query.isEmpty ? "Start typing to search the database."
                                       : "Nothing in the database matches that. Try “Ask AI” above."
            )
            .glassCard()
        } else {
            VStack(spacing: 8) {
                ForEach(results) { food in
                    FoodRow(food: food) { selectedFood = food }
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
            TextField("Search foods", text: $query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .foregroundStyle(Theme.Palette.textPrimary)
            if !query.isEmpty {
                Button {
                    query = ""
                    aiError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
        }
    }

    private var favoritesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(env.favorites) { fav in
                    Button {
                        Haptics.success()
                        env.log(DiaryEntry(food: fav.food, grams: fav.lastGrams))
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Theme.Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fav.food.name)
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                Text("\(Int(fav.lastGrams)) g · \(Int(fav.food.calories(forGrams: fav.lastGrams))) kcal")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                        }
                        .frame(maxWidth: 190, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                .fill(Theme.Palette.controlFill)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                                }
                        }
                    }
                    .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(title: "All", selected: category == nil) { category = nil }
                ForEach(env.foods.categories.prefix(18), id: \.self) { cat in
                    FilterChip(title: cat, selected: category == cat) {
                        category = (category == cat) ? nil : cat
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var askAICard: some View {
        Button {
            Task { await askAI() }
        } label: {
            HStack(spacing: 12) {
                if aiLoading {
                    ProgressView().tint(Theme.Palette.accent).frame(width: 20)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Palette.accent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask AI about “\(query)”")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                    Text("Not in the database? Get nutrition estimated for it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .glassCard(radius: Theme.Radius.md, padding: 14, tint: Theme.Palette.accent)
        }
        .buttonStyle(PressableStyle())
        .disabled(aiLoading)
    }

    private func askAI() async {
        aiLoading = true
        aiError = nil
        do {
            let food = try await env.ai.lookupFood(query)
            selectedFood = food
        } catch {
            aiError = error.localizedDescription
        }
        aiLoading = false
    }
}

// MARK: - Row

struct FoodRow: View {
    let food: Food
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(food.name)
                        .font(.rowTitle)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Image(systemName: food.source.icon)
                            .font(.system(size: 9, weight: .bold))
                        Text(food.category)
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(Int(food.kcalPer100g))")
                        .font(.numeric(17))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("per 100 g")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .glassCard(radius: Theme.Radius.md, padding: 13)
        }
        .buttonStyle(PressableStyle())
    }
}

// MARK: - Navigation helper

extension View {
    /// Sheet-based detail presentation, so every entry point (search, scan, AI)
    /// funnels into the same weigh screen without nested navigation stacks.
    func navigationDestinationCompat<Item: Identifiable, Destination: View>(
        item: Binding<Item?>,
        @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View {
        sheet(item: item) { value in
            NavigationStack { destination(value) }
        }
    }
}
