import SwiftUI
import PencilKit

/// Main drawing screen with PencilKit canvas and action buttons
struct CanvasScreen: View {
    @StateObject private var canvasViewModel = CanvasViewModel()
    @StateObject private var contextModel = ContextModel()
    @State private var showContextSheet = false
    @State private var critiqueState: CritiqueState = .idle

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Canvas area - takes most of the screen
                PKCanvasViewRepresentable(canvasView: $canvasViewModel.canvasView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)

                // Bottom action bar
                HStack(spacing: 16) {
                    // Clear button
                    Button(action: {
                        NotificationCenter.default.post(name: .clearCanvas, object: nil)
                    }) {
                        Label("Clear", systemImage: "trash")
                            .font(AppTheme.bodyFont)
                            .foregroundColor(AppTheme.destructiveColor)
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    // I'm Finished button - triggers critique flow
                    Button(action: {
                        requestCritique()
                    }) {
                        Label("I'm Finished", systemImage: "checkmark.circle.fill")
                            .font(AppTheme.bodyFont)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.primaryColor)
                    .disabled(critiqueState.isLoading)
                }
                .padding()
                .background(AppTheme.backgroundColor)
            }
            .navigationTitle("Draw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showContextSheet = true
                    }) {
                        Label("Context", systemImage: "person.crop.circle")
                    }
                }
            }
            .sheet(isPresented: $showContextSheet) {
                ContextCaptureView(contextModel: contextModel)
            }
            .sheet(isPresented: Binding(
                get: { critiqueState.isLoading },
                set: { _ in }
            )) {
                CritiqueLoadingView()
            }
            .sheet(isPresented: Binding(
                get: { critiqueState.hasResult },
                set: { if !$0 { critiqueState = .idle } }
            )) {
                if case .success(let critique) = critiqueState {
                    CritiquePanel(critique: critique)
                }
            }
            .sheet(isPresented: Binding(
                get: { critiqueState.hasError },
                set: { if !$0 { critiqueState = .idle } }
            )) {
                if case .error(let error) = critiqueState {
                    CritiqueErrorView(error: error) {
                        requestCritique()
                    }
                }
            }
        }
    }

    // MARK: - Critique Flow

    /// Request critique: render PNG → call API → show result
    private func requestCritique() {
        Task { @MainActor in
            critiqueState = .loading

            do {
                // 1. Render canvas to image
                guard let image = canvasViewModel.canvasView.renderToImage() else {
                    throw CritiqueError.invalidImage
                }

                Logger.log("Rendered canvas to image: \(image.size)", log: .ui)

                // 2. Get user context
                let context = contextModel.userContext

                // 3. Submit to critique API
                let response = try await CritiqueClient.shared.requestCritique(
                    image: image,
                    context: context
                )

                Logger.log("Critique received successfully", log: .network)

                // 4. Show result
                critiqueState = .success(response)

            } catch {
                Logger.error("Critique failed: \(error)", log: .network)
                critiqueState = .error(error)
            }
        }
    }
}

// MARK: - ViewModel

/// Manages canvas state
class CanvasViewModel: ObservableObject {
    @Published var canvasView = PKCanvasView()
}

// MARK: - Critique State

/// Represents the current state of the critique request
enum CritiqueState {
    case idle
    case loading
    case success(CritiqueResponse)
    case error(Error)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    var hasResult: Bool {
        if case .success = self { return true }
        return false
    }

    var hasError: Bool {
        if case .error = self { return true }
        return false
    }
}
