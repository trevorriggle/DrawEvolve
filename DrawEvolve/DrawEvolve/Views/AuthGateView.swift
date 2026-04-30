//
//  AuthGateView.swift
//  DrawEvolve
//
//  Sign-in screen shown before the existing onboarding/canvas flow.
//  Two paths: Sign in with Apple (system sheet), or email magic link.
//
//  Visual reskin only — auth logic, AuthManager interactions, method
//  signatures untouched.
//

import AuthenticationServices
import SwiftUI

struct AuthGateView: View {
    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.colorScheme) private var colorScheme

    @State private var emailInput: String = ""
    @State private var emailState: EmailState = .input
    @State private var isSendingMagicLink = false
    @FocusState private var emailFieldFocused: Bool

    private enum EmailState {
        case input
        case sent
    }

    // Layout constants — one place to tune visual rhythm.
    private let contentMaxWidth: CGFloat = 440
    private let horizontalPadding: CGFloat = 24
    private let controlHeight: CGFloat = 50
    private let cornerRadius: CGFloat = 12
    private let logoMaxWidth: CGFloat = 240

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 32)

                brandHeader
                    .padding(.horizontal, horizontalPadding)

                Spacer(minLength: 36)
                    .frame(maxHeight: 64)

                authControls
                    .padding(.horizontal, horizontalPadding)
                    .frame(maxWidth: contentMaxWidth)

                statusArea
                    .padding(.horizontal, horizontalPadding)
                    .frame(maxWidth: contentMaxWidth)

                Spacer(minLength: 24)

                #if DEBUG
                debugSkipButton
                    .padding(.bottom, 16)
                #endif

                footer
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }

    // MARK: - Brand

    private var brandHeader: some View {
        VStack(spacing: 16) {
            logoImage
                .frame(maxWidth: logoMaxWidth)
                .frame(height: 90)

            Text("Honest, specific feedback on your drawings.")
                .font(.system(.callout, design: .default))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var logoImage: some View {
        let base = Image("DrawEvolveLogo")
            .resizable()
            .aspectRatio(contentMode: .fit)

        if colorScheme == .dark {
            // Logo PNG is solid black on transparent — invert to white in dark mode
            // so it stays visible. Replace this with a proper dark-variant asset
            // when one ships.
            base.colorInvert().accessibilityLabel("DrawEvolve")
        } else {
            base.accessibilityLabel("DrawEvolve")
        }
    }

    // MARK: - Auth controls

    private var authControls: some View {
        VStack(spacing: 16) {
            signInWithAppleButton
            signInWithGoogleButton

            if emailState == .input {
                dividerOr
                emailInputArea
            } else {
                inboxNotice
            }
        }
        .animation(.easeInOut(duration: 0.22), value: emailState)
    }

    private var signInWithAppleButton: some View {
        SignInWithAppleButton(.signIn) { request in
            authManager.prepareAppleSignInRequest(request)
        } onCompletion: { result in
            Task { await authManager.completeAppleSignIn(result) }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(maxWidth: .infinity)
        .frame(height: controlHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
    }

    private var signInWithGoogleButton: some View {
        Button {
            Task { await authManager.signInWithGoogle() }
        } label: {
            HStack(spacing: 12) {
                Text("G")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color(red: 66/255, green: 133/255, blue: 244/255))
                Text("Sign in with Google")
                    .font(.system(.body, design: .default).weight(.semibold))
                    .foregroundStyle(Color.primary)
            }
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color(.separator).opacity(0.5), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.04), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private var dividerOr: some View {
        HStack(spacing: 12) {
            line
            Text("or")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.tertiary)
            line
        }
        .padding(.vertical, 4)
    }

    private var line: some View {
        Rectangle()
            .fill(Color(.separator).opacity(0.6))
            .frame(height: 1)
    }

    private var emailInputArea: some View {
        VStack(spacing: 12) {
            TextField("you@example.com", text: $emailInput)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .focused($emailFieldFocused)
                .padding(.horizontal, 16)
                .frame(height: controlHeight)
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(
                            emailFieldFocused ? Color.accentColor.opacity(0.8) : Color(.separator),
                            lineWidth: emailFieldFocused ? 1.5 : 1
                        )
                )
                .submitLabel(.send)
                .onSubmit { sendMagicLink() }

            magicLinkWarning

            magicLinkButton
        }
    }

    private var magicLinkWarning: some View {
        Text("Open the magic link only on this device. Opening it elsewhere won't sign you in here.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var magicLinkButton: some View {
        Button(action: sendMagicLink) {
            ZStack {
                if isSendingMagicLink {
                    ProgressView().tint(.white)
                } else {
                    Text("Send Magic Link")
                        .font(.system(.body, design: .default).weight(.semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: controlHeight)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(canSubmitEmail ? Color.accentColor : Color.accentColor.opacity(0.35))
            )
            .foregroundStyle(.white)
            .shadow(
                color: canSubmitEmail ? Color.accentColor.opacity(0.25) : .clear,
                radius: 8, y: 3
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSubmitEmail || isSendingMagicLink)
    }

    private var inboxNotice: some View {
        VStack(spacing: 14) {
            Image(systemName: "envelope.badge")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Color.accentColor)
                .padding(.top, 4)

            Text("Check your inbox")
                .font(.system(.title3).weight(.semibold))

            Text("We sent a sign-in link to \(authManager.pendingMagicLinkEmail ?? emailInput). Tap it from this device to finish signing in.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            Button("Use a different email") {
                withAnimation(.easeInOut(duration: 0.22)) {
                    emailState = .input
                    authManager.pendingMagicLinkEmail = nil
                    emailFieldFocused = true
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(.secondarySystemBackground).opacity(0.6))
        )
    }

    // MARK: - Status (reserves space so layout doesn't jump)

    private var statusArea: some View {
        Group {
            if let error = authManager.lastError, !error.isEmpty {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Color.red.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Color.clear
            }
        }
        .frame(minHeight: 44)
        .padding(.top, 12)
        .animation(.easeInOut(duration: 0.2), value: authManager.lastError)
    }

    // MARK: - Debug bypass (compiled out of Release builds)

    #if DEBUG
    private var debugSkipButton: some View {
        Button {
            authManager.enableDebugBypass()
        } label: {
            Text("DEBUG - SKIP AUTH")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Color.orange)
                .padding(.vertical, 10)
                .padding(.horizontal, 18)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            Color.orange.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Debug only — skip authentication and enter the app")
    }
    #endif

    // MARK: - Footer

    private var footer: some View {
        Text("By continuing, you agree to our Terms and acknowledge our Privacy Policy.")
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Helpers

    private var canSubmitEmail: Bool {
        let trimmed = emailInput.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") && trimmed.contains(".") && trimmed.count >= 5
    }

    private func sendMagicLink() {
        guard canSubmitEmail else { return }
        isSendingMagicLink = true
        Task {
            await authManager.sendMagicLink(email: emailInput)
            isSendingMagicLink = false
            if authManager.pendingMagicLinkEmail != nil {
                withAnimation(.easeInOut(duration: 0.25)) {
                    emailState = .sent
                }
                emailFieldFocused = false
            }
        }
    }
}

#Preview("Light") {
    AuthGateView()
        .environmentObject(AuthManager.shared)
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    AuthGateView()
        .environmentObject(AuthManager.shared)
        .preferredColorScheme(.dark)
}
