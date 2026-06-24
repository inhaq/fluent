import SwiftUI

// MARK: - Liquid-style design layer
//
// A small, reusable set of modifiers that give the app a modern, translucent
// "liquid glass"-inspired look. These use system materials so they compile and
// run on the app's macOS 13 deployment target and automatically adapt to light
// and dark appearance.
//
// NOTE ON APPLE LIQUID GLASS (macOS 26+):
// Apple's true Liquid Glass APIs (`.glassEffect(_:in:)`, `GlassEffectContainer`)
// require the macOS 26 SDK to compile and macOS 26 at runtime. To adopt them
// once the project is built with Xcode 26, change ONLY the `liquidSurface`
// modifier below to branch on `if #available(macOS 26.0, *)` and apply
// `.glassEffect(.regular, in: shape)` there — every card/surface in the app
// picks it up automatically because they all funnel through this one modifier.

/// A translucent rounded surface (card/panel) with a hairline highlight and a
/// soft shadow — the building block for the modernized UI.
struct LiquidSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var material: Material = .regularMaterial
    var strokeOpacity: Double = 1.0
    var shadowRadius: CGFloat = 8
    var shadowY: CGFloat = 4

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(material))
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.18 * strokeOpacity),
                            Color.white.opacity(0.04 * strokeOpacity)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
            )
            .clipShape(shape)
            .shadow(color: Color.black.opacity(0.12), radius: shadowRadius, x: 0, y: shadowY)
    }
}

extension View {
    /// Applies the standard translucent "liquid" surface treatment.
    func liquidSurface(
        cornerRadius: CGFloat = 14,
        material: Material = .regularMaterial,
        strokeOpacity: Double = 1.0,
        shadowRadius: CGFloat = 8,
        shadowY: CGFloat = 4
    ) -> some View {
        modifier(
            LiquidSurfaceModifier(
                cornerRadius: cornerRadius,
                material: material,
                strokeOpacity: strokeOpacity,
                shadowRadius: shadowRadius,
                shadowY: shadowY
            )
        )
    }
}

/// A selectable row treatment (used by the settings sidebar) with a soft accent
/// fill + hairline ring when selected.
struct LiquidSelectionModifier: ViewModifier {
    var isSelected: Bool
    var cornerRadius: CGFloat = 9

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .background(shape.fill(Color.accentColor.opacity(isSelected ? 0.16 : 0)))
            .overlay(
                shape.strokeBorder(
                    Color.accentColor.opacity(isSelected ? 0.35 : 0),
                    lineWidth: 1
                )
            )
            .contentShape(shape)
            .animation(.easeInOut(duration: 0.15), value: isSelected)
    }
}

extension View {
    func liquidSelection(isSelected: Bool, cornerRadius: CGFloat = 9) -> some View {
        modifier(LiquidSelectionModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

/// A modern, capsule-shaped tinted button style used for primary actions.
struct LiquidProminentButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(configuration.isPressed ? 0.8 : 1.0))
            )
            .foregroundStyle(.white)
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == LiquidProminentButtonStyle {
    static var liquidProminent: LiquidProminentButtonStyle { LiquidProminentButtonStyle() }
}
