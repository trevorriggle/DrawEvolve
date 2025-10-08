//
//  SignUpView.swift
//  DrawEvolve
//
//  Sign up screen for new user registration.
//

import SwiftUI

struct SignUpView: View {
    @Environment(\.dismiss) var dismiss
    @StateObject private var authManager = AuthManager.shared

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showError = false
    @State private var errorText = ""

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

                    Text("Create Account")
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
                            .textContentType(.newPassword)
                            .padding()
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)

                        // Confirm password field
                        SecureField("Confirm Password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .padding()
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)

                        // Password requirements
                        Text("Password must be at least 6 characters")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // Sign up button
                        Button(action: {
                            Task {
                                await handleSignUp()
                            }
                        }) {
                            if authManager.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            } else {
                                Text("Create Account")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                            }
                        }
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                        .disabled(authManager.isLoading || !isFormValid)

                        // Error message
                        if showError {
                            Text(errorText)
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

    private var isFormValid: Bool {
        !email.isEmpty &&
        password.count >= 6 &&
        password == confirmPassword
    }

    private func handleSignUp() async {
        guard password == confirmPassword else {
            errorText = "Passwords do not match"
            showError = true
            return
        }

        guard password.count >= 6 else {
            errorText = "Password must be at least 6 characters"
            showError = true
            return
        }

        do {
            try await authManager.signUp(email: email, password: password)
            dismiss()
        } catch {
            errorText = authManager.errorMessage ?? "Sign up failed"
            showError = true
        }
    }
}

#Preview {
    SignUpView()
}
