//
//  EveConversation.swift
//  DrawEvolve
//
//  Models for the Eve conversational coach (Feature 2, Phase 2A).
//
//  Schema-coupled to supabase/migrations/0012_eve_conversations.sql. When
//  the worker / migration ships a new column, mirror it here AND in the
//  CodingKeys block. The server response shape (snake_case) is unwound to
//  camelCase here, matching the convention the rest of the iOS codebase
//  uses (Drawing.swift, CritiqueEntry.swift).
//

import Foundation

// =============================================================================
// Scope
// =============================================================================
//
// Each conversation is anchored to one of three scopes:
//   - .drawing: opened via "Ask Eve" on a critique panel. The worker
//     hydrates the critique and seeds the system prompt with it.
//   - .general: opened via the dedicated EVE icon in the canvas action
//     column. No drawing context — Eve introduces herself and asks
//     what's on the user's mind.
//   - .evolution: reserved for the My Evolution surface in 2C. The
//     worker REJECTS this scope on create in 2A — the model is server-
//     gated, so the iOS client also gates here to match.

enum EveScope: String, Codable, Sendable {
    case drawing
    case evolution
    case general
}

// =============================================================================
// EveConversation
// =============================================================================

struct EveConversation: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let userId: UUID
    var title: String?
    var firstUserMessage: String?
    let scope: EveScope
    let scopeDrawingId: UUID?
    let scopeCritiqueSequence: Int?
    let createdAt: Date
    var updatedAt: Date
    var lastMessageAt: Date
    var messageCount: Int
    var totalInputTokens: Int
    var totalOutputTokens: Int
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case title
        case firstUserMessage = "first_user_message"
        case scope
        case scopeDrawingId = "scope_drawing_id"
        case scopeCritiqueSequence = "scope_critique_sequence"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastMessageAt = "last_message_at"
        case messageCount = "message_count"
        case totalInputTokens = "total_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case deletedAt = "deleted_at"
    }
}

// =============================================================================
// EveMessage
// =============================================================================
//
// `role` is the same three-value enum the schema CHECK constraint pins.
// `tool` rows are reserved for 2C — in 2A the iOS UI silently filters
// them out of the rendered bubble list (same filter the worker uses
// when building messages for OpenAI).

enum EveMessageRole: String, Codable, Sendable {
    case user
    case assistant
    case tool
}

struct EveMessage: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let conversationId: UUID
    let role: EveMessageRole
    let content: String
    let createdAt: Date
    let promptTokenCount: Int?
    let completionTokenCount: Int?
    let personaVersion: Int?
    let productContextVersion: Int?

    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case role
        case content
        case createdAt = "created_at"
        case promptTokenCount = "prompt_token_count"
        case completionTokenCount = "completion_token_count"
        case personaVersion = "persona_version"
        case productContextVersion = "product_context_version"
    }
}

// =============================================================================
// Wire response shapes
// =============================================================================
//
// Mirror the JSON the Worker returns on each endpoint. Kept distinct from
// the storage models so a future server change (e.g. an extra response
// field) doesn't have to thread through the canonical model. The service
// layer translates wire types into storage types.

struct EveConversationResponse: Decodable, Sendable {
    let conversation: EveConversation
    // Worker carries this on POST /v1/eve/conversations when the cap
    // (MAX_ACTIVE_CONVERSATIONS = 50 server-side) forced an eviction
    // before insert. Currently decoded-and-ignored on the iOS side per
    // product decision: silent eviction is the goal, no banner. Field
    // is reserved for future use (e.g., "recently archived" recovery
    // sub-view). Always null on GET / PATCH responses.
    let evictedConversationId: UUID?

    enum CodingKeys: String, CodingKey {
        case conversation
        case evictedConversationId = "evicted_conversation_id"
    }
}

struct EveConversationListResponse: Decodable, Sendable {
    let conversations: [EveConversation]
}

struct EveConversationDetailResponse: Decodable, Sendable {
    let conversation: EveConversation
    let messages: [EveMessage]
}

struct EveSendMessageResponse: Decodable, Sendable {
    let userMessage: EveMessage?
    let assistantMessage: EveMessage
    let conversation: EveConversation
    let warning: String?

    enum CodingKeys: String, CodingKey {
        case userMessage = "user_message"
        case assistantMessage = "assistant_message"
        case conversation
        case warning
    }
}

// =============================================================================
// String truncation helper — used by ConversationRow + EveSheetHost nav title
// =============================================================================
//
// Word-boundary aware truncation. If the string is shorter than maxLen,
// return as-is. Otherwise cut to maxLen, look backwards for a whitespace
// boundary within wordBoundaryLookback chars of the cut; if found, slice
// there and append the ellipsis. If no nearby boundary exists, accept
// the hard cut at maxLen to avoid pathologically short results.
//
// Mirrors the deriveTitleFromMessage helper in the Cloudflare worker
// (cloudflare-worker/routes/eve.js TITLE_MAX_CHARS / TITLE_WORD_BOUNDARY_
// LOOKBACK constants). Defaults: 60 char list rows, 40 char nav titles —
// caller passes whichever cap.

extension String {
    func truncatedAtWordBoundary(
        maxLen: Int,
        ellipsis: String = "…",
        wordBoundaryLookback: Int = 10
    ) -> String {
        guard self.count > maxLen else { return self }
        let window = self.prefix(maxLen)
        if let lastSpaceIndex = window.lastIndex(where: { $0.isWhitespace }),
           window.distance(from: lastSpaceIndex, to: window.endIndex) <= wordBoundaryLookback {
            return window[..<lastSpaceIndex] + ellipsis
        }
        return window + ellipsis
    }
}
