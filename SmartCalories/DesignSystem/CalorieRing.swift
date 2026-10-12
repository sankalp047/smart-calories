import SwiftUI

/// The hero energy ring: calories remaining, with eaten/burned context.
/// Animates smoothly whenever the underlying numbers change.
struct CalorieRing: View {
    let eaten: Double
    let goal: Double
    let burned: Double

    @State private var animatedProgress: Double = 0

    private var progress: Double {
        guard goal > 0 else { return 0 }
        return min(eaten / goal, 1.0)
    }
    private var remaining: Double { goal - eaten }
    private var isOver: Bool { eaten > goal }

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: isOver
                ? [Theme.Palette.alert, Color(hex: 0xFB7185), Theme.Palette.alert]
                : [Theme.Palette.accentDeep, Theme.Palette.accent, Color(hex: 0x7DD3FC), Theme.Palette.accent],
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                // Track
                Circle()
                    .stroke(Theme.Palette.controlFill, lineWidth: 18)

                // Progress
                Circle()
                    .trim(from: 0, to: animatedProgress)
                    .stroke(ringGradient, style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .glow(isOver ? Theme.Palette.alert : Theme.Palette.accent, radius: 20, opacity: 0.55)

                // Center readout
                VStack(spacing: 2) {
                    Text(abs(remaining), format: .number.precision(.fractionLength(0)))
                        .font(.numeric(46, .heavy))
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .contentTransition(.numericText())
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(isOver ? "kcal over" : "kcal left")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(isOver ? Theme.Palette.alert : Theme.Palette.textSecondary)
                }
            }
            .frame(width: 190, height: 190)
            .padding(.top, 4)

            // Eaten / Goal / Burned trio
            HStack(spacing: 0) {
                metric("Eaten", eaten, Theme.Palette.accent, "fork.knife")
                divider
                metric("Goal", goal, Theme.Palette.textSecondary, "target")
                divider
                metric("Burned", burned, Theme.Palette.burn, "flame.fill")
            }
        }
        .glassCard(radius: Theme.Radius.lg, padding: 20)
        .onAppear {
            withAnimation(.easeOut(duration: 0.9)) { animatedProgress = progress }
        }
        .onChange(of: progress) { _, new in
            withAnimation(Theme.Motion.spring) { animatedProgress = new }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.Palette.hairline)
            .frame(width: 1, height: 30)
    }

    private func metric(_ label: String, _ value: Double, _ tint: Color, _ icon: String) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .bold))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(tint)

            Text(value, format: .number.precision(.fractionLength(0)))
                .font(.numeric(19))
                .foregroundStyle(Theme.Palette.textPrimary)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Compact linear progress used in lists and detail headers.
struct ProgressCapsule: View {
    let value: Double
    let total: Double
    var tint: Color = Theme.Palette.accent
    var height: CGFloat = 8

    private var progress: Double {
        guard total > 0 else { return 0 }
        return min(value / total, 1)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.controlFill)
                Capsule()
                    .fill(value > total ? AnyShapeStyle(Theme.Grad.alert) : AnyShapeStyle(Theme.Grad.accent))
                    .frame(width: max(height, geo.size.width * progress))
                    .animation(Theme.Motion.spring, value: progress)
            }
        }
        .frame(height: height)
    }
}
