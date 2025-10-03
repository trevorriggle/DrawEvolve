import SwiftUI

/// Context capture form - collects user's drawing goals (subject, style, focus)
/// Presented as sheet on first launch and via "Context" button
struct ContextCaptureView: View {
    @ObservedObject var contextModel: ContextModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("Tell us about your drawing goals so we can provide personalized feedback")
                        .font(AppTheme.bodyFont)
                        .foregroundColor(AppTheme.secondaryTextColor)
                }

                Section(header: Text("Subject")) {
                    TextField("What do you want to draw?", text: $contextModel.subject)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("Examples: human figures, landscapes, portraits, animals")
                        .font(AppTheme.captionFont)
                        .foregroundColor(AppTheme.secondaryTextColor)
                }

                Section(header: Text("Style")) {
                    Picker("Drawing style", selection: $contextModel.style) {
                        ForEach(DrawingStyle.allCases) { style in
                            Text(style.rawValue).tag(style)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section(header: Text("Focus Area")) {
                    TextField("What do you want to improve?", text: $contextModel.focus)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Text("Examples: proportions, shading, line work, composition")
                        .font(AppTheme.captionFont)
                        .foregroundColor(AppTheme.secondaryTextColor)
                }

                Section {
                    Button(action: {
                        contextModel.save()
                        dismiss()
                    }) {
                        HStack {
                            Spacer()
                            Text("Save & Continue")
                                .font(AppTheme.bodyFont)
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!contextModel.isValid)
                    .foregroundColor(contextModel.isValid ? AppTheme.primaryColor : .gray)
                }
            }
            .navigationTitle("Welcome to DrawEvolve")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Only show cancel if onboarding already completed (editing context)
                    if contextModel.onboardingCompleted {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
