import Foundation
import SwiftUI

/// Available drawing styles for the style picker
enum DrawingStyle: String, CaseIterable, Identifiable {
    case realism = "Realism"
    case comics = "Comics"
    case anime = "Anime"
    case abstract = "Abstract"

    var id: String { rawValue }
}

/// Manages user context (subject, style, focus) with @AppStorage persistence
class ContextModel: ObservableObject {
    @AppStorage("user_subject") var subject: String = ""
    @AppStorage("user_style") var styleRaw: String = DrawingStyle.realism.rawValue
    @AppStorage("user_focus") var focus: String = ""
    @AppStorage("onboarding_completed") var onboardingCompleted: Bool = false

    /// Computed property for style as enum
    var style: DrawingStyle {
        get { DrawingStyle(rawValue: styleRaw) ?? .realism }
        set { styleRaw = newValue.rawValue }
    }

    /// Check if all required fields are filled
    var isValid: Bool {
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Convert to API model
    var userContext: UserContext {
        UserContext(subject: subject, style: style.rawValue, focus: focus)
    }

    /// Mark onboarding as completed
    func save() {
        onboardingCompleted = true
    }

    /// Reset all stored values (for testing or re-onboarding)
    func reset() {
        subject = ""
        styleRaw = DrawingStyle.realism.rawValue
        focus = ""
        onboardingCompleted = false
    }
}
