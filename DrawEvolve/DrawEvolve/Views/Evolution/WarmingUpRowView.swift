//
//  WarmingUpRowView.swift
//  DrawEvolve
//
//  Lists categories that haven't accumulated enough mentions to render a
//  trend line. Honest framing: the threshold ("of N mentions needed")
//  comes from the server's `needed` field, which is already
//  state-dependent (2 in growing, 5 in mature). Trust the server's value;
//  do not recompute client-side.
//
//  When the warming_up array is empty, this view collapses to nothing —
//  no header, no whitespace.
//

import SwiftUI

struct WarmingUpRowView: View {
    let items: [WarmingUpItem]

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Warming up")
                    .font(.caption.smallCaps())
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    Text("\(item.id.displayName) (\(item.dataPoints) of \(item.needed) mentions needed)")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
            }
        }
    }
}

#Preview {
    WarmingUpRowView(items: [
        WarmingUpItem(id: .color, dataPoints: 3, needed: 5),
        WarmingUpItem(id: .line, dataPoints: 2, needed: 5),
    ])
    .padding()
}
