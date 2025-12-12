//
//  TerminalColors.swift
//  OpenCodeIsland
//
//  Color palette for terminal-style UI
//

import SwiftUI

struct TerminalColors {
    static let green = Color(red: 0.4, green: 0.75, blue: 0.45)
    static let amber = Color(red: 1.0, green: 0.7, blue: 0.0)
    static let red = Color(red: 1.0, green: 0.3, blue: 0.3)
    static let cyan = Color(red: 0.0, green: 0.8, blue: 0.8)
    static let blue = Color(red: 0.4, green: 0.6, blue: 1.0)
    static let magenta = Color(red: 0.8, green: 0.4, blue: 0.8)
    static let prompt = Color(red: 0.85, green: 0.47, blue: 0.34)  // #d97857
    static let background = Color.white.opacity(0.05)
    static let backgroundHover = Color.white.opacity(0.1)

    // Slate palette - visible on black backgrounds
    static let slate50 = Color(red: 0.97, green: 0.98, blue: 0.98)   // #f8fafc
    static let slate100 = Color(red: 0.95, green: 0.96, blue: 0.98)  // #f1f5f9
    static let slate200 = Color(red: 0.89, green: 0.91, blue: 0.94)  // #e2e8f0
    static let slate300 = Color(red: 0.80, green: 0.84, blue: 0.88)  // #cbd5e1
    static let slate400 = Color(red: 0.58, green: 0.64, blue: 0.72)  // #94a3b8
    static let slate500 = Color(red: 0.39, green: 0.45, blue: 0.55)  // #64748b
    static let slate600 = Color(red: 0.28, green: 0.33, blue: 0.41)  // #475569

    // Convenience aliases
    static let dim = slate400
    static let dimmer = slate500
    static let icon = slate400
    static let iconHover = slate200
    static let text = slate300
    static let textSecondary = slate400
    static let textMuted = slate500
}
