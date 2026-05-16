//
//  HistoryManager.swift
//  DrawEvolve
//
//  Undo/redo system for canvas.
//

import Foundation

class HistoryManager: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private var undoStack: [HistoryAction] = []
    private var redoStack: [HistoryAction] = []
    private let maxHistory = 50 // Limit history to prevent memory issues

    func record(_ action: HistoryAction) {
        undoStack.append(action)
        redoStack.removeAll()

        // Trim history if needed
        if undoStack.count > maxHistory {
            undoStack.removeFirst()
        }

        updateState()
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
    }
}
