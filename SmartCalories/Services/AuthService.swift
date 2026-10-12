import Foundation
import AuthenticationServices
import Observation
import UIKit

/// Sign in with Apple, plus the session it earns.
///
/// Apple's identity token is deliberately short-lived (minutes), so it is not
/// a credential the app can keep presenting. The standard exchange is: prove
/// identity once with Apple's token, and have the backend — after verifying
/// that token against Apple's public keys — issue a long-lived session token
/// of its own. That session token lives in the Keychain, which survives app
/// deletion, so a reinstall silently restores the account and its data.
///
/// No SDK, no OAuth redirect, no developer-console setup: first-party
/// throughout, which is exactly why it replaced the Google flow.
@MainActor
@Observable
final class AuthService: NSObject {

    struct Account: Codable, Equatable {
        /// Apple's stable, app-scoped user identifier.
        let userID: String
        /// Apple reveals this only on the very first authorization, so it is
        /// remembered rather than re-requested; it may be a private relay.
        var email: String?

        var displayName: String { email ?? "Signed in" }
    }

    private(set) var account: Account?
    private(set) var isWorking = false
    private(set) var errorMessage: String?

    var isSignedIn: Bool { account != nil && Self.readSessionToken() != nil }

    private static let sessionKeychainAccount = "com.sankalpsingh.smartcalories.session"
    private static let accountDefaultsKey = "appleAccount"
    private static let endpoint = Secrets.backendBaseURL

    private var signInContinuation: CheckedContinuation<ASAuthorization, Error>?

    override init() {
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.accountDefaultsKey),
           let saved = try? JSONDecoder().decode(Account.self, from: data) {
            account = saved
        }
    }

    // MARK: - Session lifecycle

    /// Confirm at launch that Apple still considers this authorization valid.
    /// If the user revoked the app in Settings, this is where we notice.
    func restoreSession() async {
        guard let account, Self.readSessionToken() != nil else {
            self.account = nil
            return
        }
        let provider = ASAuthorizationAppleIDProvider()
        // A failure here usually means offline — that must not sign the user
        // out, so only an explicit revocation does.
        guard let state = try? await provider.credentialState(forUserID: account.userID) else {
            return
        }
        if state == .revoked || state == .notFound {
            signOut()
        }
    }

    func signIn() async {
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }

        do {
            let authorization = try await requestAppleAuthorization()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8)
            else {
                throw AuthError.message("Apple didn't return an identity token.")
            }

            let session = try await exchange(identityToken: identityToken)
            Self.writeSessionToken(session.token)

            // Email arrives only on first authorization; keep what we know.
            let resolved = Account(
                userID: credential.user,
                email: credential.email ?? session.email ?? account?.email
            )
            account = resolved
            if let data = try? JSONEncoder().encode(resolved) {
                UserDefaults.standard.set(data, forKey: Self.accountDefaultsKey)
            }
        } catch let error as AuthError {
            errorMessage = error.text
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() {
        Self.deleteSessionToken()
        UserDefaults.standard.removeObject(forKey: Self.accountDefaultsKey)
        account = nil
    }

    /// The bearer credential every backend call uses.
    func sessionToken() throws -> String {
        guard let token = Self.readSessionToken() else {
            throw AuthError.message("Signed out.")
        }
        return token
    }

    // MARK: - Backend exchange

    private struct SessionResponse {
        let token: String
        let email: String?
    }

    private func exchange(identityToken: String) async throws -> SessionResponse {
        var request = URLRequest(url: URL(string: "\(Self.endpoint)/auth/apple")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(DeviceIdentity.current, forHTTPHeaderField: "X-Device-Id")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["identityToken": identityToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["sessionToken"] as? String
        else {
            throw AuthError.message("The server rejected the sign-in. Try again.")
        }
        return SessionResponse(token: token, email: object["email"] as? String)
    }

    // MARK: - Apple authorization

    private func requestAppleAuthorization() async throws -> ASAuthorization {
        try await withCheckedThrowingContinuation { continuation in
            signInContinuation = continuation
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Keychain

    private static func readSessionToken() -> String? {
        var item: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: sessionKeychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ] as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeSessionToken(_ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: sessionKeychainAccount,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private static func deleteSessionToken() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: sessionKeychainAccount,
        ] as CFDictionary)
    }
}

enum AuthError: Error {
    case message(String)
    var text: String {
        switch self { case .message(let value): value }
    }
}

// MARK: - Delegates

extension AuthService: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            signInContinuation?.resume(returning: authorization)
            signInContinuation = nil
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            let message = (error as? ASAuthorizationError)?.code == .canceled
                ? "Sign-in cancelled."
                : error.localizedDescription
            signInContinuation?.resume(throwing: AuthError.message(message))
            signInContinuation = nil
        }
    }
}

extension AuthService: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(
        for controller: ASAuthorizationController
    ) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
                .first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}
