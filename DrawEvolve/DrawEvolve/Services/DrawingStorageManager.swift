//
//  DrawingStorageManager.swift
//  DrawEvolve
//
//  Manages saving and loading drawings locally.
//  TODO: Implement persistence (currently stubbed out)
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

    // MARK: - Fetch Drawings

    func fetchDrawings() async {
        // TODO: Implement local storage fetch
        isLoading = true
        errorMessage = nil

        // Simulate loading
        try? await Task.sleep(nanoseconds: 500_000_000)

        // For now, just return empty
        drawings = []
        isLoading = false
    }

    // MARK: - Save Drawing

    func saveDrawing(title: String, imageData: Data) async throws -> Drawing {
        // TODO: Implement local storage save
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let newDrawing = Drawing(
            id: UUID(),
            userId: UUID(uuidString: userID) ?? UUID(),
            title: title,
            imageData: imageData,
            createdAt: Date(),
            updatedAt: Date()
        )

        // For now, just add to memory (will be lost on app restart)
        drawings.insert(newDrawing, at: 0)

        return newDrawing
    }

    // MARK: - Update Drawing

    func updateDrawing(id: UUID, title: String?, imageData: Data?) async throws {
        // TODO: Implement local storage update
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        if let index = drawings.firstIndex(where: { $0.id == id }) {
            if let title = title {
                drawings[index].title = title
                drawings[index].updatedAt = Date()
            }
        }
    }

    // MARK: - Delete Drawing

    func deleteDrawing(id: UUID) async throws {
        // TODO: Implement local storage delete
        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

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
