//
//  CritiqueHistory.swift
//  DrawEvolve
//
//  Model representing a critique/feedback entry in the history.
//

import Foundation

struct CritiqueEntry: Codable, Identifiable {
    let id: UUID
    let feedback: String
    let timestamp: Date
    let context: DrawingContext?

    init(id: UUID = UUID(), feedback: String, timestamp: Date = Date(), context: DrawingContext? = nil) {
        self.id = id
        self.feedback = feedback
        self.timestamp = timestamp
        self.context = context
    }
}
