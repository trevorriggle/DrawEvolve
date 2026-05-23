//
//  LaunchHomeView.swift
//  DrawEvolve
//
//  First screen after sign-in. Two choices: start a new canvas, or
//  open the gallery. Routes upstream of the canvas's first-launch
//  prompt-input modal so a user who taps "Go to gallery" can browse
//  their work without filling out the prompt for a new drawing first.
//

import SwiftUI

struct LaunchHomeView: View {
    let onNewCanvas: () -> Void
    let onOpenGallery: () -> Void
    let onOpenConversations: () -> Void

    @EnvironmentObject private var authManager: AuthManager
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            DrawEvolveBackground()
                .ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                Image("DrawEvolveLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 280, height: 280)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.12),
                            radius: 18, x: 0, y: 6)

                VStack(spacing: 6) {
                    Text("Welcome to DrawEvolve")
                        .font(.system(size: 34, weight: .bold, design: .serif))
                        .foregroundStyle(.primary)
                    Text("Draw. Get a critique. Evolve.")
                        .font(.system(.subheadline, design: .serif))
                        .italic()
                        .tracking(0.3)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 14) {
                    choiceCard(
                        title: "Set up a new canvas",
                        subtitle: "Start fresh with your next drawing",
                        systemImage: "square.and.pencil",
                        isPrimary: true,
                        action: onNewCanvas
                    )

                    choiceCard(
                        title: "Go to gallery",
                        subtitle: "Revisit your work and critiques",
                        systemImage: "photo.on.rectangle.angled",
                        isPrimary: false,
                        action: onOpenGallery
                    )

                    choiceCard(
                        title: "Conversations with Eve",
                        subtitle: "Revisit past sessions with your AI mentor",
                        systemImage: "bubble.left.and.bubble.right",
                        isPrimary: false,
                        action: onOpenConversations
                    )
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: 520)

                Spacer()

                signedInFooter
                    .padding(.bottom, 24)
            }
        }
    }

    private func choiceCard(
        title: String,
        subtitle: String,
        systemImage: String,
        isPrimary: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(isPrimary ? Color.accentColor : Color.accentColor.opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(isPrimary ? Color.white : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.35 : 0.06),
                    radius: 12, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// Small "Signed in as <email>" line at the bottom of the launch
    /// screen. Reads from AuthManager (injected via ContentView's
    /// .environmentObject). Falls back to "—" if email isn't available
    /// (e.g., debug-bypass user has no Supabase session).
    private var signedInFooter: some View {
        HStack(spacing: 4) {
            Text("Signed in as")
                .foregroundStyle(.secondary)
            Text(authManager.currentUser?.email ?? "—")
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
        .font(.footnote)
    }
}

#Preview {
    LaunchHomeView(onNewCanvas: {}, onOpenGallery: {}, onOpenConversations: {})
        .environmentObject(AuthManager.shared)
}
