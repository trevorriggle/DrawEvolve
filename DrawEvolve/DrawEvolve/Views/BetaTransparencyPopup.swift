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
                                Text("This is a BETA")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaWarningItem(text: "There WILL be bugs")
                                BetaWarningItem(text: "There WILL be tools that don't work perfectly")
                                BetaWarningItem(text: "There WILL be UI quirks")
                                BetaWarningItem(text: "There WILL be occasional crashes")
                                BetaWarningItem(text: "Your feedback helps us improve")
                            }
                        }

                        Divider()

                        // What We Have Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("What We DO Have")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                BetaFeatureItem(
                                    icon: "paintbrush.pointed.fill",
                                    text: "Metal-based drawing engine with smooth, responsive rendering"
                                )
                                BetaFeatureItem(
                                    icon: "square.stack.3d.up.fill",
                                    text: "Multi-layer system with undo/redo"
                                )
                                BetaFeatureItem(
                                    icon: "hammer.fill",
                                    text: "Core tools: brush, eraser, shapes, text, paint bucket, eyedropper"
                                )
                                BetaFeatureItem(
                                    icon: "sparkles",
                                    text: "GPT-4o Vision AI feedback with personalized, encouraging guidance"
                                )
                            }
                        }

                        Divider()

                        // Coming Soon Section
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 8) {
                                Image(systemName: "arrow.forward.circle.fill")
                                    .foregroundColor(.blue)
                                Text("On the Horizon")
                                    .font(.headline)
                                    .fontWeight(.bold)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                ComingSoonItem(text: "Progress tracking to see your artistic evolution over time")
                                ComingSoonItem(text: "Custom AI art mentors with unique personalities (Bob Ross mode, anyone?)")
                                ComingSoonItem(text: "Portfolio analysis that tracks your improvement automatically")
                                ComingSoonItem(text: "Community galleries to share and discover artwork")
                                ComingSoonItem(text: "Advanced brushes with watercolor, oil paint, and custom effects")
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
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .background(Color.accentColor)
                .cornerRadius(12)
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
