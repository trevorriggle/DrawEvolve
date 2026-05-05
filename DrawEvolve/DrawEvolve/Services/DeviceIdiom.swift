//
//  DeviceIdiom.swift
//  DrawEvolve
//
//  Single source of truth for "is this an iPhone or an iPad" layout
//  decisions. Used at every surface where the UI forks between the two
//  device families.
//
//  IMPORTANT: do NOT use `@Environment(\.horizontalSizeClass)` for this
//  purpose in this codebase. iPad split-screen reports `.compact`, which
//  would silently re-layout iPad — explicitly forbidden by the iPhone
//  scaling strategy. Idiom is fixed for the app instance lifetime and
//  reports `.pad` regardless of split state.
//

import UIKit

enum DeviceIdiom {
    /// True when running on an iPhone. Use this to gate iPhone-specific
    /// layout branches; the iPad branch must remain bytes-identical to
    /// pre-iPhone-strategy main, so every fork looks like:
    ///
    ///     if DeviceIdiom.isPhone {
    ///         phoneLayout
    ///     } else {
    ///         iPadLayout   // existing code, untouched
    ///     }
    static var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// True when running on an iPad. Currently unused at any call site,
    /// but kept alongside `isPhone` so future explicit-pad checks read
    /// cleanly without having to negate `isPhone` (which can mask other
    /// idioms — Mac Catalyst, Vision, etc. — in the future).
    static var isPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}
