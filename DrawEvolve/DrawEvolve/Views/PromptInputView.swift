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

    // Tracks which TextField currently owns the keyboard. Used to drive the
    // ScrollViewReader auto-scroll below — without it, focusing a field that
    // sits below the keyboard's incoming top edge leaves the field hidden.
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case subject, style, artists, techniques, focus
    }

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .allowsHitTesting(false)

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

                // Form. Wrapped in ScrollViewReader + tagged with .id() so we
                // can programmatically scroll the focused field into view when
                // the keyboard appears. Without this, tapping the lower fields
                // (techniques, focus) puts the field directly under the
                // keyboard with no way to see what's being typed.
                ScrollViewReader { scrollProxy in
                    ScrollView {
                    VStack(spacing: 20) {
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
                            TextField("e.g., a portrait, landscape, still life", text: $context.subject)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .subject)
                        }
                        .id(Field.subject)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("What style?")
                                .font(.headline)
                            TextField("e.g., realism, impressionism, anime", text: $context.style)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .style)
                        }
                        .id(Field.style)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Inspired by any artists?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., Van Gogh, Miyazaki (optional)", text: $context.artists)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .artists)
                        }
                        .id(Field.artists)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Techniques you'll use?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., hatching, blending (optional)", text: $context.techniques)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .techniques)
                        }
                        .id(Field.techniques)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Area you want feedback on?")
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            TextField("e.g., proportions, shading (optional)", text: $context.focus)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.sentences)
                                .textContentType(.none)
                                .autocorrectionDisabled()
                                .focused($focusedField, equals: .focus)
                        }
                        .id(Field.focus)
                    }
                    .padding(24)
                    .padding(.bottom, 100) // Extra space for keyboard + button
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: focusedField) { _, newField in
                        guard let newField else { return }
                        // Anchor .top because the outer container ignores
                        // the keyboard safe area (so the card doesn't
                        // compress) — that means the ScrollView won't get
                        // an automatic bottom inset for the keyboard, so
                        // .center could land the field underneath it.
                        // Pinning the focused field to the top of the
                        // visible scroll area keeps it well above the
                        // keyboard regardless of card height.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy.scrollTo(newField, anchor: .top)
                            }
                        }
                    }
                }

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
        // Stop the iOS keyboard from compressing the card layout. With the
        // default behavior, the centering Spacers + maxHeight 700 frame
        // would shrink to whatever's left after the keyboard's safe area
        // inset, squashing the form fields off-screen. Ignoring the keyboard
        // safe area keeps the card at full size; the ScrollViewReader above
        // takes responsibility for scrolling the focused field into view.
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
