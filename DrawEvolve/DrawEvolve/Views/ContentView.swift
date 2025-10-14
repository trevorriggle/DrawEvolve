//
//  ContentView.swift
//  DrawEvolve
//
//  Main navigation and state management for the app.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("hasSeenBetaTransparency") private var hasSeenBetaTransparency = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasCompletedPrompt") private var hasCompletedPrompt = false
    @State private var showBetaTransparency = false
    @State private var showOnboarding = false
    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = false
    @State private var hasCheckedFirstLaunch = false

    var body: some View {
        // Main drawing canvas (no auth required)
        DrawingCanvasView(context: $drawingContext, existingDrawing: nil)
            .onAppear {
                performFirstLaunchCheck()
            }
            .overlay {
                // Beta transparency popup (shown first)
                if showBetaTransparency {
                    BetaTransparencyPopup(isPresented: $showBetaTransparency)
                }
            }
            .overlay {
                // First-time onboarding popup
                if showOnboarding {
                    OnboardingPopup(isPresented: $showOnboarding)
                }
            }
            .overlay {
                // Pre-drawing questionnaire popup
                if showPromptInput && !hasCompletedPrompt {
                    PromptInputView(
                        context: $drawingContext,
                        isPresented: $showPromptInput
                    )
                }
            }
            .onChange(of: showBetaTransparency) { _, newValue in
                if !newValue && !hasSeenOnboarding {
                    showOnboarding = true
                }
            }
            .onChange(of: showOnboarding) { _, newValue in
                if !newValue && !hasCompletedPrompt {
                    showPromptInput = true
                }
            }
            .onChange(of: showPromptInput) { _, newValue in
                if !newValue && drawingContext.isComplete {
                    hasCompletedPrompt = true
                }
            }
    }

    private func performFirstLaunchCheck() {
        guard !hasCheckedFirstLaunch else { return }
        hasCheckedFirstLaunch = true

        // Initialize anonymous user ID on first launch
        _ = AnonymousUserManager.shared.userID

        // DEBUG: Reset onboarding on every launch during development
        #if DEBUG
        UserDefaults.standard.set(false, forKey: "hasSeenBetaTransparency")
        UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(false, forKey: "hasCompletedPrompt")
        hasSeenBetaTransparency = false
        hasSeenOnboarding = false
        hasCompletedPrompt = false
        #endif

        // Show beta transparency first, then onboarding
        if !hasSeenBetaTransparency {
            showBetaTransparency = true
            hasSeenBetaTransparency = true
        } else if !hasSeenOnboarding {
            showOnboarding = true
            hasSeenOnboarding = true
        }
    }
}

#Preview {
    ContentView()
}
