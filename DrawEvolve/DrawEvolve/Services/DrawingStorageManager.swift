//
//  DrawingStorageManager.swift
//  DrawEvolve
//
//  Manages saving and loading drawings from Supabase.
//

import Foundation
import SwiftUI
import Supabase

@MainActor
class DrawingStorageManager: ObservableObject {
    static let shared = DrawingStorageManager()

    @Published var drawings: [Drawing] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let supabase = SupabaseManager.shared.client

    // MARK: - Fetch Drawings

    func fetchDrawings() async {
        guard let userId = AuthManager.shared.currentUser?.id else {
            errorMessage = "User not authenticated"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            let response: [Drawing] = try await supabase
                .from("drawings")
                .select()
                .eq("user_id", value: userId.uuidString)
                .order("created_at", ascending: false)
                .execute()
                .value

            drawings = response
        } catch {
            errorMessage = error.localizedDescription
            print("Error fetching drawings: \(error)")
        }

        isLoading = false
    }

    // MARK: - Save Drawing

    func saveDrawing(title: String, imageData: Data) async throws -> Drawing {
        guard let userId = AuthManager.shared.currentUser?.id else {
            throw DrawingStorageError.notAuthenticated
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        let newDrawing = Drawing(
            id: UUID(),
            userId: userId,
            title: title,
            imageData: imageData,
            createdAt: Date(),
            updatedAt: Date()
        )

        do {
            let _: Drawing = try await supabase
                .from("drawings")
                .insert(newDrawing)
                .select()
                .single()
                .execute()
                .value

            // Refresh drawings list
            await fetchDrawings()

            return newDrawing
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Update Drawing

    func updateDrawing(id: UUID, title: String?, imageData: Data?) async throws {
        guard AuthManager.shared.currentUser != nil else {
            throw DrawingStorageError.notAuthenticated
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        var updates: [String: Any] = [:]
        if let title = title {
            updates["title"] = title
        }
        if let imageData = imageData {
            updates["image_data"] = imageData
        }

        do {
            try await supabase
                .from("drawings")
                .update(updates)
                .eq("id", value: id.uuidString)
                .execute()

            // Refresh drawings list
            await fetchDrawings()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    // MARK: - Delete Drawing

    func deleteDrawing(id: UUID) async throws {
        guard AuthManager.shared.currentUser != nil else {
            throw DrawingStorageError.notAuthenticated
        }

        isLoading = true
        errorMessage = nil

        defer { isLoading = false }

        do {
            try await supabase
                .from("drawings")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()

            // Remove from local array
            drawings.removeAll { $0.id == id }
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
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
