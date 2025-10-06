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
    @State private var showToolPicker = true

    var body: some View {
        NavigationView {
            ZStack {
                // Canvas
                CanvasRepresentable(
                    canvasView: $canvasState.canvasView,
                    showToolPicker: $showToolPicker
                )
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

                // Bottom action bar
                VStack {
                    Spacer()
                    HStack(spacing: 16) {
                        Button(action: clearCanvas) {
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 20))
                                Text("Clear")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(12)
                        }

                        Button(action: requestFeedback) {
                            VStack(spacing: 4) {
                                if isRequestingFeedback {
                                    ProgressView()
                                } else {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 20))
                                    Text("Get Feedback")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                        }
                        .disabled(isRequestingFeedback || canvasState.canvasView.drawing.bounds.isEmpty)
                        .opacity(canvasState.canvasView.drawing.bounds.isEmpty ? 0.5 : 1.0)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showToolPicker.toggle() }) {
                        Image(systemName: showToolPicker ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle")
                    }
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
    @Binding var showToolPicker: Bool

    func makeUIView(context: Context) -> PKCanvasView {
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 2)
        canvasView.drawingPolicy = .anyInput
        canvasView.backgroundColor = .systemBackground
        canvasView.becomeFirstResponder()
        return canvasView
    }

    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Update tool picker visibility
        if let window = uiView.window,
           let toolPicker = PKToolPicker.shared(for: window) {
            toolPicker.setVisible(showToolPicker, forFirstResponder: uiView)
            toolPicker.addObserver(uiView)
        }
    }
}

#Preview {
    DrawingCanvasView(context: .constant(DrawingContext(
        subject: "Portrait",
        style: "Realism"
    )))
}
