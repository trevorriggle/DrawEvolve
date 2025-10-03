import Foundation
import SwiftUI
import UIKit
import PencilKit

// MARK: - UIImage Extensions

extension UIImage {
    /// Convert UIImage to base64 string for API transmission (JPEG)
    func toBase64(compressionQuality: CGFloat = 0.8) -> String? {
        guard let imageData = self.jpegData(compressionQuality: compressionQuality) else {
            return nil
        }
        return imageData.base64EncodedString()
    }

    /// Resize image to max dimension while maintaining aspect ratio
    func resized(maxDimension: CGFloat) -> UIImage? {
        let ratio = min(maxDimension / size.width, maxDimension / size.height)
        let newSize = CGSize(width: size.width * ratio, height: size.height * ratio)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        defer { UIGraphicsEndImageContext() }

        draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext()
    }
}

// MARK: - PKCanvasView Extensions

extension PKCanvasView {
    /// Render canvas drawing to UIImage with proper bounds and scale
    /// Returns high-quality PNG representation of the drawing
    func renderToImage() -> UIImage? {
        let drawing = self.drawing
        let bounds = drawing.bounds

        // Handle empty canvas
        guard !bounds.isEmpty else {
            // Return a default-sized white image for empty canvas
            let size = CGSize(width: 512, height: 512)
            UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
            defer { UIGraphicsEndImageContext() }

            UIColor.white.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))

            return UIGraphicsGetImageFromCurrentImageContext()
        }

        // Render drawing to image at 1x scale for reasonable file size
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0 // Use 1x scale to reduce image size
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { context in
            // White background
            UIColor.white.setFill()
            context.fill(bounds)

            // Draw the canvas content
            drawing.image(from: bounds, scale: 1.0).draw(in: bounds)
        }
    }
}

// MARK: - View Extensions

extension View {
    /// Apply conditional modifier
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - String Extensions

extension String {
    /// Trim whitespace and newlines
    var trimmed: String {
        self.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Check if string is empty or only whitespace
    var isBlank: Bool {
        self.trimmed.isEmpty
    }
}
