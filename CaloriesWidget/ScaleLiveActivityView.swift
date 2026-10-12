import SwiftUI
import WidgetKit
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
/// Lock Screen and Dynamic Island presentation of the live scale reading.
@available(iOS 16.2, *)
struct ScaleLiveActivityWidget: Widget {
    private let accent = Color(red: 0.204, green: 0.831, blue: 0.600)

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ScaleActivityAttributes.self) { context in
            // Lock Screen / banner
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.attributes.foodName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(context.state.isStable ? "Stable" : "Weighing…")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(context.state.displayWeight)
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                    Text(context.state.displayCalories)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .activityBackgroundTint(Color.black.opacity(0.55))
            .activitySystemActionForegroundColor(accent)

        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.attributes.foodName, systemImage: "scalemass.fill")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.displayCalories)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.displayWeight)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(accent)
                        .contentTransition(.numericText())
                }
            } compactLeading: {
                Image(systemName: "scalemass.fill").foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.displayWeight)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                    .contentTransition(.numericText())
            } minimal: {
                Image(systemName: "scalemass.fill").foregroundStyle(accent)
            }
        }
    }
}
#endif
