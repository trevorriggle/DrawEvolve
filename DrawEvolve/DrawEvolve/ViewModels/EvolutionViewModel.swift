//
//  EvolutionViewModel.swift
//  DrawEvolve
//
//  Single-screen view-model for EvolutionView. Owns the load lifecycle
//  (idle → loading → loaded/error) and exposes a retry hook.
//

import Foundation
import SwiftUI

@MainActor
final class EvolutionViewModel: ObservableObject {
    enum LoadState {
        case idle
        case loading
        case loaded(EvolutionData)
        case error(EvolutionError)
    }

    @Published private(set) var loadState: LoadState = .idle

    private let service: EvolutionService

    init(service: EvolutionService = .shared) {
        self.service = service
    }

    /// Idempotent load. Re-fires on pull-to-refresh and on retry. The
    /// loading state is set BEFORE awaiting so the UI updates immediately
    /// even on the second invocation.
    func load() async {
        loadState = .loading
        do {
            let data = try await service.fetchEvolution()
            loadState = .loaded(data)
        } catch let error as EvolutionError {
            loadState = .error(error)
        } catch {
            loadState = .error(.unknown)
        }
    }

    /// Alias for clarity at error-state retry call sites.
    func retry() async { await load() }
}
