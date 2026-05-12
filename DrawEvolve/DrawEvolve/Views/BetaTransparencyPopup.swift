//
//  BetaTransparencyPopup.swift
//  DrawEvolve
//
//  Beta transparency notice explaining current state and future features.
//

import SwiftUI

struct BetaTransparencyPopup: View {
    @Binding var isPresented: Bool

    var body: some View {
        if DeviceIdiom.isPhone {
            phoneBody
        } else {
            padBody
        }
    }

    /// iPhone layout — edge-to-edge, no dim BG, no maxWidth/maxHeight cap.
    /// Maps the iPad's "fixed header / scrollable middle / fixed footer"
    /// internal structure onto a ScrollView + safeAreaInset(edge: .bottom).
    /// Header sits at the top of the ScrollView's content (not pinned),
    /// matching how the iPad version renders the header inside the same
    /// card as the scrollable content.
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(spacing: 12) {
                    Image("DrawEvolveLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 100)

                    Text("DrawEvolve - Beta Transparency")
                        .font(.title2)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text("We're being completely honest with you")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text("Heads up — this is a BETA")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BetaWarningItem(text: "Expect bugs and rough edges. Please report what breaks.")
                        BetaWarningItem(text: "Pose detection (hand / body) needs a real device — the iOS Simulator can't load Apple's Vision models.")
                        BetaWarningItem(text: "iPhone support is newer than iPad — some flows are more polished on iPad.")
                        BetaWarningItem(text: "DrawEvolve is free during the beta. Some features may move behind a paid tier when we ship.")
                        BetaWarningItem(text: "Drawings and critiques sync to Supabase. If a crash takes the app down, your work survives the relaunch.")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("What's working now")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BetaFeatureItem(
                            icon: "paintbrush.pointed.fill",
                            text: "6 calibrated brushes — pencil, brush, ink pen, marker, airbrush, charcoal — each with its own shape and feel."
                        )
                        BetaFeatureItem(
                            icon: "drop.fill",
                            text: "Eraser, blur brush, blur adjustment, smudge, paint bucket, eyedropper."
                        )
                        BetaFeatureItem(
                            icon: "square.on.circle",
                            text: "Shapes (line, rectangle, circle), text, and type-on-path along a curve or a circle."
                        )
                        BetaFeatureItem(
                            icon: "lasso",
                            text: "Rectangle marquee + lasso selection, free transform (scale, rotate, move)."
                        )
                        BetaFeatureItem(
                            icon: "square.stack.3d.up.fill",
                            text: "Multi-layer drawing, undo / redo, symmetry mirror modes."
                        )
                        BetaFeatureItem(
                            icon: "figure.stand",
                            text: "Hand and body pose reference overlays — trace from a photo, then draw over them."
                        )
                        BetaFeatureItem(
                            icon: "sparkles",
                            text: "GPT-5.1 AI critique with iterative coaching — your coach remembers prior sessions on the same drawing."
                        )
                        BetaFeatureItem(
                            icon: "person.crop.circle.badge.questionmark",
                            text: "Four voice presets (Studio Mentor, The Crit, Fundamentals Coach, Renaissance Master) plus a freeform custom voice."
                        )
                        BetaFeatureItem(
                            icon: "slider.horizontal.3",
                            text: "Custom prompts — tune focus, tone, depth, and technique emphasis. Save and reuse."
                        )
                        BetaFeatureItem(
                            icon: "chart.line.uptrend.xyaxis",
                            text: "My Evolution — skill radar + critique wall tracking your growth across drawings."
                        )
                        BetaFeatureItem(
                            icon: "ipad.and.iphone",
                            text: "Universal app — iPad and iPhone with cloud sync of drawings + critique history."
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .foregroundColor(.blue)
                        Text("On the horizon")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ComingSoonItem(text: "Smarter brush sets — oil paint and watercolor with real texture.")
                        ComingSoonItem(text: "Per-drawing pinned prompts that override the global voice when active.")
                        ComingSoonItem(text: "More export formats — Procreate-compatible files and stroke-by-stroke timelapses.")
                        ComingSoonItem(text: "Sharable evolution profiles — show your growth publicly when you want to.")
                        ComingSoonItem(text: "A Pro tier with higher critique limits when paid plans land. Beta users keep the free tier as long as we can swing it.")
                    }

                    Text("Your journey matters. We're building this WITH you, not just FOR you.")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .italic()
                        .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                isPresented = false
            } label: {
                Text("I Understand - Let's Create!")
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
    private var padBody: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    // Prevent dismissal by tapping outside
                }

            // Popup card
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Image("DrawEvolveLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 100)

                    Text("DrawEvolve - Beta Transparency")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("We're being completely honest with you")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 16)

                Divider()

                // Scrollable content
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Reality Check Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("Heads up — this is a BETA")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaWarningItem(text: "Expect bugs and rough edges. Please report what breaks.")
                                BetaWarningItem(text: "Pose detection (hand / body) needs a real device — the iOS Simulator can't load Apple's Vision models.")
                                BetaWarningItem(text: "iPhone support is newer than iPad — some flows are more polished on iPad.")
                                BetaWarningItem(text: "DrawEvolve is free during the beta. Some features may move behind a paid tier when we ship.")
                                BetaWarningItem(text: "Drawings and critiques sync to Supabase. If a crash takes the app down, your work survives the relaunch.")
                            }
                        }

                        Divider()

                        // What We Have Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("What's working now")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaFeatureItem(
                                    icon: "paintbrush.pointed.fill",
                                    text: "6 calibrated brushes — pencil, brush, ink pen, marker, airbrush, charcoal — each with its own shape and feel."
                                )
                                BetaFeatureItem(
                                    icon: "drop.fill",
                                    text: "Eraser, blur brush, blur adjustment, smudge, paint bucket, eyedropper."
                                )
                                BetaFeatureItem(
                                    icon: "square.on.circle",
                                    text: "Shapes (line, rectangle, circle), text, and type-on-path along a curve or a circle."
                                )
                                BetaFeatureItem(
                                    icon: "lasso",
                                    text: "Rectangle marquee + lasso selection, free transform (scale, rotate, move)."
                                )
                                BetaFeatureItem(
                                    icon: "square.stack.3d.up.fill",
                                    text: "Multi-layer drawing, undo / redo, symmetry mirror modes."
                                )
                                BetaFeatureItem(
                                    icon: "figure.stand",
                                    text: "Hand and body pose reference overlays — trace from a photo, then draw over them."
                                )
                                BetaFeatureItem(
                                    icon: "sparkles",
                                    text: "GPT-5.1 AI critique with iterative coaching — your coach remembers prior sessions on the same drawing."
                                )
                                BetaFeatureItem(
                                    icon: "person.crop.circle.badge.questionmark",
                                    text: "Four voice presets (Studio Mentor, The Crit, Fundamentals Coach, Renaissance Master) plus a freeform custom voice."
                                )
                                BetaFeatureItem(
                                    icon: "slider.horizontal.3",
                                    text: "Custom prompts — tune focus, tone, depth, and technique emphasis. Save and reuse."
                                )
                                BetaFeatureItem(
                                    icon: "chart.line.uptrend.xyaxis",
                                    text: "My Evolution — skill radar + critique wall tracking your growth across drawings."
                                )
                                BetaFeatureItem(
                                    icon: "ipad.and.iphone",
                                    text: "Universal app — iPad and iPhone with cloud sync of drawings + critique history."
                                )
                            }
                        }

                        Divider()

                        // Coming Soon Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.forward.circle.fill")
                                    .foregroundColor(.blue)
                                Text("On the horizon")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                ComingSoonItem(text: "Smarter brush sets — oil paint and watercolor with real texture.")
                                ComingSoonItem(text: "Per-drawing pinned prompts that override the global voice when active.")
                                ComingSoonItem(text: "More export formats — Procreate-compatible files and stroke-by-stroke timelapses.")
                                ComingSoonItem(text: "Sharable evolution profiles — show your growth publicly when you want to.")
                                ComingSoonItem(text: "A Pro tier with higher critique limits when paid plans land. Beta users keep the free tier as long as we can swing it.")
                            }

                            Text("Your journey matters. We're building this WITH you, not just FOR you.")
                                .font(.caption)
                                .foregroundColor(.primary)
                                .italic()
                                .padding(.top, 8)
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
                }

                Divider()

                // Continue button
                Button(action: {
                    isPresented = false
                }) {
                    Text("I Understand - Let's Create!")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
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

struct BetaWarningItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .foregroundColor(.orange)
                .fontWeight(.bold)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

struct BetaFeatureItem: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundColor(.green)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

struct ComingSoonItem: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "star.fill")
                .font(.caption)
                .foregroundColor(.blue)
                .frame(width: 20)

            Text(text)
                .font(.subheadline)
                .foregroundColor(.primary)
        }
    }
}

#Preview {
    BetaTransparencyPopup(isPresented: .constant(true))
}
