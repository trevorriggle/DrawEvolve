//
//  LandingView.swift
//  DrawEvolve
//
//  Landing page with authentication options.
//

import SwiftUI

struct LandingView: View {
    @Binding var isAuthenticated: Bool
    @StateObject private var authManager = AuthManager.shared

    @State private var showSignIn = false
    @State private var showSignUp = false

    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [Color.accentColor.opacity(0.3), Color.accentColor.opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                // Logo and branding
                VStack(spacing: 20) {
                    Image(systemName: "paintbrush.pointed.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.accentColor, .accentColor.opacity(0.7)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("DrawEvolve")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)

                    Text("Welcome to DrawEvolve.\nLet's get you logged in to save your artwork.")
                        .font(.title3)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                Spacer()

                // Auth buttons
                VStack(spacing: 16) {
                    // Create account (primary CTA)
                    Button(action: {
                        showSignUp = true
                    }) {
                        Text("Create Account")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    // Login button
                    Button(action: {
                        showSignIn = true
                    }) {
                        Text("Log In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color(uiColor: .systemBackground))
                            .foregroundColor(.accentColor)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.accentColor, lineWidth: 2)
                        )
                        .cornerRadius(12)
                    }

                    // Google sign in (future implementation)
                    Button(action: {
                        // TODO: Implement Google sign in
                        isAuthenticated = true
                    }) {
                        HStack {
                            Image(systemName: "g.circle.fill")
                                .font(.title2)
                            Text("Continue with Google")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color(uiColor: .systemBackground))
                        .foregroundColor(.primary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(uiColor: .separator), lineWidth: 1)
                        )
                        .cornerRadius(12)
                    }

                    // Guest mode
                    Button(action: {
                        authManager.continueAsGuest()
                    }) {
                        Text("Continue as Guest")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 8)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .sheet(isPresented: $showSignIn) {
            SignInView()
        }
        .sheet(isPresented: $showSignUp) {
            SignUpView()
        }
        .onChange(of: authManager.isAuthenticated) { newValue in
            isAuthenticated = newValue
        }
    }
}

#Preview {
    LandingView(isAuthenticated: .constant(false))
}
