//
//  TutorialCardsView.swift
//  DrawEvolve
//
//  First-launch tutorial — 3-card carousel auto-presented on
//  LaunchHomeView for new users (hasSeenTutorialV1 == false). Replaces
//  the deleted-by-this-PR OnboardingPopup as the first-run experience.
//
//  Cards lock the Model B framing per cloudflare-worker/lib/eve-persona.js:
//    Card 1 — what the app does (two AIs, one writes, one chats)
//    Card 2 — relationship (critique = analysis, Eve = conversation)
//    Card 3 — iterative coaching (critique voice + Eve = two memory systems)
//
//  AUTO-PRESENTATION: this is the first auto-present onboarding flow
//  since #68/#70 killed the prior cascade. The product distinction is
//  that the prior cascade auto-presented disclaimer/trivia content;
//  this auto-presents genuine onboarding that solves a real confusion
//  moment (LaunchHomeView "Set up a new canvas" vs "Go to gallery"
//  without context).
//
//  PRESENTATION MODES:
//    - .firstRun: Card 3 CTA reads "Let's draw →" and routes into
//      PromptInputView via the caller's onComplete closure.
//    - .replay: Card 3 CTA reads "Done" and just dismisses. Replay can
//      fire from Settings → Replay Tutorial OR canvas chrome (?) info
//      button (the latter repointed in Phase 4 per v3 §4d).
//
//  SKIP: present on every card, top-right, same position and styling.
//  One tap exits any card and marks all five tutorial flags seen.
//
//  ANALYTICS: tutorial_card_seen fires per-card on appear,
//  tutorial_completed on Let's-draw / Done CTA, tutorial_skipped with
//  last_card_seen payload on Skip.
//

import SwiftUI

enum TutorialPresentationMode {
    case firstRun
    case replay
}

struct TutorialCardsView: View {
    @Binding var isPresented: Bool
    let presentationMode: TutorialPresentationMode

    /// Called when the user taps the final CTA on Card 3:
    /// - firstRun mode: caller routes into PromptInputView (this view
    ///   doesn't know about routes; the host wires it).
    /// - replay mode: caller can be a no-op; isPresented = false alone
    ///   dismisses the cover/overlay.
    /// Skip does NOT fire this. Skip only fires onSkip.
    let onComplete: () -> Void

    /// Called when the user taps Skip from any card. Caller marks all
    /// five tutorial flags seen so contextual coach-marks don't ambush
    /// a user who explicitly opted out.
    let onSkip: () -> Void

    @State private var currentIndex: Int = 0

    private let totalCards = 3

    var body: some View {
        if DeviceIdiom.isPhone {
            phoneBody
        } else {
            padBody
        }
    }

    // MARK: - iPhone layout

    /// Edge-to-edge fullScreenCover. Skip at top-right, content in middle,
    /// nav row pinned to bottom via safeAreaInset.
    private var phoneBody: some View {
        VStack(spacing: 0) {
            chromeTopBar
                .padding(.top, 12)
                .padding(.horizontal, 20)

            Spacer(minLength: 0)

            cardContent(for: currentIndex)
                .padding(.horizontal, 24)
                .transition(.opacity)

            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom) {
            navBar
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(.regularMaterial)
        }
        .background(Color(uiColor: .systemBackground))
        .onAppear {
            fireCardSeenAnalytics(card: currentIndex + 1)
        }
    }

    // MARK: - iPad layout

    /// Dimmed background + centered 600x700 card. Matches the existing
    /// padBody pattern in BetaTransparencyPopup.
    private var padBody: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { /* swallow; dismiss only via Skip / final CTA */ }

            VStack(spacing: 0) {
                chromeTopBar
                    .padding(.top, 18)
                    .padding(.horizontal, 24)

                Spacer(minLength: 16)

                cardContent(for: currentIndex)
                    .padding(.horizontal, 32)
                    .transition(.opacity)

                Spacer(minLength: 16)

                navBar
                    .padding(.horizontal, 32)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: 600, maxHeight: 700)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(radius: 20)
            )
            .padding(40)
        }
        .onAppear {
            fireCardSeenAnalytics(card: currentIndex + 1)
        }
    }

    // MARK: - Top bar (Skip + page indicator)

    private var chromeTopBar: some View {
        HStack {
            pageIndicator
            Spacer()
            Button(action: handleSkip) {
                Text("Skip")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var pageIndicator: some View {
        HStack(spacing: 8) {
            ForEach(0..<totalCards, id: \.self) { i in
                Circle()
                    .fill(i == currentIndex ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Bottom nav row

    /// Card 1: [        Next → ]
    /// Card 2: [← Back  Next → ]
    /// Card 3: [← Back  Let's draw → / Done]
    private var navBar: some View {
        HStack(spacing: 12) {
            if currentIndex > 0 {
                Button(action: goBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(10)
                }
            }

            Spacer()

            Button(action: handlePrimaryCTA) {
                HStack(spacing: 6) {
                    Text(primaryCTALabel)
                    if currentIndex < totalCards - 1 {
                        Image(systemName: "chevron.right")
                    } else if presentationMode == .firstRun {
                        Image(systemName: "chevron.right")
                    }
                }
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
                .background(Color.accentColor)
                .cornerRadius(12)
            }
        }
    }

    private var primaryCTALabel: String {
        if currentIndex < totalCards - 1 {
            return "Next"
        }
        return presentationMode == .firstRun ? "Let's draw" : "Done"
    }

    // MARK: - Card content

    @ViewBuilder
    private func cardContent(for index: Int) -> some View {
        switch index {
        case 0: card1
        case 1: card2
        case 2: card3
        default: EmptyView()
        }
    }

    /// Card 1 — DrawEvolve has two AIs. (Per v3 proposal §2.)
    private var card1: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("DrawEvolveLogo")
                .resizable()
                .scaledToFit()
                .frame(height: 80)
                .frame(maxWidth: .infinity, alignment: .center)

            Text("DrawEvolve has two AIs: one writes critiques, one chats.")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Both are honest. Both remember. They're separate features that work together.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("You draw. When you're ready, tap **Get Feedback** — one of four **critique voices** (Studio Mentor, The Crit, Fundamentals Coach, Renaissance Master) writes you a critique on what's on the canvas. Each voice has a different personality.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("Separately, **Eve** is a coach you can chat with. She can read your critiques and help you think through what to try next — but she doesn't write critiques herself.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Card 2 — Critiques vs Eve relationship. (Per v3 proposal §2.)
    private var card2: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Critiques are the analysis. Eve is the conversation.")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("A **critique** is a one-shot analysis written by your chosen critique voice. You get one each time you tap **Get Feedback**. Critiques stay attached to the drawing — you can revisit them any time.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("**Eve** is a separate ongoing conversation. After any critique, tap **Ask Eve** to dig in: she'll have read the critique and can talk it through, suggest exercises, or just answer questions. You can also open Eve from the canvas any time for general coaching that isn't about a specific critique.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Card 3 — Iterative coaching, two memory systems. (Per v3 proposal §2.)
    private var card3: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Iterative coaching, two ways.")
                .font(.title2.weight(.bold))
                .fixedSize(horizontal: false, vertical: true)

            Text("Your **critique voice remembers** prior critiques on the same drawing. Each time you tap Get Feedback on a drawing you've been working on, it picks up where the last one left off — not a fresh, generic take.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("**Eve remembers your conversations.** Within a chat she follows the thread; when you Ask Eve about a critique, she's read everything that voice has said about this drawing.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            Text("This is what makes DrawEvolve a coaching loop instead of a one-shot tool.")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation actions

    private func goBack() {
        guard currentIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            currentIndex -= 1
        }
        fireCardSeenAnalytics(card: currentIndex + 1)
    }

    private func handlePrimaryCTA() {
        if currentIndex < totalCards - 1 {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentIndex += 1
            }
            fireCardSeenAnalytics(card: currentIndex + 1)
        } else {
            // Final card. Fire completion analytics + dismiss.
            EventLogService.shared.log(event: "tutorial_completed")
            isPresented = false
            onComplete()
        }
    }

    private func handleSkip() {
        EventLogService.shared.log(
            event: "tutorial_skipped",
            payload: ["last_card_seen": currentIndex + 1]
        )
        isPresented = false
        onSkip()
    }

    // MARK: - Analytics

    private func fireCardSeenAnalytics(card: Int) {
        EventLogService.shared.log(
            event: "tutorial_card_seen",
            payload: ["card": card]
        )
    }
}

// MARK: - Preview

#Preview("First-run") {
    TutorialCardsView(
        isPresented: .constant(true),
        presentationMode: .firstRun,
        onComplete: {},
        onSkip: {}
    )
}

#Preview("Replay") {
    TutorialCardsView(
        isPresented: .constant(true),
        presentationMode: .replay,
        onComplete: {},
        onSkip: {}
    )
}
