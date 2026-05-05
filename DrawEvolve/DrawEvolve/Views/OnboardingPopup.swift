//
//  OnboardingPopup.swift
//  DrawEvolve
//
//  First-time user onboarding explanation.
//

import SwiftUI

struct OnboardingPopup: View {
    @Binding var isPresented: Bool

    var body: some View {
        if DeviceIdiom.isPhone {
            phoneBody
        } else {
            padBody
        }
    }

    /// iPhone layout — edge-to-edge, no dim BG, no maxWidth/maxHeight cap.
    /// Presented as a `.fullScreenCover` from `ContentView`, so the cover
    /// itself absorbs all touches and the existing iPad-only
    /// `.onTapGesture { }` dim-BG hack isn't needed here.
    private var phoneBody: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Image("DrawEvolveLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 120)

                    Text("Your personalized drawing coach")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 20) {
                    Text("How it works:")
                        .font(.headline)

                    OnboardingStep(
                        icon: "doc.text.fill",
                        title: "Tell us about your drawing",
                        description: "Share what you're creating and what feedback you need"
                    )

                    OnboardingStep(
                        icon: "paintbrush.pointed.fill",
                        title: "Create your artwork",
                        description: "Use our canvas and Apple Pencil to bring your vision to life"
                    )

                    OnboardingStep(
                        icon: "sparkles",
                        title: "Get personalized feedback",
                        description: "Receive encouraging, tailored guidance to improve your skills"
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isPresented = false
            } label: {
                Text("Let's Get Started")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
        .background(Color(uiColor: .systemBackground))
    }

    /// iPad layout — original implementation, byte-for-byte unchanged.
    /// Renamed from `body` so the iPad rendering passes through the new
    /// `body`'s idiom branch. This rename is the ONLY edit to the iPad
    /// code path; the inner ZStack/dim-BG/centered-card structure below
    /// is identical to pre-iPhone-strategy main.
    private var padBody: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    // Prevent dismissal by tapping outside
                }

            // Popup card
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 12) {
                    Image("DrawEvolveLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 120)

                    Text("Your personalized drawing coach")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }

                Divider()

                // How it works
                VStack(alignment: .leading, spacing: 20) {
                    Text("How it works:")
                        .font(.headline)

                    OnboardingStep(
                        icon: "doc.text.fill",
                        title: "Tell us about your drawing",
                        description: "Share what you're creating and what feedback you need"
                    )

                    OnboardingStep(
                        icon: "paintbrush.pointed.fill",
                        title: "Create your artwork",
                        description: "Use our canvas and Apple Pencil to bring your vision to life"
                    )

                    OnboardingStep(
                        icon: "sparkles",
                        title: "Get personalized feedback",
                        description: "Receive encouraging, tailored guidance to improve your skills"
                    )
                }
                .padding(.horizontal)

                // Continue button
                Button(action: {
                    isPresented = false
                }) {
                    Text("Let's Get Started")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 32)
            .padding(.top, 16)
            .frame(maxWidth: 600, maxHeight: 700)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(radius: 20)
            )
            .padding(40)
        }
    }
}

struct OnboardingStep: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(description)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
        }
    }
}

#Preview {
    OnboardingPopup(isPresented: .constant(true))
}
