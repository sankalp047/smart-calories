import SwiftUI
import Charts

struct HistoryView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var aiSheet: AISheetRequest?

    private var last14: [(date: Date, kcal: Double)] {
        let cal = Calendar.current
        return stride(from: 13, through: 0, by: -1).compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return (cal.startOfDay(for: day), env.calories(on: day))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    if env.loggedDays.isEmpty {
                        EmptyStateView(icon: "clock.arrow.circlepath",
                                       title: "No history yet",
                                       message: "Once you start logging, your days show up here.")
                            .glassCard()
                    } else {
                        SectionHeader(title: "Last 14 days")
                        chart
                        SectionHeader(title: "By day")
                        ForEach(env.loggedDays, id: \.self) { day in
                            daySection(day)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
            .screenBackground()
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        aiSheet = AISheetRequest(title: "Your week", icon: "sparkles") { ai in
                            try await ai.weeklyInsight(summary: summaryText())
                        }
                    } label: { Image(systemName: "sparkles") }
                    .disabled(env.loggedDays.isEmpty)
                }
            }
            .sheet(item: $aiSheet) { AIResultSheet(request: $0) }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(last14, id: \.date) { point in
                BarMark(x: .value("Day", point.date, unit: .day),
                        y: .value("kcal", point.kcal))
                .foregroundStyle(point.kcal > env.calorieGoal
                                 ? AnyShapeStyle(Theme.Grad.alert)
                                 : AnyShapeStyle(Theme.Grad.accent))
                .cornerRadius(5)
            }
            RuleMark(y: .value("Goal", env.calorieGoal))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(Theme.Palette.textTertiary)
                .annotation(position: .top, alignment: .trailing) {
                    Text("goal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: 3)) { _ in
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
        .frame(height: 170)
        .glassCard()
    }

    private func daySection(_ day: Date) -> some View {
        let entries = env.entries(on: day)
        let total = env.calories(on: day)
        return DisclosureGroup {
            VStack(spacing: 7) {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.foodName)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                            Text("\(Int(entry.grams)) g · \(entry.meal.label)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Text("\(Int(entry.calories)) kcal")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label(for: day))
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("\(entries.count) item\(entries.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                Spacer()
                Text("\(Int(total))")
                    .font(.numeric(16))
                    .foregroundStyle(total > env.calorieGoal ? Theme.Palette.alert : Theme.Palette.accent)
            }
        }
        .tint(Theme.Palette.textTertiary)
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }

    private func label(for day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.abbreviated).month().day())
    }

    private func summaryText() -> String {
        var text = "Daily calorie goal: \(Int(env.calorieGoal)) kcal.\nLast 7 days:\n"
        let cal = Calendar.current
        for offset in stride(from: 6, through: 0, by: -1) {
            guard let day = cal.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            let entries = env.entries(on: day)
            let protein = Int(entries.reduce(0) { $0 + ($1.protein ?? 0) })
            text += "\(day.formatted(.dateTime.month().day())): \(Int(env.calories(on: day))) kcal, \(protein)g protein, \(entries.count) items\n"
        }
        return text
    }
}
