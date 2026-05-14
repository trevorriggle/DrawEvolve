//
//  EyeTestPanel.swift
//  DrawEvolve
//
//  Production panel for the Composition / "Eye Test" feature. Renders
//  CompositionAnalysisService output with the four defenses from the
//  M1 build plan:
//
//    1. Drawing-readiness gate refusal → "Add more values and shapes…"
//    2. Confidence-low handling → "Vision couldn't read this drawing
//       clearly" instead of markers.
//    3. Tentative hotspot styling → low-confidence rows treated
//       distinctly in the list (markers also styled distinctly in
//       EyeTestOverlay).
//    4. Honest header copy that frames the analysis as one
//       perspective, not ground truth.
//
//  Honest copy is locked. Do not weaken to "the eye goes here" or
//  similar — see condition 3 of the M2 build plan.
//

import SwiftUI

struct EyeTestPanel: View {
    @ObservedObject var service: CompositionAnalysisService
    @ObservedObject var canvasState: CanvasStateManager
    @Binding var showHeatmap: Bool
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                honestCopyHeader
                Divider()
                ScrollView {
                    bodyContent
                        .padding(16)
                }
            }
            .navigationTitle("Composition")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
    }

    /// Locked copy per condition 3 of the M2 build plan. Do not
    /// weaken. Soften only with user approval.
    private var honestCopyHeader: some View {
        Text("Vision's attention model estimates these regions pull the most focus. It was trained on photographs and is approximate for drawings — read it as one perspective, not ground truth.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch service.lastResult {
        case nil:
            firstOpenContent
        case .ready(let findings):
            readyContent(findings: findings)
        case .notReady(let report):
            notReadyContent(report: report)
        case .visionError(let message):
            errorContent(message: message)
        }
    }

    // MARK: - States

    private var firstOpenContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tap Run analysis to compute the top three attention regions for the current canvas. Results render as markers on top of your drawing.")
                .font(.callout)
                .foregroundStyle(.primary)
            runAnalysisButton(label: "Run analysis")
        }
    }

    private func readyContent(findings: CompositionFindings) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if findings.confidenceLow {
                lowConfidenceBanner
            } else {
                hotspotList(findings: findings)
            }

            HStack {
                runAnalysisButton(label: "Run again", style: .bordered)
                Toggle(isOn: $showHeatmap) {
                    Label("Heatmap", systemImage: "square.stack.3d.up.fill")
                }
                .toggleStyle(.button)
                .controlSize(.regular)
            }
        }
    }

    private var lowConfidenceBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Vision couldn't read this drawing clearly", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Every hotspot the model returned has low confidence. Add more rendered values and clearer focal contrast, then try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
    }

    private func hotspotList(findings: CompositionFindings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Top \(findings.attentionHotspots.count) attention region\(findings.attentionHotspots.count == 1 ? "" : "s")")
                .font(.headline)
            ForEach(Array(findings.attentionHotspots.enumerated()), id: \.offset) { index, hotspot in
                hotspotRow(index: index + 1, hotspot: hotspot)
            }
        }
    }

    private func hotspotRow(index: Int, hotspot: SaliencyHotspot) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(hotspot.isTentative ? Color.orange.opacity(0.55) : Color.accentColor)
                    .frame(width: 30, height: 30)
                Text("\(index)")
                    .font(.callout.bold())
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int((hotspot.confidence * 100).rounded()))% confidence")
                    .font(.callout)
                if hotspot.isTentative {
                    Text("low confidence — treat as tentative")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func notReadyContent(report: CompositeReadinessReport) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(CompositeReadinessReport.notReadyMessage, systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Composition analysis needs enough rendered area to read attention pulls. Keep working on the drawing and try again.")
                .font(.callout)
                .foregroundStyle(.secondary)
            runAnalysisButton(label: "Try again", style: .bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(10)
    }

    private func errorContent(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Couldn't run analysis", systemImage: "exclamationmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("Composition analysis runs on-device using Apple Vision. If this keeps happening, the feature can be disabled remotely — file a TestFlight report.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.06))
                .cornerRadius(6)
            runAnalysisButton(label: "Retry", style: .bordered)
        }
    }

    // MARK: - Run button

    private enum ButtonStyleChoice {
        case prominent
        case bordered
    }

    @ViewBuilder
    private func runAnalysisButton(label: String, style: ButtonStyleChoice = .prominent) -> some View {
        let button = Button(action: runAnalysis) {
            HStack {
                if service.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(service.isRunning ? "Analyzing…" : label)
                    .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 6)
        }
        .disabled(service.isRunning)

        switch style {
        case .prominent: button.buttonStyle(.borderedProminent)
        case .bordered: button.buttonStyle(.bordered)
        }
    }

    private func runAnalysis() {
        Task { @MainActor in
            _ = await service.analyze(canvasState: canvasState)
        }
    }
}
