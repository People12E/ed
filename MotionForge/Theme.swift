// Theme.swift — design tokens, spring animations, shared controls.

import SwiftUI

enum Theme {
    static let canvas        = Color(red: 0.047, green: 0.051, blue: 0.067)
    static let panel         = Color(red: 0.086, green: 0.090, blue: 0.118)
    static let raised        = Color(red: 0.133, green: 0.141, blue: 0.180)
    static let hairline      = Color.white.opacity(0.08)
    static let accent        = Color(red: 0.30, green: 0.79, blue: 1.00)   // selection, primary actions
    static let key           = Color(red: 1.00, green: 0.76, blue: 0.28)   // playhead + keyframes
    static let danger        = Color(red: 1.00, green: 0.42, blue: 0.42)
    static let textPrimary   = Color.white.opacity(0.92)
    static let textSecondary = Color.white.opacity(0.55)
}

extension Animation {
    /// Drawers, sheets, collapsible sections.
    static let motionPanel = Animation.interpolatingSpring(mass: 1.0, stiffness: 260, damping: 24)
    /// Small controls: presses, toggles, handles.
    static let motionSnap  = Animation.interpolatingSpring(mass: 0.8, stiffness: 420, damping: 28)
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.motionSnap, value: configuration.isPressed)
    }
}

/// 40 pt icon button used in the top bar and transport.
struct IconButton: View {
    let symbol: String
    let label: String
    var isOn = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            IconFace(symbol: symbol, isOn: isOn)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The visual of an icon button, reusable inside other controls (for example PhotosPicker).
struct IconFace: View {
    let symbol: String
    var isOn = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 40, height: 40)
            .foregroundStyle(isOn ? Theme.accent : Theme.textPrimary)
            .background(isOn ? Theme.accent.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
