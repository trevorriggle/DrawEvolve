//
//  ContentView.swift
//  DrawEvolve
//
//  Routes between the auth gate and the signed-in onboarding/canvas flow.
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
    @AppStorage("hasSeenBetaTransparency") private var hasSeenBetaTransparency = false
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @AppStorage("hasCompletedPrompt") private var hasCompletedPrompt = false
    @State private var showBetaTransparency = false
    @State private var showOnboarding = false
    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = false
    @State private var hasCheckedFirstLaunch = false

    var body: some View {
        DrawingCanvasView(context: $drawingContext, existingDrawing: nil)
            .onAppear {
                performFirstLaunchCheck()
            }
            .overlay {
                if showBetaTransparency {
                    BetaTransparencyPopup(isPresented: $showBetaTransparency)
                } else {
                    Color.clear.allowsHitTesting(false)
                }
            }
            .overlay {
                if showOnboarding {
                    OnboardingPopup(isPresented: $showOnboarding)
                } else {
                    Color.clear.allowsHitTesting(false)
                }
            }
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

        // DEBUG: Reset onboarding on every launch during development
        #if DEBUG
        UserDefaults.standard.set(false, forKey: "hasSeenBetaTransparency")
        UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
        UserDefaults.standard.set(false, forKey: "hasCompletedPrompt")
        hasSeenBetaTransparency = false
        hasSeenOnboarding = false
        hasCompletedPrompt = false
        #endif

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
        .environmentObject(AuthManager.shared)
}
