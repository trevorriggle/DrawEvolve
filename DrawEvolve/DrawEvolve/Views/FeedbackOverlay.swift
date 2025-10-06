//
//  FeedbackOverlay.swift
//  DrawEvolve
//
//  Displays AI feedback alongside the user's drawing.
//

import SwiftUI

struct FeedbackOverlay: View {
    let feedback: String
    @Binding var isPresented: Bool
    let canvasImage: UIImage?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                // Canvas preview (left side)
                if let image = canvasImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geometry.size.width * 0.45)
                        .background(Color(uiColor: .secondarySystemBackground))
                        .border(Color(uiColor: .separator), width: 1)
                }

                // Feedback panel (right side)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("AI Feedback", systemImage: "sparkles")
                            .font(.headline)
                        Spacer()
                        Button(action: { isPresented = false }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                    }

                    Divider()

                    ScrollView {
                        Text(feedback)
                            .font(.body)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

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
                }
                .padding()
                .frame(width: geometry.size.width * 0.55)
                .background(Color(uiColor: .systemBackground))
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
        isPresented: .constant(true),
        canvasImage: nil
    )
}
