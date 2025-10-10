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

        // Save to file system
        let fileURL = drawingsDirectory.appendingPathComponent("\(newDrawing.id.uuidString).json")
        let data = try JSONEncoder().encode(newDrawing)
        try data.write(to: fileURL)

        // Add to memory array
        drawings.insert(newDrawing, at: 0)

        return newDrawing
    }

    // MARK: - Update Drawing

    func updateDrawing(id: UUID, title: String? = nil, imageData: Data? = nil, feedback: String? = nil, context: DrawingContext? = nil) async throws {
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        if let index = drawings.firstIndex(where: { $0.id == id }) {
            if let title = title {
                drawings[index].title = title
            }
            if let imageData = imageData {
                drawings[index].imageData = imageData
            }
            if let feedback = feedback {
                drawings[index].feedback = feedback
            }
            if let context = context {
                drawings[index].context = context
            }
            drawings[index].updatedAt = Date()

            // Save updated drawing to file system
            let fileURL = drawingsDirectory.appendingPathComponent("\(id.uuidString).json")
            let data = try JSONEncoder().encode(drawings[index])
            try data.write(to: fileURL)
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
