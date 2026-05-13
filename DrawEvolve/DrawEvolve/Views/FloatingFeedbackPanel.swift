//
//  FloatingFeedbackPanel.swift
//  DrawEvolve
//
//  Draggable, collapsible feedback panel that floats over the canvas.
//

import SwiftUI

struct FloatingFeedbackPanel: View {
    let feedback: String?
    let critiqueHistory: [CritiqueEntry]
    @Binding var isPresented: Bool

    /// Optional callback that fires when the user taps "Ask Eve" in the
    /// bottom row of the expanded panel. Parent supplies a closure that
    /// presents EveSheetHost scoped to the currently-displayed critique.
    /// Pass nil to suppress the Ask Eve row entirely (used by any caller
    /// that doesn't want to surface Eve from this panel — currently none,
    /// but the nil-tolerance keeps the signature additive).
    /// Carries the critique sequence the user is currently viewing so
    /// the parent knows which one to anchor the conversation on.
    var onAskEve: ((_ critiqueSequence: Int?) -> Void)? = nil

    @State private var isExpanded = true
    @State private var position: CGPoint = .zero
    @State private var dragOffset: CGSize = .zero
    @State private var showHistoryMenu = false
    @State private var selectedHistoryIndex = 0
    @State private var screenSize: CGSize = .zero

    private let collapsedSize: CGSize = CGSize(width: 60, height: 60)
    private let expandedSize: CGSize = CGSize(width: 656, height: 625)
    private let historyMenuWidth: CGFloat = 200

    /// The actual expanded panel size for the current screen. The fixed
    /// `expandedSize` (656×625) is the *upper bound* — on smaller screens or
    /// in split-screen / iPhone fallback we shrink it so the panel stays
    /// fully on-screen with room reserved on the left for the history menu
    /// when the user opens it.
    private var actualExpandedSize: CGSize {
        guard screenSize.width > 0, screenSize.height > 0 else {
            return expandedSize
        }
        let outerPadding: CGFloat = 40
        let menuRoom = historyMenuWidth + 8  // reserve so history menu fits to the left
        let widthCap = max(320, screenSize.width - outerPadding - menuRoom)
        let heightCap = max(320, screenSize.height - outerPadding)
        return CGSize(
            width: min(expandedSize.width, widthCap),
            height: min(expandedSize.height, heightCap)
        )
    }

    var body: some View {
        // Container shape forks per idiom. iPad keeps the floating-card +
        // collapsed-pill model byte-preserved in `padBody`. iPhone uses
        // a half-sheet with `.presentationDetents([.medium, .large])` —
        // the .sheet itself is attached at the parent (DrawingCanvasView's
        // phoneBody), not here, since `.sheet` is a presentation modifier
        // and lives on the presenting view, not the presented one.
        //
        // The critique scroll view (timestamp + markdown) is shared
        // between both branches via `critiqueContent`. That extraction is
        // a deliberate, contained deviation from the locked "wholesale-
        // quoted padBody, no refactoring" rule — pad/phoneBody must
        // share critique rendering to maintain functional parity and
        // prevent silent platform drift in the markdown / textSelection /
        // history-jumping logic. Same class of justified carve-out as
        // Phase 2's modifier lift.
        Group {
            if DeviceIdiom.isPhone {
                phoneBody
            } else {
                padBody
            }
        }
    }

    // MARK: - iPhone body (half-sheet content)
    //
    // Header (history Menu + title + dismiss X) over the shared
    // critiqueContent. No drag gesture, no position state, no expand /
    // collapse — the half-sheet handles dismissal via drag-down + tap-
    // outside; the X button is redundant explicit dismissal for
    // accessibility. Reset-position and collapse-to-pill buttons are
    // dropped (no position to reset, no pill state in a sheet).
    //
    // History uses a SwiftUI Menu containing a Picker — the standard
    // iOS pattern for "pick one of these recent items" inside a sheet.
    // Items show timestamps only (the iPad list shows a 50-char preview
    // of each critique; that level of richness doesn't fit Menu items
    // cleanly and is dropped on iPhone — the user gets the full
    // critique on selection anyway).

    private var phoneBody: some View {
        VStack(spacing: 0) {
            phoneHeader
            Divider()
            critiqueContent
            askEveBar
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            // Pin to the most recent entry when the panel appears.
            // Default @State of 0 mapped to critiqueHistory[0] = the
            // OLDEST critique, so opening the panel always showed
            // stale feedback. iPad's path has the same fix inside
            // padBody's GeometryReader; phoneBody was missing it,
            // hence the iPhone-only bug.
            selectedHistoryIndex = max(0, critiqueHistory.count - 1)
        }
        .onChange(of: critiqueHistory.count) { _, newCount in
            // When a new critique lands while the panel is already
            // open, jump to it. Otherwise the user keeps seeing the
            // previously-selected entry and has to fish in the
            // history menu for the new one.
            selectedHistoryIndex = max(0, newCount - 1)
        }
    }

    private var phoneHeader: some View {
        HStack {
            // History Menu (left). Disabled when there's nothing to pick.
            Menu {
                Picker("History", selection: $selectedHistoryIndex) {
                    ForEach(Array(critiqueHistory.enumerated().reversed()), id: \.element.id) { index, entry in
                        Text(formatTimestamp(entry.timestamp)).tag(index)
                    }
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .foregroundColor(critiqueHistory.isEmpty ? .secondary : .accentColor)
                    .font(.title3)
            }
            .disabled(critiqueHistory.isEmpty)

            Spacer()

            Text("AI Feedback")
                .font(.headline)

            Spacer()

            // Explicit dismiss. Redundant with sheet drag-down / tap-
            // outside but standard chrome on iOS sheets.
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
        }
        .padding()
    }

    // MARK: - Shared critique content
    //
    // Timestamp header + FormattedMarkdownView, used by both padBody and
    // phoneBody. Extracted from the original inline ScrollView block so
    // the markdown rendering, text selection, and "X of Y" indicator
    // stay in one place across both idioms. See the body comment above
    // for why this extraction is a justified, contained deviation from
    // the wholesale-quote rule.

    // MARK: - Ask Eve row
    //
    // Optional bottom row that hands off to EveSheetHost. Renders only
    // when:
    //   - the parent supplied an `onAskEve` callback (Eve is plumbed)
    //   - there is a critique to talk about (feedback != nil)
    //   - the user has navigated to a row that exists in critique_history
    //     (so we have a sequence number to anchor the conversation on)
    //
    // Visual: a small bar with the EVE compact icon + a one-line label,
    // sitting on a subtle secondary background to differentiate from
    // the critique scroll. Tap surface is the whole row, not just the
    // icon, so it reads as a single affordance.

    @ViewBuilder
    private var askEveBar: some View {
        if let onAskEve, feedback != nil {
            let sequenceForCallback: Int? = {
                guard !critiqueHistory.isEmpty,
                      selectedHistoryIndex < critiqueHistory.count else {
                    return nil
                }
                return critiqueHistory[selectedHistoryIndex].sequenceNumber
            }()
            Button(action: { onAskEve(sequenceForCallback) }) {
                HStack(spacing: 12) {
                    EveIconButton(action: { onAskEve(sequenceForCallback) }, size: .compact)
                        // The inner button handles the tap. The outer
                        // Button below makes the whole row tappable for
                        // discoverability; disable hit-testing on the
                        // icon button so it doesn't double-fire.
                        .allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Ask Eve about this critique")
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Text("Follow-up questions, what to try next")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(uiColor: .secondarySystemBackground))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var critiqueContent: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Show timestamp of current feedback
                if !critiqueHistory.isEmpty && selectedHistoryIndex < critiqueHistory.count {
                    HStack {
                        Image(systemName: "clock")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Text(formatTimestamp(critiqueHistory[selectedHistoryIndex].timestamp))
                            .font(.caption)
                            .foregroundColor(.primary)
                        Spacer()
                        Text("\(selectedHistoryIndex + 1) of \(critiqueHistory.count)")
                            .font(.caption)
                            .foregroundColor(.primary)
                    }
                    .padding(.horizontal, 4)
                }

                FormattedMarkdownView(text: displayedFeedback)
                    .textSelection(.enabled)
            }
            .padding()
        }
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - iPad body (floating-card / collapsed-pill, byte-preserved)
    //
    // Wholesale-quoted from pre-Phase-4 main. The only structural change
    // is the inline critique ScrollView block (formerly here) is now a
    // reference to `critiqueContent` — see body comment for the
    // justification. All other geometry, drag, position, expand /
    // collapse, history-slide-out, and modifier chain are unchanged.

    private var padBody: some View {
        GeometryReader { geometry in
            ZStack {
                if isExpanded, feedback != nil {
                    // Expanded panel
                    VStack(spacing: 0) {
                        // Header with drag handle and controls
                        HStack {
                            Button(action: {
                                withAnimation(.spring(response: 0.25)) {
                                    let willShow = !showHistoryMenu
                                    showHistoryMenu = willShow
                                    if willShow {
                                        // Make sure the history menu has room
                                        // to the left of the panel. Without this,
                                        // opening the menu while the panel sits
                                        // near the screen's left edge slid the
                                        // menu off-screen.
                                        let panelLeftEdge = position.x - actualExpandedSize.width / 2
                                        let needed = historyMenuWidth + 8
                                        if panelLeftEdge < needed {
                                            let newX = needed + actualExpandedSize.width / 2
                                            let maxX = screenSize.width - actualExpandedSize.width / 2
                                            position = CGPoint(
                                                x: min(newX, maxX),
                                                y: position.y
                                            )
                                        }
                                    }
                                }
                            }) {
                                Image(systemName: "line.3.horizontal")
                                    .foregroundColor(showHistoryMenu ? .accentColor : .secondary)
                                    .font(.title3)
                            }
                            .disabled(critiqueHistory.isEmpty)

                            Spacer()

                            Text("AI Feedback")
                                .font(.headline)

                            Spacer()

                            HStack(spacing: 12) {
                                // Reset position button
                                Button(action: { resetPosition() }) {
                                    Image(systemName: "arrow.counterclockwise.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .help("Reset panel position")

                                Button(action: {
                                    withAnimation(.spring(response: 0.3)) {
                                        // Adjust position so top-left stays in same place
                                        let offsetX = (actualExpandedSize.width - collapsedSize.width) / 2
                                        let offsetY = (actualExpandedSize.height - collapsedSize.height) / 2
                                        var newX = position.x - offsetX
                                        var newY = position.y - offsetY

                                        // Apply strict boundaries for collapsed state
                                        let minX = collapsedSize.width / 2
                                        let maxX = screenSize.width - collapsedSize.width / 2
                                        let minY = collapsedSize.height / 2
                                        let maxY = screenSize.height - collapsedSize.height / 2

                                        newX = min(max(newX, minX), maxX)
                                        newY = min(max(newY, minY), maxY)

                                        position = CGPoint(x: newX, y: newY)
                                        isExpanded = false
                                    }
                                }) {
                                    Image(systemName: "chevron.down.circle.fill")
                                        .foregroundColor(.secondary)
                                }

                                Button(action: { isPresented = false }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .padding()
                        .background(Color(uiColor: .systemBackground))

                        Divider()

                        // Feedback content (shared with iPhone phoneBody —
                        // see `critiqueContent` for the markdown view +
                        // timestamp header).
                        critiqueContent
                        askEveBar
                    }
                    .frame(width: actualExpandedSize.width, height: actualExpandedSize.height)
                    .background(Color(uiColor: .systemBackground))
                    .cornerRadius(16)
                    .shadow(radius: 10)
                    .overlay(alignment: .leading) {
                        // History menu overlay - appears to the left
                        if showHistoryMenu && !critiqueHistory.isEmpty {
                            VStack(spacing: 0) {
                                // History menu header
                                HStack {
                                    Text("History")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(uiColor: .secondarySystemBackground))

                                Divider()

                                // History list (most recent first)
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(Array(critiqueHistory.enumerated().reversed()), id: \.element.id) { index, entry in
                                            Button(action: {
                                                selectedHistoryIndex = index
                                                withAnimation(.spring(response: 0.25)) {
                                                    showHistoryMenu = false
                                                }
                                            }) {
                                                HStack(spacing: 8) {
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(formatTimestamp(entry.timestamp))
                                                            .font(.subheadline)
                                                            .fontWeight(.medium)
                                                            .foregroundColor(.primary)

                                                        Text({
                                                            let body = CritiqueSummary.parse(entry.feedback).body
                                                            return body.prefix(50) + (body.count > 50 ? "..." : "")
                                                        }())
                                                            .font(.caption)
                                                            .foregroundColor(.primary)
                                                            .lineLimit(2)
                                                    }
                                                    Spacer()

                                                    if index == selectedHistoryIndex {
                                                        Image(systemName: "checkmark")
                                                            .foregroundColor(.accentColor)
                                                            .font(.caption)
                                                    }
                                                }
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 10)
                                                .background(index == selectedHistoryIndex ? Color.accentColor.opacity(0.1) : Color.clear)
                                            }

                                            // Show divider except after the last item
                                            if index > 0 {
                                                Divider()
                                                    .padding(.leading, 12)
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(width: historyMenuWidth, height: actualExpandedSize.height)
                            .background(Color(uiColor: .systemBackground))
                            .cornerRadius(12)
                            .shadow(radius: 8)
                            .offset(x: -historyMenuWidth - 8)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                        }
                    }
                } else {
                    // Collapsed icon
                    ZStack {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: collapsedSize.width, height: collapsedSize.height)
                            .shadow(radius: 5)

                        Image(systemName: "pencil.tip.crop.circle")
                            .font(.system(size: 30))
                            .foregroundColor(.white)
                    }
                    .onTapGesture {
                        // Tap to expand (doesn't interfere with drag)
                        withAnimation(.spring(response: 0.3)) {
                            // Adjust position so top-left stays in same place
                            let offsetX = (actualExpandedSize.width - collapsedSize.width) / 2
                            let offsetY = (actualExpandedSize.height - collapsedSize.height) / 2
                            var newX = position.x + offsetX
                            var newY = position.y + offsetY

                            // Apply strict boundaries for expanded state
                            let minX = actualExpandedSize.width / 2
                            let maxX = screenSize.width - actualExpandedSize.width / 2
                            let minY = actualExpandedSize.height / 2
                            let maxY = screenSize.height - actualExpandedSize.height / 2

                            newX = min(max(newX, minX), maxX)
                            newY = min(max(newY, minY), maxY)

                            position = CGPoint(x: newX, y: newY)
                            isExpanded = true
                        }
                    }
                }
            }
            .position(
                x: position.x + dragOffset.width,
                y: position.y + dragOffset.height
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Constrain drag offset in real-time to prevent going off-screen
                        let currentWidth = isExpanded ? actualExpandedSize.width : collapsedSize.width
                        let currentHeight = isExpanded ? actualExpandedSize.height : collapsedSize.height

                        // Calculate what the new position would be with this drag
                        let potentialX = position.x + value.translation.width
                        let potentialY = position.y + value.translation.height

                        // Strict boundaries - keep entire panel on screen
                        // If history menu is showing, account for it on the left side
                        let leftExtension = showHistoryMenu ? (historyMenuWidth + 8) : 0
                        let minX = currentWidth / 2 + leftExtension
                        let maxX = geometry.size.width - currentWidth / 2
                        let minY = currentHeight / 2
                        let maxY = geometry.size.height - currentHeight / 2

                        // Constrain the drag offset
                        let constrainedX = min(max(potentialX, minX), maxX)
                        let constrainedY = min(max(potentialY, minY), maxY)

                        dragOffset = CGSize(
                            width: constrainedX - position.x,
                            height: constrainedY - position.y
                        )
                    }
                    .onEnded { value in
                        // Apply drag to position and reset drag offset
                        let currentWidth = isExpanded ? actualExpandedSize.width : collapsedSize.width
                        let currentHeight = isExpanded ? actualExpandedSize.height : collapsedSize.height

                        // Calculate new position
                        var newX = position.x + dragOffset.width
                        var newY = position.y + dragOffset.height

                        // Strict boundaries - keep entire panel on screen
                        // If history menu is showing, account for it on the left side
                        let leftExtension = showHistoryMenu ? (historyMenuWidth + 8) : 0
                        let minX = currentWidth / 2 + leftExtension
                        let maxX = geometry.size.width - currentWidth / 2
                        let minY = currentHeight / 2
                        let maxY = geometry.size.height - currentHeight / 2

                        newX = min(max(newX, minX), maxX)
                        newY = min(max(newY, minY), maxY)

                        withAnimation(.spring(response: 0.3)) {
                            position = CGPoint(x: newX, y: newY)
                            dragOffset = .zero
                        }
                    }
            )
            .onAppear {
                // Store screen size for reset function
                screenSize = geometry.size

                // Default to the MOST RECENT entry rather than the oldest
                // (selectedHistoryIndex = 0 was the previous default, which
                // mapped to critiqueHistory[0] — the first/oldest critique
                // — making the panel open on stale feedback every time).
                selectedHistoryIndex = max(0, critiqueHistory.count - 1)

                // Position in top-left corner initially, ensuring it stays on screen
                let currentWidth = isExpanded ? actualExpandedSize.width : collapsedSize.width
                let currentHeight = isExpanded ? actualExpandedSize.height : collapsedSize.height

                // Calculate safe position from screen edges (top-left)
                let padding: CGFloat = 20

                // Position using absolute coordinates (top-left corner)
                var x = currentWidth / 2 + padding
                var y = currentHeight / 2 + padding

                // Apply strict boundaries
                let minX = currentWidth / 2
                let maxX = geometry.size.width - currentWidth / 2
                let minY = currentHeight / 2
                let maxY = geometry.size.height - currentHeight / 2

                x = min(max(x, minX), maxX)
                y = min(max(y, minY), maxY)

                position = CGPoint(x: x, y: y)
                dragOffset = .zero
            }
            .onChange(of: critiqueHistory.count) { _, newCount in
                // When new feedback arrives while the panel is already open,
                // jump to it. Otherwise the user keeps seeing whichever
                // historical entry was selected and has to manually pick the
                // new one — easy to miss.
                selectedHistoryIndex = max(0, newCount - 1)
            }
        }
    }

    private var displayedFeedback: String {
        // Strip the trailing summary block before rendering. The block
        // is HTML-comment delimited and would otherwise render as
        // literal text in FormattedMarkdownView (our renderer doesn't
        // strip comments). The summary is only meant to surface in
        // the gallery-preview "AI Feedback Summary" panel.
        let raw: String
        if !critiqueHistory.isEmpty && selectedHistoryIndex < critiqueHistory.count {
            raw = critiqueHistory[selectedHistoryIndex].feedback
        } else {
            raw = feedback ?? ""
        }
        return CritiqueSummary.parse(raw).body
    }

    private func formatTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())

        // Also show absolute time for clarity
        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .short
        timeFormatter.timeStyle = .short

        return "\(relative) • \(timeFormatter.string(from: date))"
    }

    private func resetPosition() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            // Reset to default top-left position
            let currentWidth = isExpanded ? actualExpandedSize.width : collapsedSize.width
            let currentHeight = isExpanded ? actualExpandedSize.height : collapsedSize.height

            let padding: CGFloat = 20

            var x = currentWidth / 2 + padding
            var y = currentHeight / 2 + padding

            // Apply strict boundaries
            let minX = currentWidth / 2
            let maxX = screenSize.width - currentWidth / 2
            let minY = currentHeight / 2
            let maxY = screenSize.height - currentHeight / 2

            x = min(max(x, minX), maxX)
            y = min(max(y, minY), maxY)

            position = CGPoint(x: x, y: y)
            dragOffset = .zero
        }
    }
}

#Preview {
    ZStack {
        Color.gray.ignoresSafeArea()

        FloatingFeedbackPanel(
            feedback: """
            Great work on your portrait! Your proportions are well-balanced.

            **Strengths:**
            - Good facial structure
            - Nice shading depth

            **Areas to improve:**
            - Soften shadow transitions
            - Adjust ear positioning
            """,
            critiqueHistory: [
                CritiqueEntry(feedback: "First critique", timestamp: Date().addingTimeInterval(-86400)),
                CritiqueEntry(feedback: "Second critique", timestamp: Date())
            ],
            isPresented: .constant(true)
        )
    }
}
