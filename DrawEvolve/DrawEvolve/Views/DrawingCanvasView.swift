//
//  DrawingCanvasView.swift
//  DrawEvolve
//
//  PencilKit-powered drawing canvas with feedback request capability.
//

import SwiftUI
import PencilKit

struct DrawingCanvasView: View {
    @Binding var context: DrawingContext
    @StateObject private var canvasState = CanvasState()
    @State private var showFeedback = false
    @State private var isRequestingFeedback = false

    var body: some View {
        NavigationView {
            ZStack {
                // Canvas
                CanvasRepresentable(canvasView: $canvasState.canvasView)
                    .background(Color(uiColor: .systemBackground))

                // Feedback overlay
                if showFeedback, let feedback = canvasState.feedback {
                    FeedbackOverlay(
                        feedback: feedback,
                        isPresented: $showFeedback,
                        canvasImage: canvasState.capturedImage
                    )
                    .transition(.move(edge: .trailing))
                }
            }
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button(action: clearCanvas) {
                        Label("Clear", systemImage: "trash")
                    }

                    Button(action: requestFeedback) {
                        if isRequestingFeedback {
                            ProgressView()
                        } else {
                            Label("Feedback", systemImage: "sparkles")
                        }
                    }
                    .disabled(isRequestingFeedback || canvasState.canvasView.drawing.bounds.isEmpty)
                }
            }
        }
        .alert("Feedback Error", isPresented: $canvasState.showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(canvasState.errorMessage)
        }
    }

    private func clearCanvas() {
        canvasState.canvasView.drawing = PKDrawing()
    }

    private func requestFeedback() {
        isRequestingFeedback = true

        Task {
            await canvasState.requestFeedback(for: context)
            isRequestingFeedback = false
            if canvasState.feedback != nil {
                withAnimation {
                    showFeedback = true
                }
            }
        }
    }
}

/// Observable state for the canvas
@MainActor
class CanvasState: ObservableObject {
    @Published var canvasView = PKCanvasView()
    @Published var feedback: String?
    @Published var capturedImage: UIImage?
    @Published var showError = false
    @Published var errorMessage = ""

    func requestFeedback(for context: DrawingContext) async {
        // Capture the drawing as an image
        guard let image = captureDrawing() else {
            showError(message: "Failed to capture drawing image")
            return
        }
        capturedImage = image

        // Request feedback from OpenAI
        do {
            let feedbackText = try await OpenAIManager.shared.requestFeedback(
                image: image,
                context: context
            )
            feedback = feedbackText
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func captureDrawing() -> UIImage? {
        let drawing = canvasView.drawing
        return drawing.image(from: drawing.bounds, scale: 1.0)
    }

    private func showError(message: String) {
        errorMessage = message
        showError = true
    }
}

/// UIViewRepresentable wrapper for PKCanvasView
struct CanvasRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 2)
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .systemBackground
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {}
}

#Preview {
    DrawingCanvasView(context: .constant(DrawingContext(
        subject: "Portrait",
        style: "Realism"
    )))
}
