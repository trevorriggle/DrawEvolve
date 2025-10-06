//
//  ContentView.swift
//  DrawEvolve
//
//  Main navigation and state management for the app.
//

import SwiftUI

struct ContentView: View {
    @State private var drawingContext = DrawingContext()
    @State private var showPromptInput = true

    var body: some View {
        Group {
            if showPromptInput {
                PromptInputView(
                    context: $drawingContext,
                    isPresented: $showPromptInput
                )
            } else {
                DrawingCanvasView(context: $drawingContext)
            }
        }
    }
}

#Preview {
    ContentView()
}
