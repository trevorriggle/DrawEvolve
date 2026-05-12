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

                    Text("Here's where things stand.")
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
                        Text("A few things to know")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BetaWarningItem(text: "Bugs will happen. Tell us what you find.")
                        BetaWarningItem(text: "The iPhone build has more rough edges than iPad. Both work, but iPad feels more polished right now.")
                        BetaWarningItem(text: "Auto-save keeps your work backed up between manual saves, so a crash won't wipe what you've drawn.")
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text("What you can do")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        BetaFeatureItem(
                            icon: "paintbrush.pointed.fill",
                            text: "Six brushes: pencil, brush, ink pen, marker, airbrush, charcoal."
                        )
                        BetaFeatureItem(
                            icon: "drop.fill",
                            text: "Eraser, blur brush, blur adjustment, smudge, paint bucket, eyedropper."
                        )
                        BetaFeatureItem(
                            icon: "square.on.circle",
                            text: "Shapes, text, and type along a curve or a circle."
                        )
                        BetaFeatureItem(
                            icon: "lasso",
                            text: "Rectangle and lasso selection. Free scale and rotate."
                        )
                        BetaFeatureItem(
                            icon: "square.stack.3d.up.fill",
                            text: "Multi-layer canvas, undo and redo, symmetry mirror modes."
                        )
                        BetaFeatureItem(
                            icon: "figure.stand",
                            text: "Hand and body pose overlays you can trace from a photo."
                        )
                        BetaFeatureItem(
                            icon: "sparkles",
                            text: "AI critique that remembers what it told you last time on the same drawing."
                        )
                        BetaFeatureItem(
                            icon: "person.crop.circle.badge.questionmark",
                            text: "Four coach voices, or write your own."
                        )
                        BetaFeatureItem(
                            icon: "slider.horizontal.3",
                            text: "Custom prompts you can save and reuse."
                        )
                        BetaFeatureItem(
                            icon: "chart.line.uptrend.xyaxis",
                            text: "A skill radar that tracks how you're improving."
                        )
                        BetaFeatureItem(
                            icon: "ipad.and.iphone",
                            text: "Works on iPad and iPhone."
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.forward.circle.fill")
                            .foregroundColor(.blue)
                        Text("What's coming")
                            .font(.headline)
                            .fontWeight(.bold)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ComingSoonItem(text: "Better brushes. Oil paint and watercolor with real texture.")
                        ComingSoonItem(text: "Pinned prompts that override your default voice for one drawing.")
                        ComingSoonItem(text: "More export options.")
                        ComingSoonItem(text: "Sharing your evolution if you want to.")
                    }

                    Text("Thanks for testing early. Your feedback shapes this.")
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

                    Text("Here's where things stand.")
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
                                Text("A few things to know")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaWarningItem(text: "Bugs will happen. Tell us what you find.")
                                BetaWarningItem(text: "The iPhone build has more rough edges than iPad. Both work, but iPad feels more polished right now.")
                                BetaWarningItem(text: "Auto-save keeps your work backed up between manual saves, so a crash won't wipe what you've drawn.")
                            }
                        }

                        Divider()

                        // What We Have Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("What you can do")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaFeatureItem(
                                    icon: "paintbrush.pointed.fill",
                                    text: "Six brushes: pencil, brush, ink pen, marker, airbrush, charcoal."
                                )
                                BetaFeatureItem(
                                    icon: "drop.fill",
                                    text: "Eraser, blur brush, blur adjustment, smudge, paint bucket, eyedropper."
                                )
                                BetaFeatureItem(
                                    icon: "square.on.circle",
                                    text: "Shapes, text, and type along a curve or a circle."
                                )
                                BetaFeatureItem(
                                    icon: "lasso",
                                    text: "Rectangle and lasso selection. Free scale and rotate."
                                )
                                BetaFeatureItem(
                                    icon: "square.stack.3d.up.fill",
                                    text: "Multi-layer canvas, undo and redo, symmetry mirror modes."
                                )
                                BetaFeatureItem(
                                    icon: "figure.stand",
                                    text: "Hand and body pose overlays you can trace from a photo."
                                )
                                BetaFeatureItem(
                                    icon: "sparkles",
                                    text: "AI critique that remembers what it told you last time on the same drawing."
                                )
                                BetaFeatureItem(
                                    icon: "person.crop.circle.badge.questionmark",
                                    text: "Four coach voices, or write your own."
                                )
                                BetaFeatureItem(
                                    icon: "slider.horizontal.3",
                                    text: "Custom prompts you can save and reuse."
                                )
                                BetaFeatureItem(
                                    icon: "chart.line.uptrend.xyaxis",
                                    text: "A skill radar that tracks how you're improving."
                                )
                                BetaFeatureItem(
                                    icon: "ipad.and.iphone",
                                    text: "Works on iPad and iPhone."
                                )
                            }
                        }

                        Divider()

                        // Coming Soon Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.forward.circle.fill")
                                    .foregroundColor(.blue)
                                Text("What's coming")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                ComingSoonItem(text: "Better brushes. Oil paint and watercolor with real texture.")
                                ComingSoonItem(text: "Pinned prompts that override your default voice for one drawing.")
                                ComingSoonItem(text: "More export options.")
                                ComingSoonItem(text: "Sharing your evolution if you want to.")
                            }

                            Text("Thanks for testing early. Your feedback shapes this.")
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
