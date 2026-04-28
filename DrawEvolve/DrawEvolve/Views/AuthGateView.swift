//
//  AuthGateView.swift
//  DrawEvolve
//
//  Sign-in screen shown before the existing onboarding/canvas flow.
//  Two paths: Sign in with Apple (system sheet), or email magic link.
//

import AuthenticationServices
import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject private var authManager: AuthManager
    @State private var emailMode: EmailMode = .hidden
    @State private var emailInput: String = ""
    @State private var isSendingMagicLink = false
    @FocusState private var emailFieldFocused: Bool

    private enum EmailMode {
        case hidden
        case entering
        case sent
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 12) {
                Text("DrawEvolve")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Honest, specific feedback on your drawings.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 16) {
                signInWithAppleButton

                switch emailMode {
                case .hidden:
                    Button(action: { withAnimation { emailMode = .entering; emailFieldFocused = true } }) {
                        Text("Continue with Email")
                            .font(.body.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .background(Color(.secondarySystemBackground))
                            .foregroundStyle(.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                case .entering:
                    emailEntry
                case .sent:
                    inboxNotice
                }

                if let error = authManager.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            Text("By continuing, you agree to our Terms and acknowledge our Privacy Policy.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }

    private var signInWithAppleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            authManager.prepareAppleSignInRequest(request)
        } onCompletion: { result in
            Task { await authManager.completeAppleSignIn(result) }
        }
        .signInWithAppleButtonStyle(.black)
        .frame(maxWidth: .infinity, minHeight: 50)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var emailEntry: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $emailInput)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($emailFieldFocused)

            Button(action: sendMagicLink) {
                Group {
                    if isSendingMagicLink {
                        ProgressView().tint(.white)
                    } else {
                        Text("Send Magic Link")
                            .font(.body.weight(.medium))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(canSubmitEmail ? Color.accentColor : Color.gray.opacity(0.4))
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(!canSubmitEmail || isSendingMagicLink)

            Button("Cancel") {
                withAnimation {
                    emailMode = .hidden
                    emailInput = ""
                    emailFieldFocused = false
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var inboxNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Check your inbox")
                .font(.headline)
            Text("We sent a sign-in link to \(authManager.pendingMagicLinkEmail ?? emailInput). Tap it from this device to finish signing in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Use a different email") {
                withAnimation {
                    emailMode = .entering
                    authManager.pendingMagicLinkEmail = nil
                }
            }
            .font(.footnote)
        }
        .padding(.vertical, 8)
    }

    private var canSubmitEmail: Bool {
        let trimmed = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".")
    }

    private func sendMagicLink() {
        guard canSubmitEmail else { return }
        isSendingMagicLink = true
        Task {
            await authManager.sendMagicLink(email: emailInput)
            isSendingMagicLink = false
            if authManager.pendingMagicLinkEmail != nil {
                withAnimation { emailMode = .sent }
                emailFieldFocused = false
            }
        }
    }
}

#Preview {
    AuthGateView()
        .environmentObject(AuthManager.shared)
}
