//
//  DrawEvolveApp.swift
//  DrawEvolve
//
//  App entry point.
//

import SwiftUI

@main
struct DrawEvolveApp: App {
    init() {
        // Initialize crash reporting
        _ = CrashReporter.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
