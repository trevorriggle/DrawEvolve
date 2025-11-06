//
//  FeedbackOverlay.swift
//  DrawEvolve
//
//  Displays AI feedback alongside the user's drawing.
//

import SwiftUI

struct FeedbackOverlay: View {
    let feedback: String?
    let isLoading: Bool
    @Binding var isPresented: Bool
    let canvasImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // Header with close button
                HStack {
                    Label("AI Feedback", systemImage: "sparkles")
                        .font(.headline)
                    Spacer()
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundColor(.primary)
                    }
                }
                .padding()
                .background(Color(uiColor: .systemBackground))

                Divider()

                // Loading state OR content
                if isLoading {
                    VStack(spacing: 24) {
                        Spacer()

                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.accentColor)

                        Text("Sit tight — your analysis is on the way!")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                } else if let feedbackText = feedback {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // Canvas preview on top
                            if let image = canvasImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .frame(maxHeight: geometry.size.height * 0.4)
                                    .background(Color(uiColor: .secondarySystemBackground))
                                    .cornerRadius(12)
                                    .shadow(radius: 2)
                            }

                            // Custom formatted feedback below
                            FormattedMarkdownView(text: feedbackText)
                                .textSelection(.enabled)
                        }
                        .padding()
                    }
                    .background(Color(uiColor: .systemBackground))

                    // Continue Drawing button at bottom
                    VStack {
                        Divider()
                        Button(action: { isPresented = false }) {
                            HStack {
                                Spacer()
                                Text("Continue Drawing")
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                            .padding()
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .padding()
                    }
                    .background(Color(uiColor: .systemBackground))
                } else {
                    // Empty state (shouldn't happen, but just in case)
                    VStack {
                        Spacer()
                        Text("No feedback available")
                            .foregroundColor(.primary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(uiColor: .systemBackground))
                }
            }
        }
        .edgesIgnoringSafeArea(.all)
    }
}

#Preview {
    FeedbackOverlay(
        feedback: """
        Great work on your portrait! Your proportions are well-balanced, especially the placement of the eyes and nose.

        Here's what I noticed:

        **Strengths:**
        - The facial structure shows good understanding of anatomy
        - Your shading technique adds nice depth to the cheekbones

        **Areas to improve:**
        - Consider softening the transition between light and shadow on the forehead
        - The ear could be positioned slightly higher to align with the eyebrow

        Keep practicing your hatching technique—it's really coming along! (And hey, even Picasso had to start somewhere, right?)
        """,
        isLoading: false,
        isPresented: .constant(true),
        canvasImage: nil
    )
}

#Preview("Loading State") {
    FeedbackOverlay(
        feedback: nil,
        isLoading: true,
        isPresented: .constant(true),
        canvasImage: nil
    )
}
