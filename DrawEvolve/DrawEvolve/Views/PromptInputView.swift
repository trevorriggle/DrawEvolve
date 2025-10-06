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
        NavigationView {
            Form {
                Section {
                    Text("Welcome to DrawEvolve")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Let's understand what you're creating today.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } header: {
                    EmptyView()
                }

                Section("What are you drawing today?") {
                    TextField("e.g., a portrait, landscape, still life", text: $context.subject)
                        .textInputAutocapitalization(.sentences)
                }

                Section("What style are you going for?") {
                    TextField("e.g., realism, impressionism, anime", text: $context.style)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Are you inspired by any artists?") {
                    TextField("e.g., Van Gogh, Miyazaki (optional)", text: $context.artists)
                        .textInputAutocapitalization(.words)
                }

                Section("What techniques are you planning on implementing?") {
                    TextField("e.g., hatching, blending, stippling (optional)", text: $context.techniques)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Is there a specific area you want feedback on?") {
                    TextField("e.g., proportions, shading, composition (optional)", text: $context.focus)
                        .textInputAutocapitalization(.sentences)
                }

                Section("Lastly, is there any additional context you'd like me to have?") {
                    TextEditor(text: $context.additionalContext)
                        .frame(minHeight: 80)
                        .textInputAutocapitalization(.sentences)
                }

                Section {
                    Button(action: {
                        if context.isComplete {
                            isPresented = false
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text("Start Drawing")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(!context.isComplete)
                }
            }
            .navigationTitle("Setup Your Session")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

#Preview {
    PromptInputView(
        context: .constant(DrawingContext()),
        isPresented: .constant(true)
    )
}
