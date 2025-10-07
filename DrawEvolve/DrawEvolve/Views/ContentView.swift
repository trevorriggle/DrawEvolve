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

    var body: some View {
        let _ = print("ContentView: body re-evaluated")
        let _ = print("  isAuthenticated: \(isAuthenticated), hasSeenOnboarding: \(hasSeenOnboarding), hasCompletedPrompt: \(hasCompletedPrompt), showPromptInput: \(showPromptInput)")
        Group {
            if !isAuthenticated {
                // Landing page with auth options
                LandingView(isAuthenticated: $isAuthenticated)
                    .onAppear {
                        print("ContentView: Showing landing page")
                        print("  isAuthenticated: \(isAuthenticated)")
                        print("  hasSeenOnboarding: \(hasSeenOnboarding)")
                        print("  hasCompletedPrompt: \(hasCompletedPrompt)")
                        print("  showPromptInput: \(showPromptInput)")
                    }
            } else if showPromptInput && !hasCompletedPrompt {
                // Questionnaire
                PromptInputView(
                    context: $drawingContext,
                    isPresented: $showPromptInput
                )
                .onAppear {
                    print("ContentView: Showing questionnaire")
                }
            } else {
                // Drawing canvas
                DrawingCanvasView(context: $drawingContext)
                    .onAppear {
                        print("ContentView: Showing drawing canvas")
                    }
            }
        }
        .overlay {
            // First-time onboarding popup
            if showOnboarding {
                OnboardingPopup(isPresented: $showOnboarding)
            }
        }
        .onChange(of: isAuthenticated) { _, newValue in
            print("ContentView: isAuthenticated changed to \(newValue)")
            if newValue {
                // User just logged in/signed up
                if !hasSeenOnboarding {
                    print("  -> First time user, showing onboarding")
                    showOnboarding = true
                    hasSeenOnboarding = true
                } else if !hasCompletedPrompt {
                    print("  -> Returning user without prompt, showing prompt")
                    showPromptInput = true
                } else {
                    print("  -> Returning user with completed prompt, showing canvas")
                }
            }
        }
        .onChange(of: showOnboarding) { _, newValue in
            print("ContentView: showOnboarding changed to \(newValue)")
            if !newValue && isAuthenticated && !hasCompletedPrompt {
                print("  -> Onboarding dismissed, showing prompt input")
                showPromptInput = true
            }
        }
        .onChange(of: showPromptInput) { _, newValue in
            if !newValue && isAuthenticated && drawingContext.isComplete {
                // Prompt dismissed with complete context - mark as complete
                hasCompletedPrompt = true
                print("ContentView: Prompt completed, moving to canvas")
            }
        }
    }
}

#Preview {
    ContentView()
}
