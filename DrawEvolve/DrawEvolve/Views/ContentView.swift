//
//  ContentView.swift
//  DrawEvolve
//
//  Main navigation and state management for the app.
//

import SwiftUI

struct ContentView: View {
    @AppStorage("isAuthenticated") private var isAuthenticated = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasCompletedPrompt") private var hasCompletedPrompt = false
    @State private var showOnboarding = false
    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = false
    @State private var hasCheckedFirstLaunch = false
    @State private var showCanvas = false

    var body: some View {
        Group {
            if !isAuthenticated {
                // Landing page with auth options
                LandingView(isAuthenticated: $isAuthenticated)
            } else {
                // Drawing canvas (main screen after auth)
                DrawingCanvasView(context: $drawingContext)
            }
        }
        .onAppear {
            performFirstLaunchCheck()
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
        .onChange(of: isAuthenticated) { _, newValue in
            if newValue {
                // User just logged in/signed up
                if !hasSeenOnboarding {
                    showOnboarding = true
                    hasSeenOnboarding = true
                } else if !hasCompletedPrompt {
                    showPromptInput = true
                }
            }
        }
        .onChange(of: showOnboarding) { _, newValue in
            if !newValue && isAuthenticated && !hasCompletedPrompt {
                showPromptInput = true
            }
        }
        .onChange(of: showPromptInput) { _, newValue in
            if !newValue && isAuthenticated && drawingContext.isComplete {
                hasCompletedPrompt = true
            }
        }
    }

    private func performFirstLaunchCheck() {
        guard !hasCheckedFirstLaunch else { return }
        hasCheckedFirstLaunch = true

        // DEBUG: Reset auth/onboarding on every launch during development
        // IMPORTANT: Keep this ENABLED during development to test full user journey including pre-draw prompts
        // Only DISABLE for TestFlight/production builds
        #if DEBUG
        UserDefaults.standard.set(false, forKey: "isAuthenticated")
        UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(false, forKey: "hasCompletedPrompt")
        isAuthenticated = false
        hasSeenOnboarding = false
        hasCompletedPrompt = false
        #endif
    }
}

#Preview {
    ContentView()
}
