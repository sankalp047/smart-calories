import SwiftUI

/// Central design tokens. Everything visual in the app resolves through here so
/// the product reads as one system rather than a pile of screens.
///
/// Every palette entry is a *dynamic* color carrying both a light and a dark
/// variant — the whole app adapts to appearance changes through this one file,
/// and views never need to know which mode they're in.
enum Theme {

    // MARK: - Palette

    enum Palette {
        /// Screen ground. Dark: deep blue-black. Light: soft mint-tinged white.
        static let base = Color(light: 0xF3F6F4, dark: 0x0B0F14)
        static let elevated = Color(light: 0xFFFFFF, dark: 0x131A22)

        /// Primary brand accent — emerald. Deepened in light mode so it holds
        /// contrast against white instead of glowing out.
        static let accent = Color(light: 0x0E9F6E, dark: 0x34D399)
        static let accentDeep = Color(light: 0x047857, dark: 0x059669)

        /// Energy-out (burn) — warm amber.
        static let burn = Color(light: 0xD97706, dark: 0xFB923C)
        /// Over-budget / warning.
        static let alert = Color(light: 0xE11D48, dark: 0xF43F5E)

        // Macro identity colors, kept consistent everywhere macros appear.
        static let protein = Color(light: 0x2563EB, dark: 0x60A5FA)
        static let carbs = Color(light: 0xC27803, dark: 0xFBBF24)
        static let fat = Color(light: 0xDB2777, dark: 0xF472B6)

        static let textPrimary = Color(light: 0x101815, dark: 0xFFFFFF)
        static let textSecondary = Color.dynamic(
            light: .black.withAlphaComponent(0.55), dark: .white.withAlphaComponent(0.62))
        static let textTertiary = Color.dynamic(
            light: .black.withAlphaComponent(0.35), dark: .white.withAlphaComponent(0.38))

        static let hairline = Color.dynamic(
            light: .black.withAlphaComponent(0.08), dark: .white.withAlphaComponent(0.10))

        /// Ink used on accent-filled surfaces (buttons, hero cards). The
        /// accent is bright enough in both modes for dark ink to win.
        static let onAccent = Color(light: 0x06231A, dark: 0x06231A)

        /// Faint fill for inline controls (steppers, chips) — replaces the
        /// old hardcoded `Color.white.opacity(0.06)`.
        static let controlFill = Color.dynamic(
            light: .black.withAlphaComponent(0.05), dark: .white.withAlphaComponent(0.06))

        /// Card drop shadow — soft in light, deep in dark.
        static let shadow = Color.dynamic(
            light: .black.withAlphaComponent(0.10), dark: .black.withAlphaComponent(0.45))
    }

    // MARK: - Gradients

    enum Grad {
        static let accent = LinearGradient(
            colors: [Color(light: 0x34D399, dark: 0x34D399),
                     Color(light: 0x059669, dark: 0x059669)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let burn = LinearGradient(
            colors: [Color(hex: 0xFDBA74), Palette.burn],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        static let alert = LinearGradient(
            colors: [Color(hex: 0xFB7185), Palette.alert],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )

        /// App background: the ground layer glass floats above. A soft accent
        /// bloom up top in both modes.
        static let screen = LinearGradient(
            stops: [
                .init(color: Color(light: 0xDDEFE6, dark: 0x11201C), location: 0.0),
                .init(color: Palette.base, location: 0.42),
                .init(color: Palette.base, location: 1.0)
            ],
            startPoint: .top, endPoint: .bottom
        )

        /// Subtle top-lit sheen for non-glass fills that want depth.
        static let cardSheen = LinearGradient(
            colors: [Color.white.opacity(0.10), Color.white.opacity(0.02)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
    }

    // MARK: - Metrics

    enum Radius {
        static let sm: CGFloat = 12
        static let md: CGFloat = 18
        static let lg: CGFloat = 26
        static let pill: CGFloat = 999
    }

    enum Space {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 10
        static let md: CGFloat = 16
        static let lg: CGFloat = 22
        static let xl: CGFloat = 32
    }

    // MARK: - Motion

    enum Motion {
        /// Default springy transition — used for value changes and reveals.
        static let spring = Animation.spring(response: 0.45, dampingFraction: 0.82)
        static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.85)
    }
}

// MARK: - Appearance

/// The user's appearance choice, persisted in AppSettings.
enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max.fill"
        case .dark: "moon.fill"
        }
    }
    /// nil = follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

// MARK: - Typography

extension Font {
    /// Big expressive numerals (calorie counts, live weight).
    static func numeric(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    /// Small all-caps section/eyebrow label.
    static let eyebrow = Font.system(size: 11, weight: .semibold, design: .rounded)
    static let cardTitle = Font.system(size: 16, weight: .semibold, design: .rounded)
    static let rowTitle = Font.system(size: 15, weight: .medium)
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }

    /// Dynamic color from two hex values, resolved per appearance.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(Color(hex: dark))
                : UIColor(Color(hex: light))
        })
    }

    /// Dynamic color from two UIColors — for alpha-carrying tokens.
    static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }
}

extension View {
    /// Standard app background — the content layer Liquid Glass samples from.
    func screenBackground() -> some View {
        background(Theme.Grad.screen.ignoresSafeArea())
    }

    /// The app's card surface: real Liquid Glass. The material refracts the
    /// screen gradient behind it, which is what keeps cards feeling lit by
    /// the app's own accent in both modes.
    ///
    /// A `tint` washes the glass itself (use sparingly — hero cards only).
    func glassCard(
        radius: CGFloat = Theme.Radius.lg,
        padding: CGFloat = Theme.Space.md,
        tint: Color? = nil
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(
                tint.map { Glass.regular.tint($0.opacity(0.24)) } ?? .regular,
                in: .rect(cornerRadius: radius, style: .continuous)
            )
            .shadow(color: Theme.Palette.shadow, radius: 14, y: 8)
    }

    /// Applies a soft colored glow — used sparingly on hero elements.
    func glow(_ color: Color, radius: CGFloat = 24, opacity: Double = 0.5) -> some View {
        shadow(color: color.opacity(opacity), radius: radius)
    }
}

/// Light haptic helper so interactions feel physical.
enum Haptics {
    static func tap() {
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }
    static func success() {
        #if canImport(UIKit)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }
}
