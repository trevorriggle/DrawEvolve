//
//  SignInView.swift
//  DrawEvolve
//
//  Sign in screen with email/password authentication.
//

import SwiftUI

struct SignInView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var authManager = AuthManager.shared

    @State private var email = ""
    @State private var password = ""
    @State private var showError = false

    var body: some View {
        NavigationView {
            ZStack {
                // Background gradient
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.2), Color.accentColor.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                VStack(spacing: 24) {
                    // Logo
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 40)

                    Text("Welcome Back")
                        .font(.system(size: 32, weight: .bold, design: .rounded))

                    Spacer()

                    // Form
                    VStack(spacing: 16) {
                        // Email field
                        TextField("Email", text: $email)
                            .textContentType(.emailAddress)
                            .autocapitalization(.none)
                            .keyboardType(.emailAddress)
                            .padding()
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)

                        // Password field
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .padding()
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)

                        // Sign in button
                        Button(action: {
                            Task {
                                await handleSignIn()
                            }
                        }) {
                            if authManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            } else {
                                Text("Sign In")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                        }
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .disabled(authManager.isLoading || email.isEmpty || password.isEmpty)

                        // Error message
                        if let error = authManager.errorMessage {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(.horizontal, 32)

                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func handleSignIn() async {
        do {
            try await authManager.signIn(email: email, password: password)
            dismiss()
        } catch {
            showError = true
        }
    }
}

#Preview {
    SignInView()
}
