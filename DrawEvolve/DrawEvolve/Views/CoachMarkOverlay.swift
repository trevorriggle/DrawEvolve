//
//  CoachMarkOverlay.swift
//  DrawEvolve
//
//  Reusable anchor-resolving overlay for first-encounter coach marks.
//  Used by the tutorial flow (Get Feedback button, Ask Eve row, Gallery
//  tabs) to highlight a UI affordance with a callout bubble.
//
//  USAGE — two paired modifiers:
//    1. Mark the target view with .coachMarkAnchor(.getFeedback)
//    2. Attach .coachMark(isPresented:, anchor:, title:, body:) on an
//       ancestor (typically the screen's root container)
//
//  Tap anywhere dismisses. Single-mark-at-a-time API; for sequences
//  (Gallery 3-tab tour), the caller drives a @State CoachMarkID? and
//  swaps it between callouts.
//
//  POSITIONING:
//    - Callout chooses above or below target based on which side has
//      more vertical space.
//    - Horizontal: centered on target, clamped to screen with 24pt
//      margins. Max callout width 360pt — fits on iPhone SE (327pt
//      content width) and reads comfortably on iPad.
//
//  IPAD-FIRST per the v3 fallback plan: the positioning math is
//  idiom-agnostic and the only iPhone-specific concern is whether the
//  callout overlaps the safe-area inset bottom; the margin-clamp covers
//  it. If iPhone-specific layout debt grows, defer iPhone coach-marks
//  to a follow-up PR rather than burning time here.
//
//  TAP BEHAVIOR:
//    - Dim layer catches all taps and dismisses. The underlying target
//      button does NOT receive the tap that dismisses the coach mark.
//    - This is intentional: the user reads the callout, taps to
//      dismiss, then taps the target with the coach mark gone. Two-
//      step but unambiguous.
//

import SwiftUI

// MARK: - Public API

/// Surface-scoped identifier for a coach-mark anchor. Each tutorial-era
/// callout reserves one case. Add new cases here when a new surface
/// adopts the coach-mark pattern.
enum CoachMarkID: Hashable {
    case getFeedback        // DrawingCanvasView trailing action panel
    case askEve             // FloatingFeedbackPanel Ask Eve row
    case galleryDrawings    // GalleryView tab strip
    case galleryPrompts     // GalleryView tab strip
    case galleryEvolution   // GalleryView tab strip
}

extension View {
    /// Marks this view as a coach-mark target. Pair with `.coachMark(...)`
    /// on an ancestor. The anchor records the view's screen-space bounds
    /// at layout time so the overlay can position its callout correctly.
    func coachMarkAnchor(_ id: CoachMarkID) -> some View {
        anchorPreference(
            key: CoachMarkAnchorKey.self,
            value: .bounds
        ) { anchor in [id: anchor] }
    }

    /// Renders a dim + highlight-ring + callout-bubble overlay anchored
    /// to a descendant marked with `.coachMarkAnchor(id)`. Tap anywhere
    /// to dismiss.
    ///
    /// - Parameters:
    ///   - isPresented: Binding to the parent's presentation state. The
    ///     overlay sets it back to false on dismiss.
    ///   - anchor: Which anchor on screen to point at. The anchor must
    ///     exist in the view tree below this modifier's host or no
    ///     overlay renders.
    ///   - title: Bold first line of the callout.
    ///   - message: Body copy below the title. Multi-line wraps naturally.
    ///     (Not named `body:` to avoid shadowing `View.body` /
    ///     `ViewModifier.body` in implementation structs.)
    ///   - onDismiss: Optional callback fired after the overlay hides.
    ///     Use for analytics, flag flips, or chaining a follow-up mark.
    func coachMark(
        isPresented: Binding<Bool>,
        anchor: CoachMarkID,
        title: String,
        message: String,
        onDismiss: @escaping () -> Void = {}
    ) -> some View {
        modifier(CoachMarkModifier(
            isPresented: isPresented,
            anchorID: anchor,
            title: title,
            message: message,
            onDismiss: onDismiss
        ))
    }
}

// MARK: - PreferenceKey

private struct CoachMarkAnchorKey: PreferenceKey {
    static var defaultValue: [CoachMarkID: Anchor<CGRect>] { [:] }

    static func reduce(
        value: inout [CoachMarkID: Anchor<CGRect>],
        nextValue: () -> [CoachMarkID: Anchor<CGRect>]
    ) {
        // Later anchors win — matters if two views accidentally register
        // the same CoachMarkID (shouldn't, but be permissive at the
        // reduce site so a bug elsewhere doesn't crash).
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - ViewModifier

private struct CoachMarkModifier: ViewModifier {
    @Binding var isPresented: Bool
    let anchorID: CoachMarkID
    let title: String
    let message: String
    let onDismiss: () -> Void

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(CoachMarkAnchorKey.self) { anchors in
                GeometryReader { proxy in
                    if isPresented, let anchor = anchors[anchorID] {
                        coachMarkOverlay(
                            targetRect: proxy[anchor],
                            screenSize: proxy.size
                        )
                    }
                }
                .ignoresSafeArea()
            }
    }

    @ViewBuilder
    private func coachMarkOverlay(targetRect: CGRect, screenSize: CGSize) -> some View {
        ZStack {
            // Dim layer — full-screen, catches all taps, dismisses.
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { dismiss() }

            // Highlight ring around target. allowsHitTesting(false) so
            // taps in this region still hit the dim below and dismiss.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 3)
                .frame(
                    width: targetRect.width + 12,
                    height: targetRect.height + 12
                )
                .position(x: targetRect.midX, y: targetRect.midY)
                .shadow(color: Color.accentColor.opacity(0.7), radius: 10)
                .allowsHitTesting(false)

            // Callout bubble. Same hit-testing rationale.
            CalloutBubble(title: title, message: message)
                .position(calloutCenter(targetRect: targetRect, screenSize: screenSize))
                .allowsHitTesting(false)
        }
        .transition(.opacity)
    }

    /// Decide where to put the callout: above or below the target,
    /// whichever side has more vertical room. Horizontal centered on
    /// target then clamped so the bubble doesn't run off screen.
    private func calloutCenter(targetRect: CGRect, screenSize: CGSize) -> CGPoint {
        let estimatedCalloutHeight: CGFloat = 140
        let estimatedCalloutWidth: CGFloat = min(360, screenSize.width - 48)
        let verticalGap: CGFloat = 20

        let spaceAbove = targetRect.minY
        let spaceBelow = screenSize.height - targetRect.maxY
        let placeBelow = spaceBelow >= spaceAbove

        let y: CGFloat = placeBelow
            ? targetRect.maxY + verticalGap + (estimatedCalloutHeight / 2)
            : targetRect.minY - verticalGap - (estimatedCalloutHeight / 2)

        let halfWidth = estimatedCalloutWidth / 2
        let minX = halfWidth + 24
        let maxX = screenSize.width - halfWidth - 24
        let x = max(minX, min(maxX, targetRect.midX))

        return CGPoint(x: x, y: y)
    }

    private func dismiss() {
        withAnimation(.easeOut(duration: 0.2)) {
            isPresented = false
        }
        onDismiss()
    }
}

// MARK: - Surface hook

/// Bundles the four modifiers a coach-mark-hosting surface needs:
/// `.coachMark(...)` + `.onAppear` armer + two `.onChange` re-arms
/// (one for the surface flag, one for hasSeenTutorialV1) that drive
/// the Replay Tutorial path. Wrapping these in a single ViewModifier
/// (a) keeps replay wiring uniform across surfaces, (b) breaks the
/// SwiftUI type-checker workload at the call site so heavy host views
/// like DrawingCanvasView don't blow past the inference time limit.
///
/// USAGE:
///   .modifier(CoachMarkSurfaceHook(
///     show: $showFoo,
///     title: "...", message: "...",
///     anchor: .foo,
///     surfaceFlag: hasSeenFooV1,
///     tutorialFlag: hasSeenTutorialV1,
///     onArm: armFooIfNeeded,
///     onDismissAction: { hasSeenFooV1 = true; ... }
///   ))
///
/// Pass the @AppStorage values as plain `Bool` — SwiftUI tracks them
/// for .onChange via the modifier's parameter list.
struct CoachMarkSurfaceHook: ViewModifier {
    @Binding var show: Bool
    let title: String
    let message: String
    let anchor: CoachMarkID
    let surfaceFlag: Bool
    let tutorialFlag: Bool
    let onArm: () -> Void
    let onDismissAction: () -> Void

    func body(content: Content) -> some View {
        content
            .coachMark(
                isPresented: $show,
                anchor: anchor,
                title: title,
                message: message,
                onDismiss: onDismissAction
            )
            .onAppear { onArm() }
            // Replay path 1: Settings → Replay Tutorial reset the surface
            // flag while the surface was already on screen.
            .onChange(of: surfaceFlag) { _, newValue in
                if !newValue { onArm() }
            }
            // Replay path 2: replay cards dismissed → hasSeenTutorialV1
            // flipped true. The armer's guard requires that, so re-fire
            // now that the replay cards are out of the way.
            .onChange(of: tutorialFlag) { _, newValue in
                if newValue { onArm() }
            }
    }
}

// MARK: - Callout bubble

private struct CalloutBubble: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 16, x: 0, y: 4)
    }
}

// MARK: - Preview

#Preview("Get Feedback coach mark") {
    CoachMarkPreviewHarness()
}

private struct CoachMarkPreviewHarness: View {
    @State private var showCoachMark = false

    var body: some View {
        VStack(spacing: 0) {
            // Some mock chrome at the top so the target isn't right at
            // the screen edge.
            Text("DrawEvolve")
                .font(.system(.title, design: .serif))
                .padding(.top, 60)

            Spacer()

            // The "canvas" placeholder.
            Rectangle()
                .fill(Color(uiColor: .secondarySystemBackground))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    Text("Canvas")
                        .foregroundStyle(.tertiary)
                )

            // Bottom action row — emulates DrawingCanvasView's trailing
            // panel where Get Feedback lives.
            HStack(spacing: 12) {
                Button(action: {}) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .padding(12)
                        .background(Color(uiColor: .systemBackground))
                        .clipShape(Circle())
                }

                Button(action: {}) {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Get Feedback")
                            .font(.headline)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .cornerRadius(10)
                }
                .coachMarkAnchor(.getFeedback)

                Spacer()

                Button("Show coach mark") {
                    withAnimation(.easeIn(duration: 0.2)) {
                        showCoachMark = true
                    }
                }
                .font(.footnote)
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemGroupedBackground))
        .coachMark(
            isPresented: $showCoachMark,
            anchor: .getFeedback,
            title: "Tap Get Feedback when you're ready.",
            message: "Your critique voice writes back — and remembers next time on the same drawing."
        )
    }
}
