import SwiftUI

@main
struct DrawEvolveApp: App {
    @StateObject private var contextModel = ContextModel()

    var body: some Scene {
        WindowGroup {
            ContentView(contextModel: contextModel)
                .onAppear {
                    // Log app configuration on startup
                    AppConfig.printConfiguration()
                }
        }
    }
}

struct ContentView: View {
    @ObservedObject var contextModel: ContextModel
    @State private var showOnboarding = false

    var body: some View {
        CanvasScreen()
            .sheet(isPresented: $showOnboarding) {
                ContextCaptureView(contextModel: contextModel)
                    .interactiveDismissDisabled(true)  // Must complete onboarding
            }
            .onAppear {
                // Show onboarding on first launch
                if !contextModel.onboardingCompleted {
                    showOnboarding = true
                }
            }
    }
}
