import SwiftUI

// MARK: - Fluent Design System
//
// The shared visual language for every surface in the app: the menu panel,
// Settings, Setup, and the recording overlay. Built on three rules:
//
// 1. One accent, used sparingly — an indigo that reads as "voice" without
//    fighting system semantics (red stays recording/destructive).
// 2. Depth comes from layered fills and hairlines, never blur or drop shadows
//    — Settings stacks 15+ surfaces per tab, and live materials/offscreen
//    shadows made tab switching janky. Flat-but-layered reads premium at a
//    fraction of the cost.
// 3. Geometry is capsules for actions, continuous rounded rectangles for
//    surfaces — matching the current macOS control vocabulary.
//
// APPLE LIQUID GLASS (macOS 26+): `liquidSurface` and the prominent button
// style use Apple's true Liquid Glass (`.glassEffect`) when running on
// macOS 26+, falling back to the layered-fill system below on macOS 13–25.

/// Design tokens. Everything visual traces back here.
enum FluentTheme {
    /// The voice accent — an electric indigo. Used for selection, primary
    /// actions, and focus; never for decoration.
    static let accent = Color(red: 0.44, green: 0.38, blue: 0.98)

    /// Spacing scale (4pt base).
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
    }

    /// Corner radius scale.
    enum Radius {
        static let chip: CGFloat = 7
        static let control: CGFloat = 9
        static let card: CGFloat = 16
        static let panel: CGFloat = 20
    }
}

// MARK: - Surfaces

/// A layered card surface: vertical sheen, outer hairline, inner top
/// highlight. Reads as machined glass under soft light — no blur required.
struct LiquidSurfaceModifier: ViewModifier {
    var cornerRadius: CGFloat = FluentTheme.Radius.card
    var strokeOpacity: Double = 1.0

    @ViewBuilder
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            // True Apple Liquid Glass supplies its own depth and clipping.
            content.glassEffect(.regular, in: shape)
        } else {
            content
                .background(
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    // Vertical sheen: barely-lighter top edge, settling darker.
                    shape.fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.045),
                                Color.white.opacity(0.0),
                                Color.black.opacity(0.02),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                )
                .overlay(
                    // Outer hairline — defines the edge without demanding attention.
                    shape.strokeBorder(Color.primary.opacity(0.09 * strokeOpacity), lineWidth: 1)
                )
                .overlay(
                    // Inner top highlight — the light-catching lip.
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.14),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                    .clipShape(shape)
                    .allowsHitTesting(false)
                )
                .clipShape(shape)
        }
    }
}

extension View {
    /// Applies the standard card surface treatment.
    func liquidSurface(
        cornerRadius: CGFloat = FluentTheme.Radius.card,
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

/// A selectable row treatment (settings sidebar): System-Settings-style filled
/// pill when selected, whisper-quiet hover otherwise.
struct LiquidSelectionModifier: ViewModifier {
    var isSelected: Bool
    var cornerRadius: CGFloat = FluentTheme.Radius.control

    @State private var hovering = false

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .modifier(SelectionTintModifier(isSelected: isSelected, shape: shape))
            .background(
                shape.fill(
                    isSelected
                        ? FluentTheme.accent.opacity(0.999)
                        : hovering
                            ? Color.primary.opacity(0.05)
                            : Color.clear
                )
            )
            .animation(.easeOut(duration: 0.14), value: isSelected)
            .animation(.easeOut(duration: 0.1), value: hovering)
            .contentShape(shape)
            .onHover { hovering = $0 && !isSelected }
    }
}

/// Applies the selected foreground treatment (white-on-accent) to whatever the
/// row declares as its content, including icon chips.
private struct SelectionTintModifier: ViewModifier {
    let isSelected: Bool
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        content
            .environment(\.fluentSelected, isSelected)
            .foregroundStyle(isSelected ? Color.white : Color.primary)
    }
}

/// Environment flag a row's children can read to restyle themselves when the
/// row is selected (icon chips flip from tinted-on-surface to translucent-on-
/// accent, labels go white, etc.).
private struct FluentSelectedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var fluentSelected: Bool {
        get { self[FluentSelectedKey.self] }
        set { self[FluentSelectedKey.self] = newValue }
    }
}

extension View {
    func liquidSelection(isSelected: Bool, cornerRadius: CGFloat = FluentTheme.Radius.control) -> some View {
        modifier(LiquidSelectionModifier(isSelected: isSelected, cornerRadius: cornerRadius))
    }
}

/// Groups nearby glass surfaces so they blend/morph and share a single render
/// pass. On macOS 26+ this is a real `GlassEffectContainer`; on macOS 13–25 it
/// passes its content through unchanged.
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

// MARK: - Buttons

/// Primary action: full-bleed accent capsule with a subtle top sheen so it
/// feels lit rather than flat.
struct LiquidProminentButtonStyle: ButtonStyle {
    var tint: Color = FluentTheme.accent

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, tint: tint)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let tint: Color
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            if #available(macOS 26.0, *) {
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
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .foregroundStyle(.white)
                    .background(
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        tint.opacity(configuration.isPressed ? 0.82 : 1.0),
                                        tint.opacity(configuration.isPressed ? 0.72 : 0.88),
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: tint.opacity(isEnabled ? 0.32 : 0.0), radius: 9, y: 3)
                    .opacity(isEnabled ? 1.0 : 0.45)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
                    .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            }
        }
    }
}

/// Quiet secondary action: hairline capsule that fills softly on hover.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.10 : 0.045))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == GhostButtonStyle {
    static var fluentGhost: GhostButtonStyle { GhostButtonStyle() }
}

extension ButtonStyle where Self == LiquidProminentButtonStyle {
    static var liquidProminent: LiquidProminentButtonStyle { LiquidProminentButtonStyle() }
}

// MARK: - Fields

/// Inset text field: slightly darker than its surface (fields receive
/// content), hairline border, accent focus ring.
struct FluentFieldStyle: TextFieldStyle {
    @FocusState.Binding var isFocused: Bool

    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: FluentTheme.Radius.control, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FluentTheme.Radius.control, style: .continuous)
                    .strokeBorder(
                        isFocused ? FluentTheme.accent.opacity(0.65) : Color.primary.opacity(0.12),
                        lineWidth: 1
                    )
            )
            .animation(.easeOut(duration: 0.15), value: isFocused)
    }
}

// MARK: - Shared Components

/// Tinted rounded-square icon container — the System Settings vocabulary for
/// giving standalone icons presence. Flips to translucent-white when its row
/// is selected.
struct IconChip: View {
    let systemImage: String
    var tint: Color = FluentTheme.accent
    var size: CGFloat = 24
    var iconSize: CGFloat = 12

    @Environment(\.fluentSelected) private var isSelected

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: iconSize, weight: .semibold))
            .foregroundStyle(isSelected ? Color.white : tint)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill(isSelected ? Color.white.opacity(0.22) : tint.opacity(0.14))
            )
    }
}

/// Eyebrow-style section label between card groups.
struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.06)
            .foregroundStyle(.tertiary)
            .padding(.leading, 2)
    }
}

/// Standard settings page scaffold: generous padding, aligned header, card
/// stack rhythm. Every tab runs through this so the window always feels like
/// one document.
struct SettingsPage<Content: View>: View {
    let title: String
    var subtitle: String?
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FluentTheme.Space.l) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.bold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 4)

                content
            }
            .padding(.top, 36)
            .padding(.horizontal, FluentTheme.Space.xxl)
            .padding(.bottom, FluentTheme.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
