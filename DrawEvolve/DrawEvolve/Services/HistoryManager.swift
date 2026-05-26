//
//  HistoryManager.swift
//  DrawEvolve
//
//  Undo/redo system for canvas.
//

import Foundation
import UIKit
import SwiftUI  // for Angle (used in SelectionLiftState)

extension Notification.Name {
    /// Broadcast when the app receives a `didReceiveMemoryWarning` and
    /// the cloud storage manager has shed its caches. HistoryManager
    /// instances listen for this so they can trim their undo stacks
    /// (uncompressed LayerSnapshot data is the heaviest tenant after
    /// the live canvas textures).
    static let drawEvolveMemoryPressure = Notification.Name("DrawEvolve.memoryPressure")
}

class HistoryManager: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [HistoryAction] = []
    private var redoStack: [HistoryAction] = []

    /// History cap sized to the device's physical RAM. A single stroke's
    /// `LayerSnapshot` is uncompressed BGRA tile data and can reach
    /// ~80 MB on a 4096²/8-layer/40%-coverage drawing — a flat 50-entry
    /// cap was costing several GB of resident memory on iPad Pro and
    /// driving jetsam kills on smaller iPads. Caps are derived once at
    /// init from `ProcessInfo.physicalMemory`; the buckets are
    /// conservative on the low end and let high-RAM devices keep the
    /// old depth.
    private let maxHistory: Int = {
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0
        if gb <= 3.0 { return 20 }   // iPad mini 5, iPhone 8, iPad 9th gen
        if gb <= 6.0 { return 30 }   // iPhone 11/12, iPad Air 4
        return 50                     // M-series iPads, modern iPhones
    }()

    func record(_ action: HistoryAction) {
        undoStack.append(action)
        redoStack.removeAll()

        // Trim history if needed
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }

        updateState()
    }

    /// Aggressively trim the undo stack under memory pressure. Called
    /// from the `didReceiveMemoryWarning` listener. Keeps the most
    /// recent N entries; older snapshots are released along with their
    /// `LayerSnapshot` data.
    func trimToMostRecent(_ keep: Int) {
        if undoStack.count > keep {
            undoStack.removeFirst(undoStack.count - keep)
        }
        redoStack.removeAll()
        updateState()
    }

    private var memoryPressureObserver: NSObjectProtocol?

    init() {
        memoryPressureObserver = NotificationCenter.default.addObserver(
            forName: .drawEvolveMemoryPressure,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Keep just the most recent 10 entries when iOS is yelling.
            // The user can still undo their last few strokes; older
            // snapshots are the bulk of the resident weight.
            self?.trimToMostRecent(10)
        }
    }

    deinit {
        if let observer = memoryPressureObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func undo() -> HistoryAction? {
        guard let action = undoStack.popLast() else { return nil }
        redoStack.append(action)
        updateState()
        return action
    }

    func redo() -> HistoryAction? {
        guard let action = redoStack.popLast() else { return nil }
        undoStack.append(action)
        updateState()
        return action
    }

    func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
        updateState()
    }

    private func updateState() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }
}

/// Bundle of everything needed to reconstruct the "lifted" selection state
/// (layer-with-hole + floating texture + polygon + transform deltas).
/// Carried by the three new selection HistoryAction cases. Stored as
/// UIImage rather than MTLTexture so the history stack stays CPU-resident
/// — the floating MTLTexture is recreated via `renderer.makeTexture(from:)`
/// on undo/redo. `preLiftSnapshot` is included so that undo-of-commit /
/// undo-of-cancel can restore CanvasStateManager.selectionBeforeSnapshot,
/// which any subsequent user-triggered cancel from the restored lifted
/// state will need.
struct SelectionLiftState {
    /// Layer state BEFORE the lift (no hole).
    let preLiftSnapshot: CanvasRenderer.LayerSnapshot
    /// Layer state AT the lift (hole punched).
    let layerWithHoleSnapshot: CanvasRenderer.LayerSnapshot
    /// CPU copy of the lifted pixels, used to rebuild the floating MTLTexture.
    let liftedPixels: UIImage
    /// Polygon at lift time (RDP-simplified + closed for lasso; 4-corner quad for rect).
    let sourcePath: [CGPoint]
    /// Bbox at lift time. Restored to `selectionOriginalRect`.
    let originalRect: CGRect
    /// Transform deltas captured at the moment commit/cancel fired
    /// (zero/identity for `.selectionLift` — no transforms applied yet).
    let offset: CGPoint
    let scale: CGSize
    let rotation: Angle
}

enum HistoryAction {
    case stroke(layerId: UUID, beforeSnapshot: CanvasRenderer.LayerSnapshot, afterSnapshot: CanvasRenderer.LayerSnapshot)
    case layerAdded(DrawingLayer)
    case layerRemoved(DrawingLayer, index: Int)
    case layerMoved(from: Int, to: Int)
    case layerPropertyChanged(layerId: UUID, property: LayerProperty)
    // Flip is an involution — undoing it is just applying the same flip
    // again on the same set of layers, so we don't need before/after
    // pixel snapshots (which would force a full-texture getBytes per
    // layer). `layerIds` pins which layers were flipped at op time so
    // visibility changes between record and undo don't re-flip the
    // wrong set.
    case flipContent(layerIds: [UUID], flipH: Bool, flipV: Bool)

    // MARK: - Selection lifecycle (Polygon ↔ Lifted ↔ Idle)
    //
    // Three explicit cases for the rebuilt selection state machine.
    // - .selectionLift: Polygon → Lifted (first transform input).
    //   Undo: liftState.preLiftSnapshot → pre-lift Idle.
    //   Redo: liftState.layerWithHoleSnapshot + recreate floating + restore polygon.
    // - .selectionCommit: Lifted → Idle (tap-outside / tool-change / floating-drag release).
    //   Undo: restore lifted state from liftState.
    //   Redo: afterSnapshot → post-commit Idle.
    // - .selectionCancel: Lifted → Idle (pill tap post-lift).
    //   Undo: restore lifted state from liftState.
    //   Redo: restoredSnapshot → pre-lift Idle.
    //
    // None of these are recorded yet — call sites land in a later commit.
    // Restore branches in CanvasStateManager.undo()/redo() are wired so
    // the schema is exhaustive and functional the moment a call site exists.
    case selectionLift(layerId: UUID, liftState: SelectionLiftState)
    case selectionCommit(layerId: UUID, afterSnapshot: CanvasRenderer.LayerSnapshot, liftState: SelectionLiftState)
    case selectionCancel(layerId: UUID, restoredSnapshot: CanvasRenderer.LayerSnapshot, liftState: SelectionLiftState)

    enum LayerProperty {
        case opacity(old: Float, new: Float)
        case name(old: String, new: String)
        case blendMode(old: BlendMode, new: BlendMode)
        case visibility(old: Bool, new: Bool)
        case lock(old: Bool, new: Bool)
    }
}
