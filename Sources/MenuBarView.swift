import SwiftUI
import AppKit

// MARK: - Window-style menu panel

/// Resolves the `NSWindow` hosting the menu-bar panel so we can dismiss it
/// programmatically. A `.window`-style `MenuBarExtra` does NOT auto-close when
/// the user activates an item (unlike a system menu), so we close the panel's
/// own window after actions.
private struct MenuWindowResolver: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.window) }
    }
}

/// Reports the natural (fitting) height of the menu panel content so the
/// `.window`-style `MenuBarExtra` can be given a concrete height. A bare
/// `ScrollView` has no intrinsic height in its scroll axis, which otherwise
/// collapses the panel window to a 1–2px sliver.
private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A full-width tappable panel row with a hover highlight, used to mimic native
/// menu items inside the `.window`-style panel.
private struct PanelRow<Label: View>: View {
    var role: ButtonRole?
    let action: () -> Void
    let label: () -> Label
    @State private var hovering = false

    init(
        role: ButtonRole? = nil,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> Label
    ) {
        self.role = role
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(role: role, action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
                )
                .scaleEffect(hovering ? 1.0 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Soft tinted banner for permission warnings — colored text on a quiet tint,
/// with a hairline edge. Solid fills read as errors; these are invitations.
private struct WarningBanner: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(color)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color.opacity(0.6))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: FluentTheme.Radius.control, style: .continuous)
                    .fill(color.opacity(hovering ? 0.16 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FluentTheme.Radius.control, style: .continuous)
                    .strokeBorder(color.opacity(0.28), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var hostWindow: NSWindow?
    /// Measured natural height of the panel content. Defaults to the max so the
    /// panel opens at full height and shrinks to fit, never collapsing to 0.
    @State private var contentHeight: CGFloat = MenuBarView.maxPanelHeight

    private static let panelWidth: CGFloat = 320
    private static let maxPanelHeight: CGFloat = 620

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var recentHistoryItems: [PipelineHistoryItem] {
        Array(appState.pipelineHistory.filter { !transcriptText(for: $0).isEmpty }.prefix(10))
    }

    private func transcriptText(for item: PipelineHistoryItem) -> String {
        let cleaned = item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleaned.isEmpty {
            return cleaned
        }
        return item.rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcriptFull(for item: PipelineHistoryItem) -> String {
        if !item.postProcessedTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.postProcessedTranscript
        }
        return item.rawTranscript
    }

    private func transcriptSnippet(for item: PipelineHistoryItem) -> String {
        let text = transcriptText(for: item)
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "(no transcript)" }
        return text.count > 48 ? String(text.prefix(48)) + "..." : text
    }

    private func copyTranscriptToPasteboard(_ transcript: String) {
        guard !transcript.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
    }

    /// Closes the menu panel. Used after activating an item, since the
    /// `.window` style does not dismiss automatically.
    private func dismiss() {
        let window = hostWindow ?? NSApp.keyWindow
        DispatchQueue.main.async { window?.close() }
    }

    private func openRunLog() {
        appState.selectedSettingsTab = .runLog
        NotificationCenter.default.post(name: .showSettings, object: nil)
        dismiss()
    }

    private func openSettings(tab: SettingsTab? = nil) {
        if let tab {
            appState.selectedSettingsTab = tab
        }
        NotificationCenter.default.post(name: .showSettings, object: nil)
        dismiss()
    }

    private func rowLabel(_ title: String, systemImage: String, tint: Color = .primary) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint == .primary ? Color.secondary : tint)
                .frame(width: 16)
            Text(title)
                .font(.body)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// Tiny uppercase divider label between panel groups.
    private func sectionLabel(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.07)
            .foregroundStyle(Color.secondary.opacity(0.75))
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private var statusLabel: some View {
        Group {
            if appState.isRecording {
                statusPill(
                    text: "Recording",
                    color: .red,
                    pulsing: true
                )
            } else if appState.isTranscribing {
                HStack(spacing: 7) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(appState.debugStatusMessage.isEmpty ? "Processing" : appState.debugStatusMessage)
                        .lineLimit(1)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color.green.opacity(0.9))
                        .frame(width: 6, height: 6)
                    Text(appState.shortcutStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
    }

    @State private var pulse = false

    private func statusPill(text: String, color: Color, pulsing: Bool) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .opacity(pulsing ? (pulse ? 1.0 : 0.35) : 1.0)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(color.opacity(0.12)))
        .onAppear {
            guard pulsing else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                // Header — app identity
                HStack(spacing: 10) {
                    if let appIcon = NSApp.applicationIconImage {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 26, height: 26)
                            .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                    }
                    Text(AppName.displayName)
                        .font(.headline)
                    Spacer()
                    Text("v\(appVersion)")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule(style: .continuous).fill(Color.primary.opacity(0.06)))
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)

                // Permission warnings
                if !appState.hasScreenRecordingPermission {
                    warningRow(
                        title: "Screen Recording Permission Needed",
                        systemImage: "camera.viewfinder",
                        color: .orange
                    ) {
                        appState.requestScreenCapturePermission()
                        dismiss()
                    }
                }

                if !appState.hasAccessibility {
                    warningRow(
                        title: "Accessibility Required",
                        systemImage: "exclamationmark.triangle.fill",
                        color: .red
                    ) {
                        appState.showAccessibilityAlert()
                        dismiss()
                    }
                }

                statusLabel
                    .padding(.vertical, 2)

                // Primary action
                Button {
                    appState.toggleRecording()
                    dismiss()
                } label: {
                    Label(
                        appState.isRecording ? "Stop Recording" : "Start Dictating",
                        systemImage: appState.isRecording ? "stop.fill" : "mic.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.liquidProminent)
                .disabled(appState.isTranscribing)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                if let hotkeyError = appState.hotkeyMonitoringErrorMessage {
                    Text(hotkeyError)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                }

                if let error = appState.errorMessage {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(3)
                        .padding(.horizontal, 10)
                }

                // Paste again + last transcript
                if !appState.lastTranscript.isEmpty && !appState.isRecording && !appState.isTranscribing {
                    Divider().padding(.vertical, 4)
                    sectionLabel("Last Transcript")

                    PanelRow {
                        appState.copyLastTranscriptToPasteboard()
                        dismiss()
                    } label: {
                        rowLabel(
                            appState.copyAgainShortcut.isDisabled
                                ? "Paste Again"
                                : "Paste Again  (\(appState.copyAgainShortcut.displayName))",
                            systemImage: "doc.on.clipboard"
                        )
                    }

                    let truncatedTranscript = appState.lastTranscript.count > 60
                        ? String(appState.lastTranscript.prefix(60)) + "…"
                        : appState.lastTranscript
                    Text("\u{201C}\(truncatedTranscript)\u{201D}")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.primary.opacity(0.045))
                        )
                        .padding(.horizontal, 10)
                        .padding(.top, 2)
                }

                Divider().padding(.vertical, 4)
                sectionLabel("Library")

                // History submenu
                Menu {
                    if recentHistoryItems.isEmpty {
                        Text("No transcripts yet")
                    } else {
                        ForEach(recentHistoryItems) { item in
                            let transcript = transcriptText(for: item)
                            Button {
                                copyTranscriptToPasteboard(transcriptFull(for: item))
                                dismiss()
                            } label: {
                                Text(transcriptSnippet(for: item))
                            }
                            .disabled(transcript.isEmpty)
                        }
                        Divider()
                    }
                    Button("Open Run Log") { openRunLog() }
                } label: {
                    rowLabel("History", systemImage: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .padding(.horizontal, 10)

                PanelRow {
                    if appState.pasteWordToVocabulary() != nil {
                        VocabularyNotificationManager.shared.flashCheckmark()
                    }
                    dismiss()
                } label: {
                    rowLabel("Paste Custom Word to Vocabulary", systemImage: "text.badge.plus")
                }

                Divider().padding(.vertical, 4)
                sectionLabel("Shortcuts")

                // Shortcut submenus
                holdShortcutMenu
                toggleShortcutMenu
                copyAgainShortcutMenu
                microphoneMenu

                Divider().padding(.vertical, 4)
                sectionLabel("App")

                PanelRow {
                    NotificationCenter.default.post(name: .showSetup, object: nil)
                    dismiss()
                } label: {
                    rowLabel("Re-run Setup…", systemImage: "wand.and.stars")
                }

                PanelRow {
                    openSettings()
                } label: {
                    rowLabel("Settings", systemImage: "gearshape")
                }

                PanelRow {
                    Task { await updateManager.checkForUpdates(userInitiated: true) }
                } label: {
                    HStack(spacing: 9) {
                        if updateManager.isChecking {
                            ProgressView().controlSize(.small).frame(width: 18)
                        } else {
                            Image(systemName: "arrow.down.circle").font(.system(size: 13)).frame(width: 18)
                        }
                        Text(updateManager.isChecking ? "Checking for Updates…" : "Check for Updates")
                        Spacer(minLength: 0)
                    }
                }
                .disabled(updateManager.isChecking)

                updateStatusSection

                Divider().padding(.vertical, 2)

                PanelRow(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    rowLabel("Quit \(AppName.displayName)", systemImage: "power", tint: .secondary)
                }
            }
            .padding(10)
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: MenuContentHeightKey.self, value: proxy.size.height)
                }
            )
        }
        .frame(width: Self.panelWidth)
        .frame(height: min(contentHeight, Self.maxPanelHeight))
        .onPreferenceChange(MenuContentHeightKey.self) { newHeight in
            if newHeight > 0 { contentHeight = newHeight }
        }
        .background(MenuWindowResolver { hostWindow = $0 })
    }

    private func warningRow(
        title: String,
        systemImage: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        WarningBanner(title: title, systemImage: systemImage, color: color, action: action)
            .padding(.horizontal, 6)
            .padding(.bottom, 4)
    }

    @ViewBuilder
    private var updateStatusSection: some View {
        if updateManager.updateAvailable {
            switch updateManager.updateStatus {
            case .downloading:
                VStack(spacing: 4) {
                    Text("Downloading update… \(Int((updateManager.downloadProgress ?? 0) * 100))%")
                        .font(.caption.weight(.semibold))
                    ProgressView(value: updateManager.downloadProgress ?? 0)
                        .progressViewStyle(.linear)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)

            case .installing, .readyToRelaunch:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Installing update…")
                        .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)

            default:
                PanelRow {
                    updateManager.showUpdateAlert()
                    dismiss()
                } label: {
                    rowLabel("Update available", systemImage: "arrow.down.circle.fill", tint: .accentColor)
                }
            }
        }
    }

    // MARK: Shortcut submenus

    @ViewBuilder
    private var holdShortcutMenu: some View {
        Menu {
            Button {
                _ = appState.setShortcut(.disabled, for: .hold)
            } label: {
                Text(appState.holdShortcut.isDisabled ? "✓ Disabled" : "  Disabled")
            }

            ForEach(ShortcutPreset.allCases) { preset in
                Button {
                    _ = appState.setShortcut(preset.binding, for: .hold)
                } label: {
                    Text(appState.holdShortcut == preset.binding ? "✓ \(preset.title)" : "  \(preset.title)")
                }
                .disabled(preset.binding == appState.toggleShortcut)
            }

            if let savedCustomShortcut = appState.savedCustomShortcut(for: .hold) {
                Divider()
                Button {
                    _ = appState.setShortcut(savedCustomShortcut, for: .hold)
                } label: {
                    Text(appState.holdShortcut == savedCustomShortcut ? "✓ Custom: \(savedCustomShortcut.displayName)" : "  Custom: \(savedCustomShortcut.displayName)")
                }
                .disabled(savedCustomShortcut == appState.toggleShortcut)
            }

            Divider()
            Button("Customize…") { openSettings(tab: .general) }
        } label: {
            rowLabel("Hold Shortcut", systemImage: "command")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var toggleShortcutMenu: some View {
        Menu {
            Button {
                _ = appState.setShortcut(.disabled, for: .toggle)
            } label: {
                Text(appState.toggleShortcut.isDisabled ? "✓ Disabled" : "  Disabled")
            }

            ForEach(ShortcutPreset.allCases) { preset in
                Button {
                    _ = appState.setShortcut(preset.binding, for: .toggle)
                } label: {
                    Text(appState.toggleShortcut == preset.binding ? "✓ \(preset.title)" : "  \(preset.title)")
                }
                .disabled(preset.binding == appState.holdShortcut)
            }

            if let savedCustomShortcut = appState.savedCustomShortcut(for: .toggle) {
                Divider()
                Button {
                    _ = appState.setShortcut(savedCustomShortcut, for: .toggle)
                } label: {
                    Text(appState.toggleShortcut == savedCustomShortcut ? "✓ Custom: \(savedCustomShortcut.displayName)" : "  Custom: \(savedCustomShortcut.displayName)")
                }
                .disabled(savedCustomShortcut == appState.holdShortcut)
            }

            Divider()
            Button("Customize…") { openSettings(tab: .general) }
        } label: {
            rowLabel("Toggle Shortcut", systemImage: "switch.2")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var copyAgainShortcutMenu: some View {
        Menu {
            Button {
                _ = appState.setShortcut(.disabled, for: .copyAgain)
            } label: {
                Text(appState.copyAgainShortcut.isDisabled ? "✓ Disabled" : "  Disabled")
            }

            ForEach(ShortcutPreset.allCases) { preset in
                Button {
                    _ = appState.setShortcut(preset.binding, for: .copyAgain)
                } label: {
                    Text(appState.copyAgainShortcut == preset.binding ? "✓ \(preset.title)" : "  \(preset.title)")
                }
                .disabled(preset.binding == appState.holdShortcut || preset.binding == appState.toggleShortcut)
            }

            if let savedCustomShortcut = appState.savedCustomShortcut(for: .copyAgain) {
                Divider()
                Button {
                    _ = appState.setShortcut(savedCustomShortcut, for: .copyAgain)
                } label: {
                    Text(appState.copyAgainShortcut == savedCustomShortcut ? "✓ Custom: \(savedCustomShortcut.displayName)" : "  Custom: \(savedCustomShortcut.displayName)")
                }
                .disabled(savedCustomShortcut == appState.holdShortcut || savedCustomShortcut == appState.toggleShortcut)
            }

            Divider()
            Button("Customize…") { openSettings(tab: .general) }
        } label: {
            rowLabel("Paste Again Shortcut", systemImage: "arrow.uturn.backward")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
    }

    @ViewBuilder
    private var microphoneMenu: some View {
        Menu {
            Button {
                appState.selectedMicrophoneID = "default"
            } label: {
                Text(appState.selectedMicrophoneID == "default" || appState.selectedMicrophoneID.isEmpty ? "✓ System Default" : "  System Default")
            }
            ForEach(appState.availableMicrophones) { device in
                Button {
                    appState.selectedMicrophoneID = device.uid
                } label: {
                    Text(appState.selectedMicrophoneID == device.uid ? "✓ \(device.name)" : "  \(device.name)")
                }
            }
        } label: {
            rowLabel("Microphone", systemImage: "mic")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 10)
    }
}
