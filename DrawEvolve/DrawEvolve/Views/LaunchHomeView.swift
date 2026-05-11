//
//  LaunchHomeView.swift
//  DrawEvolve
//
//  First screen after sign-in. Two choices: start a new canvas, or
//  open the gallery. Routes upstream of the canvas's first-launch
//  prompt-input modal so a user who taps "Go to gallery" can browse
//  their work without filling out the prompt for a new drawing first.
//

import SwiftUI

struct LaunchHomeView: View {
    let onNewCanvas: () -> Void
    let onOpenGallery: () -> Void

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            Image("DrawEvolveLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 320, height: 320)

            VStack(spacing: 8) {
                Text("Welcome to DrawEvolve")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                Text("Draw. Get a critique. Evolve.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(spacing: 12) {
                Button(action: onNewCanvas) {
                    Label("Set up a new canvas", systemImage: "square.and.pencil")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onOpenGallery) {
                    Label("Go to gallery", systemImage: "photo.on.rectangle.angled")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 480)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
    }
}

#Preview {
    LaunchHomeView(onNewCanvas: {}, onOpenGallery: {})
}
