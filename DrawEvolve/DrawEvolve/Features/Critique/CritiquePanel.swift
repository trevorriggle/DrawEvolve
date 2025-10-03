import SwiftUI

/// Displays AI critique results in two sections: Visual Analysis + Personalized Coaching
struct CritiquePanel: View {
    let critique: CritiqueResponse
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.paddingLarge) {
                    // Phase 1: Visual Analysis Section
                    VStack(alignment: .leading, spacing: AppTheme.paddingSmall) {
                        Label("Visual Analysis", systemImage: "eye")
                            .font(AppTheme.headlineFont)
                            .foregroundColor(AppTheme.primaryColor)

                        Text(critique.visualAnalysis)
                            .font(AppTheme.bodyFont)
                            .foregroundColor(AppTheme.textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(AppTheme.cornerRadius)

                    // Phase 2: Personalized Coaching Section
                    VStack(alignment: .leading, spacing: AppTheme.paddingSmall) {
                        Label("Personalized Coaching", systemImage: "sparkles")
                            .font(AppTheme.headlineFont)
                            .foregroundColor(AppTheme.primaryColor)

                        Text(critique.personalizedCoaching)
                            .font(AppTheme.bodyFont)
                            .foregroundColor(AppTheme.textColor)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(AppTheme.cornerRadius)

                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Your Critique")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Loading State View

/// Shows loading spinner while critique is being generated
struct CritiqueLoadingView: View {
    var body: some View {
        VStack(spacing: AppTheme.paddingLarge) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(AppTheme.primaryColor)

            Text("Analyzing your drawing...")
                .font(AppTheme.headlineFont)
                .foregroundColor(AppTheme.textColor)

            Text("This may take a few seconds")
                .font(AppTheme.captionFont)
                .foregroundColor(AppTheme.secondaryTextColor)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.backgroundColor)
    }
}

// MARK: - Error State View

/// Shows error message with retry option
struct CritiqueErrorView: View {
    let error: Error
    let onRetry: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: AppTheme.paddingLarge) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 60))
                    .foregroundColor(.orange)

                Text("Critique Failed")
                    .font(AppTheme.titleFont)

                Text(error.localizedDescription)
                    .font(AppTheme.bodyFont)
                    .foregroundColor(AppTheme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button(action: onRetry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                        .font(AppTheme.bodyFont)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primaryColor)

                Spacer()
            }
            .padding()
            .navigationTitle("Error")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
