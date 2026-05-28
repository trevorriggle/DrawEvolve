//
//  ContentView.swift
//  DrawEvolve
//
//  Routes between the auth gate and the signed-in flow. Hosts the
//  fresh-install tutorial (auto-presents on LaunchHomeView for new
//  users) and the PromptInputView cover on the canvas route.
//
//  Auto-present design: the new tutorial intentionally REVIVES auto-
//  presentation that #68/#70 killed for the prior beta/onboarding
//  cascade. The product distinction is that the prior cascade auto-
//  presented disclaimers/feature-trivia (correctly killed); this auto-
//  presents genuine onboarding that solves a real confusion moment
//  (new user lands on LaunchHomeView, sees two buttons, doesn't know
//  which to pick). See drawevolve_tutorial_proposal_v3.md decision
//  block "Auto-present" for the full rationale.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var authManager: AuthManager

    @ViewBuilder
    var body: some View {
        #if DEBUG
        if authManager.isDebugBypassed {
            SignedInRoot()
        } else {
            authStateRouter
        }
        #else
        authStateRouter
        #endif
    }

    @ViewBuilder
    private var authStateRouter: some View {
        switch authManager.state {
        case .loading:
            SplashView()
        case .signedOut:
            AuthGateView()
        case .signedIn:
            SignedInRoot()
        }
    }
}

private struct SplashView: View {
    var body: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

private struct SignedInRoot: View {
    // hasSeenOnboarding is read once by the existing-user migration block
    // in handleSignedInAppear — detects TestFlight users who already saw
    // the deleted OnboardingPopup so they skip the new tutorial. Keep the
    // declaration even though it's read-only here; the AppStorage value
    // still exists in UserDefaults for affected users.
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasCompletedPrompt") private var hasCompletedPrompt = false

    // Tutorial v1 flags. hasSeenTutorialV1 gates the 3-card carousel;
    // the other four gate the surface-specific banner + coach-marks
    // (PromptInputView banner, Get Feedback button, Ask Eve row,
    // Gallery 3-tab tour). Version-suffixed so we can re-arm the whole
    // cohort on a material content change.
    @AppStorage("hasSeenTutorialV1") private var hasSeenTutorialV1 = false
    @AppStorage("hasSeenPromptInputBannerV1") private var hasSeenPromptInputBannerV1 = false
    @AppStorage("hasSeenGetFeedbackCoachMarkV1") private var hasSeenGetFeedbackCoachMarkV1 = false
    @AppStorage("hasSeenAskEveCoachMarkV1") private var hasSeenAskEveCoachMarkV1 = false
    @AppStorage("hasSeenGalleryTourV1") private var hasSeenGalleryTourV1 = false

    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = false

    @State private var showTutorial = false
    @State private var tutorialMode: TutorialPresentationMode = .firstRun

    /// Session route between LaunchHomeView and DrawingCanvasView.
    /// `nil` = launch home; setting it advances into the canvas. Reset
    /// to nil on every fresh app launch so the user always lands on
    /// the welcome screen first.
    @State private var route: SignedInRoute? = nil

    enum SignedInRoute {
        case canvas(openGallery: Bool)
    }

    var body: some View {
        Group {
            switch route {
            case .none:
                LaunchHomeView(
                    onNewCanvas: {
                        // ALWAYS fire the prompt input for "Set up a new
                        // canvas". Reset both the completion flag and
                        // the context so the prompt sheet starts blank.
                        drawingContext = DrawingContext()
                        hasCompletedPrompt = false
                        showPromptInput = true
                        route = .canvas(openGallery: false)
                    },
                    onOpenGallery: {
                        // Skip the prompt for gallery-entry — user is
                        // browsing, not starting a fresh drawing.
                        route = .canvas(openGallery: true)
                    }
                )
            case .canvas(let openGallery):
                DrawingCanvasView(
                    context: $drawingContext,
                    existingDrawing: nil,
                    openGalleryOnAppear: openGallery
                )
                .modifier(PromptInputPresentation(
                    showPromptInput: $showPromptInput,
                    hasCompletedPrompt: hasCompletedPrompt,
                    drawingContext: $drawingContext
                ))
                .onChange(of: showPromptInput) { _, newValue in
                    if !newValue && drawingContext.isComplete {
                        hasCompletedPrompt = true
                    }
                }
            }
        }
        .modifier(TutorialPresentation(
            showTutorial: $showTutorial,
            mode: tutorialMode,
            onComplete: handleTutorialComplete,
            onSkip: handleTutorialSkip
        ))
        .onAppear { handleSignedInAppear() }
        .onChange(of: hasSeenTutorialV1) { _, newValue in
            // Settings → Replay Tutorial resets this flag to false. We
            // pick that up here, switch to replay mode, and present.
            // Replay overlays whatever screen the user is on (per v3
            // Q4 decision — do not navigate back to LaunchHome).
            if !newValue && !showTutorial {
                tutorialMode = .replay
                showTutorial = true
            }
        }
    }

    // MARK: - Tutorial lifecycle

    private func handleSignedInAppear() {
        // One-shot migration: TestFlight users who already saw the
        // deleted OnboardingPopup don't get re-onboarded by the new
        // tutorial. They can replay from Settings if they want. Safe
        // to remove this block once all pre-tutorial-V1 installs have
        // either upgraded or churned (~2026-Q4).
        if hasSeenOnboarding && !hasSeenTutorialV1 {
            hasSeenTutorialV1 = true
        }

        // Auto-fire on LaunchHomeView for first-launch users. Gated on
        // route == .none so re-entering the signed-in flow (e.g. after
        // sign-out + sign-in) doesn't re-present mid-canvas.
        if !hasSeenTutorialV1, case .none = route {
            tutorialMode = .firstRun
            showTutorial = true
        }
    }

    private func handleTutorialComplete() {
        // First-run Card 3 "Let's draw" — routes into the canvas + fires
        // PromptInputView. Mirrors the existing onNewCanvas closure on
        // LaunchHomeView so the entry-into-canvas behavior is uniform.
        hasSeenTutorialV1 = true
        if tutorialMode == .firstRun {
            drawingContext = DrawingContext()
            hasCompletedPrompt = false
            showPromptInput = true
            route = .canvas(openGallery: false)
        }
        // Replay mode: just dismiss; user stays where they were.
    }

    private func handleTutorialSkip() {
        // Skip kills everything — set all five tutorial flags so the
        // surface-specific coach-marks don't ambush a user who opted
        // out of the upfront cards.
        hasSeenTutorialV1 = true
        hasSeenPromptInputBannerV1 = true
        hasSeenGetFeedbackCoachMarkV1 = true
        hasSeenAskEveCoachMarkV1 = true
        hasSeenGalleryTourV1 = true
    }
}

// MARK: - PromptInputPresentation

/// PromptInputView cover modifier for the canvas route. iPhone uses
/// .fullScreenCover; iPad uses .overlay with a dimmed background so
/// the centered-card padBody renders correctly. Same idiom split as
/// the prior PopupPresentation modifier — the difference is that this
/// one only handles the one surface; the dead beta/onboarding bindings
/// from the killed cascade are gone.
private struct PromptInputPresentation: ViewModifier {
    @Binding var showPromptInput: Bool
    let hasCompletedPrompt: Bool
    @Binding var drawingContext: DrawingContext

    func body(content: Content) -> some View {
        if DeviceIdiom.isPhone {
            content
                .fullScreenCover(isPresented: showPromptInputBinding) {
                    PromptInputView(
                        context: $drawingContext,
                        isPresented: $showPromptInput
                    )
                }
        } else {
            content
                .overlay {
                    if showPromptInput && !hasCompletedPrompt {
                        PromptInputView(
                            context: $drawingContext,
                            isPresented: $showPromptInput
                        )
                    } else {
                        Color.clear.allowsHitTesting(false)
                    }
                }
        }
    }

    /// Match the iPad branch's `showPromptInput && !hasCompletedPrompt`
    /// gate. Bound through a synthesized Binding so the cover dismisses
    /// when either flag flips.
    private var showPromptInputBinding: Binding<Bool> {
        Binding(
            get: { showPromptInput && !hasCompletedPrompt },
            set: { newValue in showPromptInput = newValue }
        )
    }
}

// MARK: - TutorialPresentation

/// Hosts the 3-card tutorial overlay. iPhone uses .fullScreenCover;
/// iPad uses .overlay (matching the existing popup pattern so the
/// dimmed-BG + centered-card chrome inside TutorialCardsView renders
/// correctly). Sits at the SignedInRoot level so it overlays both
/// LaunchHomeView (first-run) and DrawingCanvasView (replay) without
/// route-specific gating.
private struct TutorialPresentation: ViewModifier {
    @Binding var showTutorial: Bool
    let mode: TutorialPresentationMode
    let onComplete: () -> Void
    let onSkip: () -> Void

    func body(content: Content) -> some View {
        if DeviceIdiom.isPhone {
            content.fullScreenCover(isPresented: $showTutorial) {
                TutorialCardsView(
                    isPresented: $showTutorial,
                    presentationMode: mode,
                    onComplete: onComplete,
                    onSkip: onSkip
                )
            }
        } else {
            content.overlay {
                if showTutorial {
                    TutorialCardsView(
                        isPresented: $showTutorial,
                        presentationMode: mode,
                        onComplete: onComplete,
                        onSkip: onSkip
                    )
                }
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthManager.shared)
}
