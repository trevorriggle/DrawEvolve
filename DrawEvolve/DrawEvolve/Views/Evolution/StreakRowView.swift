//
//  StreakRowView.swift
//  DrawEvolve
//
//  Zone 1 of the Evolution dashboard. Four counters in a horizontal row.
//  Always rendered, in every state — including "example" where the real
//  values are zeros and we surface those zeros honestly. No fire emojis,
//  no motivational copy, no padding around zeros.
//

import SwiftUI

struct StreakRowView: View {
    let streak: StreakData

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            counter(value: streak.drawingsThisWeek, label: "This week")
            counter(value: streak.drawingsThisMonth, label: "This month")
            counter(value: streak.critiquesTotal, label: "Critiques")
            counter(value: streak.drawingsTotal, label: "Drawings")
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private func counter(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text("\(value)")
                .font(.system(.title, design: .rounded).monospacedDigit())
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
            Text(label.uppercased())
                .font(.caption2)
                .tracking(0.5)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    StreakRowView(streak: StreakData(
        drawingsThisWeek: 2,
        drawingsThisMonth: 7,
        critiquesTotal: 18,
        drawingsTotal: 12
    ))
    .padding()
}
