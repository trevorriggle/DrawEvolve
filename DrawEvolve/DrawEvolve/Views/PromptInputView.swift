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

    /// First-open inline banner gate. Lands the "why we ask all this"
    /// framing — honest input = sharper critique. Not a coach-mark; the
    /// banner scrolls with the form and disappears with animation on dismiss.
    ///
    /// `hasSeenPromptInputBannerV1` persists across sessions and is now
    /// marked seen the moment the banner first appears (body .onAppear) —
    /// NOT only when "Got it" is tapped. The old "Got it"-only mark left the
    /// flag false for anyone who proceeded through the form without tapping
    /// the small button, so the banner re-fired on every new-drawing setup.
    /// In-session visibility is driven by `bannerVisible` so persisting the
    /// flag on appear doesn't make the card flash-and-vanish. Fresh install =
    /// UserDefaults key absent → shows once; delete-and-reinstall clears it
    /// and re-shows; Settings → Replay Tutorial re-arms it. All intended.
    @AppStorage("hasSeenPromptInputBannerV1") private var hasSeenPromptInputBannerV1 = false

    /// In-session visibility for the first-open banner. Seeded once from
    /// `hasSeenPromptInputBannerV1` in body .onAppear; set false by "Got it".
    @State private var bannerVisible = false

    var body: some View {
        Group {
            if DeviceIdiom.isPhone {
                phoneBody
            } else {
                padBody
            }
        }
        .onAppear {
            // Mark the first-open banner seen the moment it would first show,
            // so it fires exactly once on fresh install regardless of how the
            // form is dismissed (not only when "Got it" is tapped).
            if !hasSeenPromptInputBannerV1 {
                bannerVisible = true
                hasSeenPromptInputBannerV1 = true
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

                bannerSection

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

                canvasSizeField

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

    /// iPad layout. The outer ZStack provides the dim tap-blocker that both
    /// portrait and landscape branches inherit; the GeometryReader picks the
    /// layout by available height, not orientation, so Split View / Stage
    /// Manager / iPad mini landscape (anywhere the centered 700pt card would
    /// be squeezed) all fall into the edge-to-edge variant. The threshold
    /// (1050pt) is "700pt card + a bit of breathing room for outer padding."
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

            GeometryReader { geo in
                if geo.size.height < 1050 {
                    padLandscapeBody
                } else {
                    padPortraitBody
                }
            }
        }
    }

    /// iPad portrait (tall enough — geo.size.height >= 1050). Centered modal
    /// card, byte-identical to the pre-split implementation aside from the
    /// 7 form sections being extracted into `promptFormFields` for view
    /// identity continuity across the height-threshold swap.
    private var padPortraitBody: some View {
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
                VStack(alignment: .leading, spacing: 20) {
                    bannerSection
                    promptFormFieldsSingleColumn
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
        // GeometryReader places its child at top-leading with the child's
        // intrinsic size — without this frame the outer VStack would render
        // at its 600pt-card-width intrinsic size, leaving the card flush
        // against the leading edge after .padding(40). The frame forces the
        // VStack to fill the GeometryReader's proposed size; the inner
        // Spacers then center the card vertically and VStack's default
        // alignment centers it horizontally.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    /// iPad short-height variant (geo.size.height < 1050 — landscape, Split
    /// View, Stage Manager, iPad mini landscape, or any pad layout where the
    /// keyboard squeezes the 700pt centered card). Mirrors phoneBody's
    /// edge-to-edge structure (ScrollView + safeAreaInset CTAs) but caps the
    /// content at 720pt wide and centers it, and uses 24pt horizontal padding
    /// (vs 16pt on phone).
    private var padLandscapeBody: some View {
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

                bannerSection

                promptFormFieldsGrid
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
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
            .padding(.horizontal, 24)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .background(.ultraThinMaterial)
        }
        .background(Color(uiColor: .systemBackground))
    }

    // MARK: - Per-field subviews
    //
    // Each form section is a property on PromptInputView so it can read
    // $context and $showRecommendations via `self` without threaded bindings.
    // Both layout wrappers (`promptFormFieldsSingleColumn` and
    // `promptFormFieldsGrid`) embed these directly, which keeps view
    // identity — and therefore @FocusState, scroll position, and
    // in-progress text edits — stable across the padBody height-threshold
    // swap (e.g. rotating with the keyboard up).

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name your drawing")
                .font(.headline)
            TextField("e.g., Mountain sunset, Portrait of Lily", text: $context.title)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.words)
                .textContentType(.none)
                .autocorrectionDisabled()
        }
    }

    private var skillLevelField: some View {
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
        // padBody mounts the canvas-size chips right below skill level,
        // mirroring phoneBody's placement.
    }

    // MARK: - Canvas size (canvas-sizes feature)
    //
    // Preset chips writing to @AppStorage; DrawingCanvasView observes the
    // same key and applies the size to the renderer for NEW drawings only
    // (guarded on zero strokes — see applyNewCanvasSizePreset there).
    // Deliberately NOT a DrawingContext field: context is Codable and its
    // fields are rendered into the critique system prompt by the Worker
    // (lib/prompt.js renderContextBlock) — canvas dimensions don't belong
    // in an AI prompt.

    @AppStorage("newCanvasSizePreset") private var canvasSizePresetRaw =
        CanvasSizePreset.deviceDefault.rawValue

    var canvasSizeField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Canvas")
                .font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CanvasSizePreset.allCases) { preset in
                        let selected = preset.rawValue == canvasSizePresetRaw
                        Button {
                            canvasSizePresetRaw = preset.rawValue
                        } label: {
                            VStack(spacing: 2) {
                                Text(preset.label)
                                    .font(.subheadline.weight(.medium))
                                Text(preset.detail)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(selected ? Color.accentColor.opacity(0.15)
                                                   : Color(uiColor: .secondarySystemBackground))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var subjectField: some View {
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
    }

    private var styleField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What style?")
                .font(.headline)
            TextField("e.g., realism, impressionism, anime", text: $context.style)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.sentences)
                .textContentType(.none)
                .autocorrectionDisabled()
        }
    }

    private var artistsField: some View {
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
    }

    private var techniquesField: some View {
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
    }

    private var focusField: some View {
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

    // MARK: - Form layout wrappers

    /// Single-column stack used by padPortraitBody. The portrait modal is
    /// capped at maxWidth: 600 — not enough horizontal room for two columns
    /// to be readable.
    private var promptFormFieldsSingleColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            nameField
            skillLevelField
            canvasSizeField
            subjectField
            styleField
            artistsField
            techniquesField
            focusField
        }
    }

    // MARK: - First-open banner

    /// Inline banner shown on first PromptInputView open. Lands the
    /// "why we ask all this" framing per v3 proposal. Card-style, lives
    /// at the top of the form (above the Name field), dismissible via
    /// the "Got it" button. Flag persists across sessions so the banner
    /// doesn't re-fire on every drawing setup.
    ///
    /// Per Phase A audit §G1: this banner deliberately does NOT claim
    /// the user is picking a critique voice in this form — voice
    /// selection lives in Gallery → My Prompts. The Gallery 3-tab tour
    /// (separate coach-mark) handles the voice-location pointing.
    @ViewBuilder
    private var bannerSection: some View {
        if bannerVisible {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.bubble.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Why we ask all this")
                        .font(.headline)
                    Spacer(minLength: 0)
                    Button {
                        dismissBanner()
                    } label: {
                        Text("Got it")
                            .font(.subheadline.weight(.semibold))
                    }
                }

                Text("Honest input makes your critique sharper. The more accurately you describe what you're trying to do, the more your critique voice has to work with.")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Your answers here shape every critique and can't be edited afterward, so be as accurate as you can. (You can always rename the drawing later.)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private func dismissBanner() {
        withAnimation(.easeOut(duration: 0.2)) {
            bannerVisible = false
        }
        EventLogService.shared.log(event: "prompt_input_banner_dismissed")
    }

    /// Two-column grid used by padLandscapeBody. Short-height pad layouts
    /// (landscape with keyboard up has ~436pt of vertical space) feel
    /// cramped single-column — only 1–2 fields visible at a time. The grid
    /// pairs the six main fields and lets focusField span the full content
    /// width as a final row below, reading as "main fields + one closing
    /// question" rather than as an empty grid cell.
    private var promptFormFieldsGrid: some View {
        VStack(alignment: .leading, spacing: 20) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16),
                    GridItem(.flexible(), spacing: 16)
                ],
                alignment: .leading,
                spacing: 20
            ) {
                nameField;      skillLevelField
                subjectField;   styleField
                artistsField;   techniquesField
            }
            canvasSizeField
            focusField
        }
    }
}

#Preview {
    PromptInputView(
        context: .constant(DrawingContext()),
        isPresented: .constant(true)
    )
}

// MARK: - Canvas size presets (canvas-sizes feature)

/// Creation-time canvas dimensions. Long side is 2048 for the aspect
/// presets (matches the iPhone-class square; iPad Pro's 4096 high-res
/// path stays available via Device default). `nil` size = legacy
/// device-derived square (diagonal-fit pow2) — the pre-feature behavior
/// and the default, so users who never touch the picker see zero change.
enum CanvasSizePreset: String, CaseIterable, Identifiable {
    case deviceDefault = "default"
    case square = "square"
    case portrait34 = "portrait34"
    case landscape43 = "landscape43"
    case story916 = "story916"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .deviceDefault: return "Device"
        case .square:        return "Square"
        case .portrait34:    return "Portrait"
        case .landscape43:   return "Landscape"
        case .story916:      return "Story"
        }
    }

    var detail: String {
        switch self {
        case .deviceDefault: return "best fit"
        case .square:        return "1:1"
        case .portrait34:    return "3:4"
        case .landscape43:   return "4:3"
        case .story916:      return "9:16"
        }
    }

    var size: CGSize? {
        switch self {
        case .deviceDefault: return nil
        case .square:        return CGSize(width: 2048, height: 2048)
        case .portrait34:    return CGSize(width: 1536, height: 2048)
        case .landscape43:   return CGSize(width: 2048, height: 1536)
        case .story916:      return CGSize(width: 1152, height: 2048)
        }
    }
}
