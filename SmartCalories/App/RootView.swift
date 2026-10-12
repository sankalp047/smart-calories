import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Group {
            if !env.auth.isSignedIn {
                SignInView()
                    .transition(.opacity)
            } else if env.isRestoring {
                RestoringView(restoredCount: 0)
                    .transition(.opacity)
            } else if env.settings.hasCompletedOnboarding, env.profile != nil {
                MainTabView()
                    .transition(.opacity.combined(with: .scale(scale: 1.02)))
            } else {
                OnboardingView()
                    .transition(.opacity)
            }
        }
        .animation(Theme.Motion.spring, value: env.settings.hasCompletedOnboarding)
        .animation(Theme.Motion.spring, value: env.auth.isSignedIn)
        // A Keychain refresh token outlives app deletion, so this is what
        // silently restores the account (and its data) after a reinstall.
        .task { await env.restoreSessionIfPossible() }
        // nil = follow the system; the palette's dynamic colors do the rest.
        .preferredColorScheme((env.settings.appearance ?? .system).colorScheme)
    }
}

// MARK: - Tabs

enum AppTab: Int, CaseIterable, Identifiable {
    case today, foods, scale, workouts, health
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: "Today"
        case .foods: "Foods"
        case .scale: "Scale"
        case .workouts: "Train"
        case .health: "Health"
        }
    }
    var icon: String {
        switch self {
        case .today: "chart.pie.fill"
        case .foods: "magnifyingglass"
        case .scale: "scalemass.fill"
        case .workouts: "figure.strengthtraining.traditional"
        case .health: "heart.fill"
        }
    }

    /// Allows launching straight to a tab (`-startTab foods`) for UI review.
    static var initialTab: AppTab {
        switch UserDefaults.standard.string(forKey: "startTab") {
        case "foods": .foods
        case "scale": .scale
        case "workouts": .workouts
        case "health": .health
        default: .today
        }
    }
}

/// Detail screens that are normally reached by tapping. Mirrors `startTab`
/// so a reviewer can launch straight into one (`-startSheet training`).
enum ReviewSheet: String {
    case training, weight, history, settings, whoop, watch, insights

    static var initial: ReviewSheet? {
        UserDefaults.standard.string(forKey: "startSheet").flatMap(ReviewSheet.init)
    }
}

struct MainTabView: View {
    @State private var selection: AppTab = .initialTab
    @State private var sheet: ReviewSheet? = ReviewSheet.initial

    var body: some View {
        ZStack(alignment: .bottom) {
            Group {
                switch selection {
                case .today: TodayView()
                case .foods: FoodSearchView()
                case .scale: ScaleView()
                case .workouts: WorkoutsView()
                case .health: HealthView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            FloatingTabBar(selection: $selection)
        }
        .screenBackground()
        .fullScreenCover(item: $sheet) { which in
            switch which {
            case .training: TrainingHistoryView()
            case .weight: WeightView()
            case .history: HistoryView()
            case .settings: SettingsView()
            case .whoop: WhoopDeviceView()
            case .watch: AppleWatchView()
            case .insights: InsightsView()
            }
        }
    }
}

extension ReviewSheet: Identifiable { var id: String { rawValue } }

/// Custom floating tab bar — a glass pill with a sliding selection indicator.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    guard selection != tab else { return }
                    Haptics.tap()
                    withAnimation(Theme.Motion.snappy) { selection = tab }
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(height: 20)
                        Text(tab.title)
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    .foregroundStyle(
                        selection == tab ? Theme.Palette.accent : Theme.Palette.textTertiary
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background {
                        if selection == tab {
                            // Capsule, not a rounded rect: the bar itself is a
                            // capsule, and a capsule inset uniformly inside one
                            // is exactly concentric (inner radius = outer −
                            // inset). A fixed corner radius can't follow the
                            // bar's curve and spills past it on the end tabs.
                            Capsule(style: .continuous)
                                .fill(Theme.Palette.accent.opacity(0.16))
                                .matchedGeometryEffect(id: "tab", in: indicator)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

// MARK: - Shared screen scaffold

/// Consistent large-title header used across the main screens.
struct ScreenScaffold<Content: View, Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.Palette.textSecondary)
                        }
                    }
                    Spacer()
                    trailing()
                }
                .padding(.top, 8)

                content()
            }
            .padding(.horizontal, Theme.Space.md)
            .padding(.bottom, 110)   // clears the floating tab bar
        }
        .scrollIndicators(.hidden)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, content: content, trailing: { EmptyView() })
    }
}

/// Circular icon button used in screen headers.
struct CircleIconButton: View {
    let icon: String
    var tint: Color = Theme.Palette.textPrimary
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay { Circle().strokeBorder(Theme.Palette.hairline, lineWidth: 1) }
                }
        }
        .buttonStyle(PressableStyle())
    }
}
