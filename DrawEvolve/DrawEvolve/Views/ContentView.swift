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
            } else if showPromptInput && !hasCompletedPrompt {
                // Questionnaire before starting drawing
                PromptInputView(
                    context: $drawingContext,
                    isPresented: $showPromptInput
                )
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

        #if DEBUG
        // Reset on every launch for testing
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
