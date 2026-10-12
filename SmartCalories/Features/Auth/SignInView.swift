import SwiftUI
import AuthenticationServices

/// The gate. Signing in is what makes your data survive a reinstall, so the
/// screen says that plainly rather than treating the account as a formality.
struct SignInView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 18) {
                Image(systemName: "flame.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.Grad.accent)
                    .glow(Theme.Palette.accent, radius: 28, opacity: 0.35)

                VStack(spacing: 8) {
                    Text("Smart Calories")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text("Sign in so your food log, weight history and training survive a reinstall or a new phone.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
            }

            Spacer()

            VStack(spacing: 14) {
                if let error = env.auth.errorMessage {
                    InlineMessage(kind: .error, text: error)
                }

                // Apple's own button: required styling, and it already
                // adapts to light/dark, so it just follows the app theme.
                SignInWithAppleButton(.signIn) { _ in
                    // The request is configured inside AuthService, which owns
                    // the whole flow; this closure only starts it.
                } onCompletion: { _ in }
                    .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                    .frame(height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                    .allowsHitTesting(false)
                    .overlay {
                        Button { Task { await env.signIn() } } label: {
                            Color.clear.contentShape(Rectangle())
                        }
                        .disabled(env.auth.isWorking)
                    }
                    .opacity(env.auth.isWorking ? 0.5 : 1)

                if env.auth.isWorking {
                    HStack(spacing: 8) {
                        ProgressView().tint(Theme.Palette.accent)
                        Text("Signing in…")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }

                Text("Your health data is stored against your Apple ID and never shared.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}

/// Shown while a fresh install pulls the account's data back down.
struct RestoringView: View {
    let restoredCount: Int

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Palette.accent)
            Text(restoredCount > 0 ? "Restoring your data…" : "Checking your account…")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
    }
}
