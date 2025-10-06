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
    @State private var showOnboarding = false
    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = false

    var body: some View {
        Group {
            if !isAuthenticated {
                // Landing page with auth options
                LandingView(isAuthenticated: $isAuthenticated)
                    .onAppear {
                        print("ContentView: Showing landing page")
                    }
            } else if showPromptInput {
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
            if newValue {
                // User just logged in/signed up
                if !hasSeenOnboarding {
                    showOnboarding = true
                    hasSeenOnboarding = true
                } else {
                    // Returning user - go straight to prompt
                    showPromptInput = true
                }
            }
        }
        .onChange(of: showOnboarding) { _, newValue in
            if !newValue && isAuthenticated {
                // Onboarding dismissed - show prompt input
                showPromptInput = true
            }
        }
    }
}

#Preview {
    ContentView()
}
