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
    @State private var showGallery = false

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Card
            VStack(spacing: 0) {
                // Header
                VStack(spacing: 12) {
                    Text("Let's Set Up Your Canvas")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Tell me what you're creating today")
                        .font(.subheadline)
                        .foregroundColor(.primary)
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
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What style?")
                                .font(.headline)
                            TextField("e.g., realism, impressionism, anime", text: $context.style)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inspired by any artists?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., Van Gogh, Miyazaki (optional)", text: $context.artists)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Techniques you'll use?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., hatching, blending (optional)", text: $context.techniques)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Area you want feedback on?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., proportions, shading (optional)", text: $context.focus)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }
                    }
                    .padding(24)
                    .padding(.bottom, 100) // Extra space for keyboard + button
                }
                .scrollDismissesKeyboard(.interactively)

                // Sticky buttons at bottom
                VStack(spacing: 0) {
                    Divider()

                    VStack(spacing: 12) {
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
                        }
                        .background(context.isComplete ? Color.accentColor : Color.gray)
                        .cornerRadius(12)
                        .disabled(!context.isComplete)

                        Button(action: {
                            showGallery = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "photo.on.rectangle")
                                Text("View Gallery")
                            }
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                        }
                        .background(Color(uiColor: .secondarySystemBackground))
                        .cornerRadius(10)
                    }
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
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView()
        }
    }
}

#Preview {
    PromptInputView(
        context: .constant(DrawingContext()),
        isPresented: .constant(true)
    )
}
