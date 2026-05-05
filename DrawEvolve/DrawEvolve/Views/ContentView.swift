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
            .modifier(PopupPresentation(
                showBetaTransparency: $showBetaTransparency,
                showOnboarding: $showOnboarding,
                showPromptInput: $showPromptInput,
                hasCompletedPrompt: hasCompletedPrompt,
                drawingContext: $drawingContext
            ))
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

/// Onboarding popup presentation strategy.
///
/// On iPad: three layered `.overlay { ... }` modifiers, byte-for-byte
/// identical to the pre-iPhone-strategy main code path. The dim-BG +
/// centered-card pattern that BetaTransparencyPopup / OnboardingPopup /
/// PromptInputView render in their `padBody` only makes sense behind a
/// translucent overlay, so the wrapper-and-content pair must stay on
/// iPad — it's the locked iPad design.
///
/// On iPhone: three layered `.fullScreenCover(isPresented:)` modifiers
/// instead, which platform-level absorb all touches and let the popups
/// render their `phoneBody` edge-to-edge with no dim BG and no maxWidth
/// cap. The cascade `onChange` handlers stay on the parent SignedInRoot
/// and fire identically across both branches.
private struct PopupPresentation: ViewModifier {
    @Binding var showBetaTransparency: Bool
    @Binding var showOnboarding: Bool
    @Binding var showPromptInput: Bool
    let hasCompletedPrompt: Bool
    @Binding var drawingContext: DrawingContext

    func body(content: Content) -> some View {
        if DeviceIdiom.isPhone {
            content
                .fullScreenCover(isPresented: $showBetaTransparency) {
                    BetaTransparencyPopup(isPresented: $showBetaTransparency)
                }
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingPopup(isPresented: $showOnboarding)
                }
                .fullScreenCover(isPresented: showPromptInputBinding) {
                    PromptInputView(
                        context: $drawingContext,
                        isPresented: $showPromptInput
                    )
                }
        } else {
            content
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
        }
    }

    /// Match the iPad branch's `showPromptInput && !hasCompletedPrompt`
    /// gate. Bound through a synthesized Binding so the cover dismisses
    /// when either flag flips, matching the existing flow exactly.
    private var showPromptInputBinding: Binding<Bool> {
        Binding(
            get: { showPromptInput && !hasCompletedPrompt },
            set: { newValue in showPromptInput = newValue }
        )
    }
}

#Preview {
    ContentView()
        .environmentObject(AuthManager.shared)
}
