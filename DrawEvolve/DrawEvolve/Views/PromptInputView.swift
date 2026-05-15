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

    /// Phase 4 — Subject Recommendations. When true, the recommendations
    /// sheet is presented over the questionnaire. Picking a recommendation
    /// pre-fills context.subject (and context.focus when the recommendation
    /// carries a focus area), then dismisses the sheet — the user stays
    /// on the questionnaire to confirm and proceed.
    @State private var showRecommendations = false

    var body: some View {
        Group {
            if DeviceIdiom.isPhone {
                phoneBody
            } else {
                padBody
            }
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView()
        }
        .sheet(isPresented: $showRecommendations) {
            // Phase 4 — when the user picks a recommendation, pre-fill
            // the subject (always) and the focus area (when present and
            // the focus field is currently empty — don't clobber what
            // the user has already typed in the optional focus slot).
            RecommendationsView(onPick: { rec in
                context.subject = rec.subject
                if context.focus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    context.focus = rec.focusArea
                }
                showRecommendations = false
            })
        }
    }

    /// iPhone layout — edge-to-edge questionnaire with bottom-pinned CTAs.
    /// SwiftUI's automatic keyboard avoidance handles inset adjustment when
    /// a TextField becomes first responder; .scrollDismissesKeyboard(.interactively)
    /// matches the iPad version's drag-to-dismiss-keyboard behavior.
    private var phoneBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(spacing: 12) {
                    Text("Let's Set Up Your Canvas")
                        .font(.title)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)

                    Text("Tell me what you're creating today")
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Name your drawing")
                        .font(.headline)
                    TextField("e.g., Mountain sunset, Portrait of Lily", text: $context.title)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Skill Level")
                        .font(.headline)
                    Picker("Skill Level", selection: $context.skillLevel) {
                        Text("Beginner").tag("Beginner")
                        Text("Intermediate").tag("Intermediate")
                        Text("Advanced").tag("Advanced")
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What are you drawing?")
                        .font(.headline)
                    // axis: .vertical lets the field grow from 1 line up
                    // to 3 lines for longer subjects (recommendation picks
                    // are often longer than the bar width — "still life
                    // with three glass objects of varying heights" etc.).
                    // Beyond 3 lines the field scrolls internally, which
                    // is fine — the bar visually caps and the user can
                    // still see what they typed.
                    TextField("e.g., a portrait, landscape, still life", text: $context.subject, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.sentences)
                        .textContentType(.none)
                        .autocorrectionDisabled()
                    Button {
                        showRecommendations = true
                    } label: {
                        Label("See suggestions", systemImage: "sparkles")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 2)
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
            .padding(.horizontal, 16)
            .padding(.top, 24)
            .padding(.bottom, 16)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 12) {
                Button {
                    if context.isComplete {
                        isPresented = false
                    }
                } label: {
                    Text("Start Drawing")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                }
                .background(context.isComplete ? Color.accentColor : Color.gray)
                .cornerRadius(12)
                .disabled(!context.isComplete)

                Button {
                    showGallery = true
                } label: {
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
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .background(Color(uiColor: .systemBackground))
    }

    /// iPad layout — original implementation, byte-for-byte unchanged.
    /// The outer `.fullScreenCover(isPresented: $showGallery)` lives on
    /// the `body`'s Group wrapper now (so iPhone gets it too), but the
    /// inner ZStack/dim-BG/centered-card structure here is identical to
    /// pre-iPhone-strategy main.
    private var padBody: some View {
        ZStack {
            // Dimmed background. Default Color hit-testing is enabled so
            // taps that miss the card get absorbed here (no action) —
            // the user can't draw on the canvas behind the modal or
            // sneak a tool change through the toolbar. With
            // `.allowsHitTesting(false)` the dim BG was visually present
            // but every touch passed straight through to the canvas
            // chrome underneath, which let the user draw / switch tools
            // / interact with the toolbar while the prompt was up.
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Card — sits in a VStack with a top Spacer so the keyboard
            // pushes it upward instead of hiding the active field
            VStack {
                Spacer(minLength: 0)

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
                            Text("Name your drawing")
                                .font(.headline)
                            TextField("e.g., Mountain sunset, Portrait of Lily", text: $context.title)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Skill Level")
                                .font(.headline)
                            Picker("Skill Level", selection: $context.skillLevel) {
                                Text("Beginner").tag("Beginner")
                                Text("Intermediate").tag("Intermediate")
                                Text("Advanced").tag("Advanced")
                            }
                            .pickerStyle(.segmented)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What are you drawing?")
                                .font(.headline)
                            // See phoneBody comment — axis: .vertical
                            // grows the field for longer subject strings
                            // (recommendation picks are often longer
                            // than the bar width).
                            TextField("e.g., a portrait, landscape, still life", text: $context.subject, axis: .vertical)
                                .lineLimit(1...3)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                            Button {
                                showRecommendations = true
                            } label: {
                                Label("See suggestions", systemImage: "sparkles")
                                    .font(.subheadline.weight(.medium))
                            }
                            .buttonStyle(.borderless)
                            .padding(.top, 2)
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

                Spacer(minLength: 0)
            }
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
