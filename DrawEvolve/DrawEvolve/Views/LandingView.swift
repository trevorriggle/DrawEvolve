//
//  LandingView.swift
//  DrawEvolve
//
//  Landing page with authentication options.
//

import SwiftUI

struct LandingView: View {
    @Binding var isAuthenticated: Bool

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
                VStack(spacing: 16) {
                    // Placeholder for logo image
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

                    Text("Your AI Drawing Coach")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Auth buttons
                VStack(spacing: 16) {
                    // Login button
                    Button(action: {
                        // TODO: Implement login
                        isAuthenticated = true
                    }) {
                        Text("Log In")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }

                    // Google sign in
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

                    // Create account
                    Button(action: {
                        // TODO: Implement account creation
                        isAuthenticated = true
                    }) {
                        Text("Create Account")
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

                    // Guest mode
                    Button(action: {
                        isAuthenticated = true
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
    }
}

#Preview {
    LandingView(isAuthenticated: .constant(false))
}
