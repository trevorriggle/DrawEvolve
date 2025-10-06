//
//  DrawingContext.swift
//  DrawEvolve
//
//  Created by DrawEvolve Team
//

import Foundation

/// Holds the user's pre-drawing questionnaire responses
struct DrawingContext: Codable {
    var subject: String = ""
    var style: String = ""
    var artists: String = ""
    var techniques: String = ""
    var focus: String = ""
    var additionalContext: String = ""

    var isComplete: Bool {
        !subject.isEmpty && !style.isEmpty
    }
}
