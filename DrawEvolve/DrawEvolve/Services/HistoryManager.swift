//
//  HistoryManager.swift
//  DrawEvolve
//
//  Undo/redo system for canvas.
//

import Foundation
import UIKit

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

    enum LayerProperty {
        case opacity(old: Float, new: Float)
        case name(old: String, new: String)
        case blendMode(old: BlendMode, new: BlendMode)
        case visibility(old: Bool, new: Bool)
        case lock(old: Bool, new: Bool)
    }
}
