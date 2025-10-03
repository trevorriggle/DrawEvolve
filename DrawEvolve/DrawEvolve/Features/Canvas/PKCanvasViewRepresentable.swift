import SwiftUI
import PencilKit

/// SwiftUI wrapper for PencilKit's PKCanvasView (UIKit)
/// Bridges UIKit ↔ SwiftUI to enable drawing with Apple Pencil or finger
struct PKCanvasViewRepresentable: UIViewRepresentable {
    @Binding var canvasView: PKCanvasView
    let toolPicker: PKToolPicker = PKToolPicker()

    // MARK: - UIViewRepresentable

    /// Create the underlying UIKit PKCanvasView
    func makeUIView(context: Context) -> PKCanvasView {
        // Configure canvas for drawing
        canvasView.drawingPolicy = .anyInput  // Allow finger and Apple Pencil
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true

        // Set default tool
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 3)

        // Show the tool picker (drawing tools UI)
        toolPicker.setVisible(true, forFirstResponder: canvasView)
        toolPicker.addObserver(canvasView)
        canvasView.becomeFirstResponder()

        // Register for clear notification
        NotificationCenter.default.addObserver(
            forName: .clearCanvas,
            object: nil,
            queue: .main
        ) { _ in
            canvasView.drawing = PKDrawing()  // Clear the drawing
        }

        return canvasView
    }

    /// Update the view when SwiftUI state changes
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        // Ensure tool picker stays visible
        toolPicker.setVisible(true, forFirstResponder: uiView)
    }

    /// Cleanup when view is removed
    static func dismantleUIView(_ uiView: PKCanvasView, coordinator: ()) {
        NotificationCenter.default.removeObserver(uiView, name: .clearCanvas, object: nil)
    }
}

// MARK: - Notification Extension

extension Notification.Name {
    /// Notification to trigger canvas clear
    static let clearCanvas = Notification.Name("clearCanvas")
}
