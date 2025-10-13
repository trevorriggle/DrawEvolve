//
//  DrawingStorageManager.swift
//  DrawEvolve
//
//  Manages saving and loading drawings locally using FileManager.
//

import Foundation
import SwiftUI

@MainActor
class DrawingStorageManager: ObservableObject {
    static let shared = DrawingStorageManager()

    @Published var drawings: [Drawing] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let userID = AnonymousUserManager.shared.userID
    private let fileManager = FileManager.default

    private var drawingsDirectory: URL {
        let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Drawings", isDirectory: true)
    }

    init() {
        // Create drawings directory if it doesn't exist
        try? fileManager.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Fetch Drawings

    func fetchDrawings() async {
        isLoading = true
        errorMessage = nil

        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: drawingsDirectory, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])

            var loadedDrawings: [Drawing] = []

            for fileURL in fileURLs where fileURL.pathExtension == "json" {
                let data = try Data(contentsOf: fileURL)
                let drawing = try JSONDecoder().decode(Drawing.self, from: data)
                loadedDrawings.append(drawing)
            }

            // Sort by creation date, newest first
            drawings = loadedDrawings.sorted { $0.createdAt > $1.createdAt }
        } catch {
            print("Error loading drawings: \(error)")
            errorMessage = "Failed to load drawings"
        }

        isLoading = false
    }

    // MARK: - Save Drawing

    func saveDrawing(title: String, imageData: Data, feedback: String? = nil, context: DrawingContext? = nil) async throws -> Drawing {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let newDrawing = Drawing(
            id: UUID(),
            userId: UUID(uuidString: userID) ?? UUID(),
            title: title,
            imageData: imageData,
            createdAt: Date(),
            updatedAt: Date(),
            feedback: feedback,
            context: context
        )

        print("DrawingStorageManager: Saving new drawing '\(title)'")

        // Save to file system
        let fileURL = drawingsDirectory.appendingPathComponent("\(newDrawing.id.uuidString).json")
        let data = try JSONEncoder().encode(newDrawing)
        try data.write(to: fileURL)
        print("  - Saved to file: \(fileURL.lastPathComponent)")

        // Add to memory array (insert at beginning for newest-first)
        drawings.insert(newDrawing, at: 0)
        print("  - Added to in-memory array (now \(drawings.count) drawings)")

        return newDrawing
    }

    // MARK: - Update Drawing

    func updateDrawing(id: UUID, title: String? = nil, imageData: Data? = nil, feedback: String? = nil, context: DrawingContext? = nil) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        print("DrawingStorageManager: Updating drawing \(id)")

        if let index = drawings.firstIndex(where: { $0.id == id }) {
            let oldTitle = drawings[index].title

            if let title = title {
                drawings[index].title = title
                print("  - Title: '\(oldTitle)' → '\(title)'")
            }
            if let imageData = imageData {
                print("  - Updated image data: \(imageData.count) bytes")
                drawings[index].imageData = imageData
            }
            if let feedback = feedback {
                // Add new critique to history
                let critiqueEntry = CritiqueEntry(
                    feedback: feedback,
                    timestamp: Date(),
                    context: context ?? drawings[index].context
                )
                drawings[index].critiqueHistory.append(critiqueEntry)
                drawings[index].feedback = feedback
                print("  - Added feedback to critique history (now \(drawings[index].critiqueHistory.count) entries)")
            }
            if let context = context {
                drawings[index].context = context
                print("  - Updated context")
            }
            drawings[index].updatedAt = Date()

            // Save updated drawing to file system
            let fileURL = drawingsDirectory.appendingPathComponent("\(id.uuidString).json")
            let data = try JSONEncoder().encode(drawings[index])
            try data.write(to: fileURL)
            print("  - Saved to file: \(fileURL.lastPathComponent)")
            print("✅ Drawing update complete")
        } else {
            print("❌ ERROR: Drawing with ID \(id) not found in memory")
        }
    }

    // MARK: - Delete Drawing

    func deleteDrawing(id: UUID) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        // Delete from file system
        let fileURL = drawingsDirectory.appendingPathComponent("\(id.uuidString).json")
        try fileManager.removeItem(at: fileURL)

        // Remove from memory
        drawings.removeAll { $0.id == id }
    }

    // MARK: - Debug: Clear All Drawings

    func clearAllDrawings() async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        print("🗑️ DEBUG: Clearing all drawings...")

        // Delete all files in drawings directory
        let fileURLs = try fileManager.contentsOfDirectory(at: drawingsDirectory, includingPropertiesForKeys: nil)
        for fileURL in fileURLs where fileURL.pathExtension == "json" {
            try fileManager.removeItem(at: fileURL)
            print("  - Deleted: \(fileURL.lastPathComponent)")
        }

        // Clear memory
        drawings.removeAll()
        print("✅ All drawings cleared")
    }
}

// MARK: - Errors

enum DrawingStorageError: LocalizedError {
    case notAuthenticated
    case saveFailed
    case fetchFailed

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "You must be logged in to save drawings"
        case .saveFailed:
            return "Failed to save drawing"
        case .fetchFailed:
            return "Failed to fetch drawings"
        }
    }
}
