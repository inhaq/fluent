import SwiftUI

// MARK: - Liquid-style design layer
//
// A small, reusable set of modifiers that give the app a modern, translucent
// "liquid glass"-inspired look. These use system materials so they compile and
// run on the app's macOS 13 deployment target and automatically adapt to light
// and dark appearance.
//
// APPLE LIQUID GLASS (macOS 26+):
// `liquidSurface` and the prominent button style use Apple's true Liquid Glass
// (`.glassEffect`) when running on macOS 26+, and fall back to system materials
// on macOS 13–25. Everything funnels through these modifiers, so the whole app
// adopts Liquid Glass automatically. Building requires the macOS 26 SDK
// (Xcode 26+); the `if #available(macOS 26.0, *)` gate keeps the binary running
// on the macOS 13 deployment target.
//
// Possible future enhancement: wrap each tab's stack of cards in a
// `GlassEffectContainer` so adjacent glass surfaces blend/morph and share a
// single render pass.

/// A translucent rounded surface (card/panel) with a hairline highlight and a
/// soft shadow — the building block for the modernized UI.
struct LiquidSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = 14
    var strokeOpacity: Double = 1.0

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // True Apple Liquid Glass. It supplies its own depth/shadow and
            // clips to the shape, so no extra material/stroke/shadow is added.
            content.glassEffect(.regular, in: shape)
        } else {
            // macOS 13–25 fallback. Deliberately cheap: the Settings screens
            // stack ~15+ of these surfaces, and a live `Material`
            // (NSVisualEffectView backdrop blur) plus a per-card drop shadow
            // made switching tabs janky (each tab switch had to spin up a dozen+
            // blur views and offscreen shadow passes). A flat, adaptive fill and
            // a hairline stroke keep the card look at a fraction of the cost,
            // with no NSVisualEffectView and no offscreen shadow rendering.
            content
                .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(
                    shape.strokeBorder(
                        Color.primary.opacity(0.08 * strokeOpacity),
                        lineWidth: 1
                    )
                )
                .clipShape(shape)
        }
    }
}

extension View {
    /// Applies the standard translucent "liquid" surface treatment.
    func liquidSurface(
        cornerRadius: CGFloat = 14,
        strokeOpacity: Double = 1.0
    ) -> some View {
        modifier(
            LiquidSurfaceModifier(
                cornerRadius: cornerRadius,
                strokeOpacity: strokeOpacity
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

/// Groups nearby glass surfaces so they blend/morph and share a single render
/// pass. On macOS 26+ this is a real `GlassEffectContainer`; on macOS 13–25 it
/// passes its content through unchanged (the material fallback needs no
/// grouping).
struct LiquidGlassGroup<Content: View>: View {
    private let spacing: CGFloat?
    private let content: Content

    init(spacing: CGFloat? = nil, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

/// A modern, capsule-shaped tinted button style used for primary actions.
struct LiquidProminentButtonStyle: ButtonStyle {
    var tint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            if #available(macOS 26.0, *) {
                // Native Liquid Glass, tinted + interactive (fluid press).
                configuration.label
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .glassEffect(
                        .regular.tint(tint).interactive(),
                        in: Capsule(style: .continuous)
                    )
                    .opacity(isEnabled ? 1.0 : 0.45)
            } else {
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
                    .opacity(isEnabled ? 1.0 : 0.45)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
        }
    }
}

extension ButtonStyle where Self == LiquidProminentButtonStyle {
    static var liquidProminent: LiquidProminentButtonStyle { LiquidProminentButtonStyle() }
}
