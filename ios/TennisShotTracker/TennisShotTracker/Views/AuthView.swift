import SwiftUI
import TennisCore

/// Login / sign-up screen. All auth calls are delegated to SessionStore
/// (which delegates further to APIClient) — no networking, token, Keychain,
/// or model-decoding logic lives here (AC22).
struct AuthView: View {
    let sessionStore: SessionStore

    @State private var isLoginMode = true
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    // Instant client-side feedback via TennisCore PasswordValidator (OQ-2).
    private var passwordValidation: PasswordValidation {
        PasswordValidator.validate(password)
    }

    private var passwordHint: String? {
        switch passwordValidation {
        case .tooShort: return "Password must be at least 8 characters."
        case .tooLong:  return "Password must be 72 bytes or fewer."
        case .valid:    return nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Password", text: $password)
                }

                if let hint = passwordHint {
                    Section {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let message = errorMessage {
                    Section {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button(isLoginMode ? "Log In" : "Sign Up") {
                        submit()
                    }
                    .disabled(isSubmitting || username.isEmpty || password.isEmpty)
                }

                Section {
                    Button(isLoginMode ? "Need an account? Sign Up" : "Have an account? Log In") {
                        isLoginMode.toggle()
                        errorMessage = nil
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(isLoginMode ? "Log In" : "Sign Up")
        }
    }

    private func submit() {
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                if isLoginMode {
                    try await sessionStore.login(username: username, password: password)
                } else {
                    try await sessionStore.signup(username: username, password: password)
                }
            } catch {
                // Surface the backend message when available; fall back to a
                // generic string for transport / offline errors (backendMessage is nil there).
                errorMessage = (error as? APIError)?.backendMessage ?? "Something went wrong. Please try again."
            }
        }
    }
}
