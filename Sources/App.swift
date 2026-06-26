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
/// with a tail and a waveform inside. Embedded as a base64 PNG and flagged as a
/// template image so macOS auto-tints it (black on light bars, white on dark).
/// Displayed at 18pt; the bitmap is 72x72 so it stays crisp on Retina.
enum BubbleWaveMenuBarIcon {
    static let templateImage: NSImage = {
        guard let data = Data(base64Encoded: base64PNG),
              let image = NSImage(data: data) else {
            // Fallback to a stock symbol if decoding ever fails.
            let fallback = NSImage(systemSymbolName: "waveform.circle",
                                   accessibilityDescription: "Fluent") ?? NSImage()
            fallback.isTemplate = true
            return fallback
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }()

    private static let base64PNG = """
    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
    """
}
