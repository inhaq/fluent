import AppKit
import SwiftUI

@main
struct FluentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("show_menu_bar_icon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        } label: {
            MenuBarLabel()
                .environmentObject(appDelegate.appState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
struct MenuBarLabel: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var notificationManager = VocabularyNotificationManager.shared

    var body: some View {
        HStack(spacing: 4) {
            if notificationManager.showCheckmark {
                Image(systemName: "checkmark")
            }
            icon
        }
        .animation(.easeInOut(duration: 0.2), value: notificationManager.showCheckmark)
    }

    /// Idle state shows the Fluent logo glyph (speech bubble + waveform).
    /// Recording / transcribing keep their distinct status symbols.
    @ViewBuilder
    private var icon: some View {
        if appState.isRecording {
            Image(systemName: "record.circle")
        } else if appState.isTranscribing {
            Image(systemName: "ellipsis.circle")
        } else {
            Image(nsImage: BubbleWaveMenuBarIcon.templateImage)
                .renderingMode(.template)
        }
    }
}

/// Monochrome menu-bar glyph derived from the app logo: a speech-bubble ring
/// with a tail and a waveform inside.
///
/// Drawn with `NSBezierPath` through a sizing drawing handler — the reliable
/// way to render a crisp, correctly-sized template image inside `MenuBarExtra`.
/// (SwiftUI does not scale a bitmap `NSImage` loaded from PNG/asset data in a
/// menu-bar label, so such images render oversized or blank.) Flagged as a
/// template so macOS auto-tints it (black on light bars, white on dark).
enum BubbleWaveMenuBarIcon {
    static let templateImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current else { return false }
            NSColor.black.setFill()

            // Bubble body (outer disc) + tail spout, unioned via nonzero winding.
            let body = NSBezierPath()
            body.appendOval(in: NSRect(x: 1, y: 1.3, width: 16, height: 16)) // center (9, 9.3), r = 8
            let tail: [(x: CGFloat, y: CGFloat, r: CGFloat)] = [
                (5.6, 5.0, 1.7), (4.6, 3.8, 1.45), (3.7, 2.6, 1.15), (3.0, 1.6, 0.8),
            ]
            for t in tail {
                body.appendOval(in: NSRect(x: t.x - t.r, y: t.y - t.r, width: t.r * 2, height: t.r * 2))
            }
            body.fill()

            // Punch the ring's interior to leave a clean transparent hole.
            ctx.compositingOperation = .clear
            NSBezierPath(ovalIn: NSRect(x: 3.4, y: 3.7, width: 11.2, height: 11.2)).fill() // center (9, 9.3), r = 5.6
            ctx.compositingOperation = .sourceOver

            // Waveform inside the bubble.
            NSColor.black.setStroke()
            let wave = NSBezierPath()
            let pts: [(x: CGFloat, y: CGFloat)] = [
                (4.9, 6.6), (6.6, 10.7), (7.8, 8.0), (9.0, 12.3),
                (10.2, 8.0), (11.4, 10.7), (13.1, 6.6),
            ]
            wave.move(to: NSPoint(x: pts[0].x, y: pts[0].y))
            for p in pts.dropFirst() {
                wave.line(to: NSPoint(x: p.x, y: p.y))
            }
            wave.lineWidth = 1.7
            wave.lineCapStyle = .round
            wave.lineJoinStyle = .round
            wave.stroke()

            return true
        }
        image.isTemplate = true
        return image
    }()
}
