import SwiftUI

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?
    var actionLabel: String = "See all"

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.eyebrow)
                .kerning(1.1)
                .foregroundStyle(Theme.Palette.textTertiary)
            Spacer()
            if let action {
                Button(actionLabel, action: action)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
            }
        }
        .padding(.horizontal, 2)
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil
    var icon: String? = nil
    var tint: Color = Theme.Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.numeric(24))
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
        }
        .glassCard(radius: Theme.Radius.md, padding: 14)
    }
}

// MARK: - Macro bar

struct MacroBar: View {
    let label: String
    let grams: Double?
    let target: Double?
    let tint: Color

    private var progress: Double {
        guard let grams, let target, target > 0 else { return 0 }
        return min(grams / target, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textSecondary)
                Spacer()
                Text(grams.map { "\(Int($0.rounded()))g" } ?? "—")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.Palette.controlFill)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(4, geo.size.width * progress))
                        .glow(tint, radius: 6, opacity: 0.6)
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Buttons

struct PrimaryButton: View {
    let title: String
    var icon: String? = nil
    var gradient: LinearGradient = Theme.Grad.accent
    var isLoading: Bool = false
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView().tint(Theme.Palette.onAccent)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: 15, weight: .bold))
                }
                Text(title).font(.system(size: 16, weight: .bold, design: .rounded))
            }
            .foregroundStyle(Theme.Palette.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(gradient)
                    .opacity(enabled ? 1 : 0.35)
            }
            .glow(Theme.Palette.accent, radius: 18, opacity: enabled ? 0.35 : 0)
        }
        .disabled(!enabled || isLoading)
        .buttonStyle(PressableStyle())
    }
}

struct SecondaryButton: View {
    let title: String
    var icon: String? = nil
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: 8) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 15, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(Theme.Palette.textPrimary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .glassEffect(.regular.interactive(),
                         in: .rect(cornerRadius: Theme.Radius.md, style: .continuous))
        }
        .buttonStyle(PressableStyle())
    }
}

/// Gives every button a subtle physical press response.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(Theme.Motion.snappy, value: configuration.isPressed)
    }
}

// MARK: - Chips

struct FilterChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(selected ? Theme.Palette.onAccent : Theme.Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(selected ? AnyShapeStyle(Theme.Grad.accent) : AnyShapeStyle(Theme.Palette.controlFill))
                }
                .overlay {
                    Capsule().strokeBorder(selected ? Color.clear : Theme.Palette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(PressableStyle())
    }
}

/// Small status/insight pill, e.g. "6-day streak".
struct BadgePill: View {
    let icon: String
    let text: String
    var tint: Color = Theme.Palette.burn

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(text).font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.3), lineWidth: 1))
    }
}

// MARK: - Empty state

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Theme.Palette.accent.opacity(0.12))
                    .frame(width: 78, height: 78)
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Theme.Palette.accent)
            }
            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                    .padding(.top, 2)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Loading / error inline states

struct InlineMessage: View {
    enum Kind { case info, error, success }
    let kind: Kind
    let text: String

    private var tint: Color {
        switch kind {
        case .info: Theme.Palette.accent
        case .error: Theme.Palette.alert
        case .success: Theme.Palette.accent
        }
    }
    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        case .success: "checkmark.circle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .glassCard(radius: Theme.Radius.md, padding: 14, tint: tint)
    }
}
