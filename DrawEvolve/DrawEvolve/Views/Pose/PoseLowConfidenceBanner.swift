//
//  PoseLowConfidenceBanner.swift
//  DrawEvolve
//
//  Auto-dismissing banner that appears at the top of the canvas chrome
//  after a detection produces low-confidence joints. The on-skeleton
//  yellow pulse (PR 2) signals which joints are uncertain; this banner
//  is the second layer of feedback that summarizes the count and
//  suggests the action ("drag the highlighted ones").
//
//  Visible duration is owned by `PoseOverlayManager.bannerVisibleDuration`
//  (5 seconds at the time of this PR — audit §4.2). Dismissal is
//  immediate on the X tap; the manager cancels its auto-dismiss task so
//  no stale callback re-shows the banner.
//

import SwiftUI

struct PoseLowConfidenceBanner: View {
    @ObservedObject var poseManager: PoseOverlayManager

    var body: some View {
        VStack {
            if let entry = poseManager.lowConfidenceBanner {
                bannerCard(entry: entry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
        }
        .animation(.easeInOut(duration: 0.25), value: poseManager.lowConfidenceBanner)
        .allowsHitTesting(poseManager.lowConfidenceBanner != nil)
    }

    private func bannerCard(entry: PoseOverlayManager.BannerEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)

            Text(message(entry: entry))
                .font(.subheadline)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button(action: { poseManager.dismissLowConfidenceBanner() }) {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Dismiss low-confidence notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.78))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 2)
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func message(entry: PoseOverlayManager.BannerEntry) -> String {
        let n = entry.lowConfidenceCount
        let kindWord = entry.kind == .hand ? "hand" : "body"
        let jointWord = n == 1 ? "joint" : "joints"
        return "\(n) \(kindWord) \(jointWord) couldn't be seen clearly — drag the yellow \(jointWord) to refine."
    }
}
