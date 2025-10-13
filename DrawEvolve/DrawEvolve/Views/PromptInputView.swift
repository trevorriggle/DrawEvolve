//
//  PromptInputView.swift
//  DrawEvolve
//
//  The pre-drawing questionnaire that gathers context from the user.
//

import SwiftUI

struct PromptInputView: View {
    @Binding var context: DrawingContext
    @Binding var isPresented: Bool

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Card
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Text("Let's Set Up Your Canvas")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Tell me what you're creating today")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 32)
                .padding(.horizontal, 24)

                // Form
                ScrollView {
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What are you drawing?")
                                .font(.headline)
                            TextField("e.g., a portrait, landscape, still life", text: $context.subject)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What style?")
                                .font(.headline)
                            TextField("e.g., realism, impressionism, anime", text: $context.style)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inspired by any artists?")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("e.g., Van Gogh, Miyazaki (optional)", text: $context.artists)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Techniques you'll use?")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("e.g., hatching, blending (optional)", text: $context.techniques)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Area you want feedback on?")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            TextField("e.g., proportions, shading (optional)", text: $context.focus)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 100) // Extra space for keyboard + button
                }
                .scrollDismissesKeyboard(.interactively)

                // Sticky Start Drawing button
                VStack(spacing: 0) {
                    Divider()

                    Button(action: {
                        if context.isComplete {
                            isPresented = false
                        }
                    }) {
                        Text("Start Drawing")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(context.isComplete ? Color.accentColor : Color.gray)
                            .cornerRadius(12)
                    }
                    .disabled(!context.isComplete)
                    .padding()
                    .background(.ultraThinMaterial)
                }
            }
            .frame(maxWidth: 600, maxHeight: 700)
            .background(Color(uiColor: .systemBackground))
            .cornerRadius(20)
            .shadow(radius: 20)
            .padding(40)
        }
    }
}

#Preview {
    PromptInputView(
        context: .constant(DrawingContext()),
        isPresented: .constant(true)
    )
}
