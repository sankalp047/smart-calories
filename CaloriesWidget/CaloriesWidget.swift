import WidgetKit
import SwiftUI

/// Home-screen widget showing today's calorie budget.
///
/// It reads a small snapshot the app publishes into the shared App Group
/// (see `WidgetBridge`), so it renders instantly without launching the app or
/// touching the full data store.
private let appGroup = "group.com.sankalpsingh.smartcalories"

struct CalorieSnapshot: TimelineEntry {
    let date: Date
    let eaten: Int
    let goal: Int
    let remaining: Int
    let burned: Int

    var progress: Double { goal > 0 ? min(Double(eaten) / Double(goal), 1) : 0 }
    var isOver: Bool { eaten > goal }

    static let placeholder = CalorieSnapshot(
        date: Date(), eaten: 1240, goal: 2400, remaining: 1160, burned: 480)
}

struct CalorieProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalorieSnapshot { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (CalorieSnapshot) -> Void) {
        completion(context.isPreview ? .placeholder : read())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CalorieSnapshot>) -> Void) {
        // The app pushes a reload whenever anything changes; this periodic
        // refresh is only a safety net for a long gap between launches.
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date()
        completion(Timeline(entries: [read()], policy: .after(next)))
    }

    private func read() -> CalorieSnapshot {
        let defaults = UserDefaults(suiteName: appGroup)
        let goal = defaults?.integer(forKey: "calories_goal") ?? 0
        let eaten = defaults?.integer(forKey: "calories_eaten") ?? 0
        return CalorieSnapshot(
            date: Date(),
            eaten: eaten,
            goal: goal > 0 ? goal : 2000,
            remaining: defaults?.object(forKey: "calories_remaining") != nil
                ? defaults!.integer(forKey: "calories_remaining")
                : max(0, (goal > 0 ? goal : 2000) - eaten),
            burned: defaults?.integer(forKey: "calories_burned") ?? 0
        )
    }
}

// MARK: - Views

private let accent = Color(red: 0.204, green: 0.831, blue: 0.600)
private let burnColor = Color(red: 0.984, green: 0.573, blue: 0.235)

struct CaloriesWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalorieSnapshot

    var body: some View {
        switch family {
        case .systemMedium: medium
        case .accessoryCircular: circular
        case .accessoryInline: Text("\(entry.remaining) kcal left")
        default: small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("SMART CALORIES", systemImage: "flame.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .labelStyle(.titleOnly)
            Spacer(minLength: 0)
            Text("\(entry.remaining)")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(entry.isOver ? "kcal over" : "kcal left")
                .font(.caption2)
                .foregroundStyle(.secondary)
            ProgressView(value: entry.progress)
                .tint(entry.isOver ? .red : accent)
            Text("\(entry.eaten) / \(entry.goal)")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SMART CALORIES")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 0) {
                stat("Eaten", entry.eaten, "fork.knife", accent)
                Spacer(minLength: 0)
                stat("Burned", entry.burned, "flame.fill", burnColor)
                Spacer(minLength: 0)
                stat("Left", entry.remaining, "target",
                     entry.isOver ? .red : .primary)
            }

            Spacer(minLength: 0)
            ProgressView(value: entry.progress)
                .tint(entry.isOver ? .red : accent)
            Text("\(entry.eaten) of \(entry.goal) kcal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .containerBackground(for: .widget) { Color(.systemBackground) }
    }

    private func stat(_ label: String, _ value: Int, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
            Text("\(value)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6)
                .lineLimit(1)
        }
    }

    /// Lock Screen / watch-style complication.
    private var circular: some View {
        Gauge(value: entry.progress) {
            Image(systemName: "flame.fill")
        } currentValueLabel: {
            Text("\(entry.remaining)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
        }
        .gaugeStyle(.accessoryCircular)
        .containerBackground(for: .widget) { Color.clear }
    }
}

struct CaloriesWidget: Widget {
    let kind = "CaloriesWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CalorieProvider()) { entry in
            CaloriesWidgetView(entry: entry)
        }
        .configurationDisplayName("Calories Left")
        .description("Today's calorie budget at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline])
    }
}

@main
struct CaloriesWidgetBundle: WidgetBundle {
    var body: some Widget {
        CaloriesWidget()
        if #available(iOS 16.2, *) {
            ScaleLiveActivityWidget()
        }
    }
}
