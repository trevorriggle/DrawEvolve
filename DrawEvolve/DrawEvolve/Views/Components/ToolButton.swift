//
//  ToolButton.swift
//  DrawEvolve
//
//  Reusable toolbar button component
//

import SwiftUI

struct ToolButton: View {
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundColor(isSelected ? .white : .primary)
                .frame(width: 44, height: 44)
                .background(isSelected ? Color.accentColor : Color.clear)
                .cornerRadius(8)
        }
    }
}
