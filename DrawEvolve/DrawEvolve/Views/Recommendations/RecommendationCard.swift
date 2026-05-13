//
//  RecommendationCard.swift
//  DrawEvolve
//
//  Single tappable card for one recommendation. Used inside
//  RecommendationsView (the full 5-up sheet) and inside the
//  "Recommended next" section on the Evolution panel (3-up inline).
//
//  Visual: subject as headline, rationale as subtext, type badge on
//  the trailing edge. No emoji, no sparkle — matches the EVE-as-text
//  precedent the owner established.
//

import SwiftUI

struct RecommendationCard: View {
    let recommendation: Recommendation
    var onTap: () -> Void

    /// Display style. `.full` renders the rationale + type badge for
    /// the dedicated RecommendationsView sheet. `.compact` drops the
    /// badge for tighter layouts (the 3-up inline on Evolution).
    enum Style {
        case full
        case compact
    }
    var style: Style = .full

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(recommendation.subject)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    Text(recommendation.rationale)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(style == .full ? nil : 3)
                    if style == .full, !recommendation.focusArea.isEmpty {
                        Text("Focus: \(recommendation.focusArea)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)

                if style == .full {
                    typeBadge
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemBackground))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Suggested subject: \(recommendation.subject)")
        .accessibilityHint(recommendation.rationale)
    }

    @ViewBuilder
    private var typeBadge: some View {
        if !recommendation.recommendationType.displayLabel.isEmpty {
            Text(recommendation.recommendationType.displayLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(typeColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule().fill(typeColor.opacity(0.15))
                )
        }
    }

    private var typeColor: Color {
        switch recommendation.recommendationType {
        case .skillTargeting: return .blue
        case .variety:        return .green
        case .stretch:        return .orange
        case .unknown:        return .gray
        }
    }
}
