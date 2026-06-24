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
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var updateManager = UpdateManager.shared
    @State private var hostWindow: NSWindow?

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
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .frame(width: 18)
                .foregroundStyle(tint)
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
    }

    private var statusLabel: some View {
        Group {
            if appState.isRecording {
                Label("Recording…", systemImage: "record.circle")
                    .foregroundStyle(.red)
            } else if appState.isTranscribing {
                Label(appState.debugStatusMessage, systemImage: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            } else {
                Text(appState.shortcutStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                // Header
                HStack {
                    Text(AppName.displayName)
                        .font(.headline)
                    Spacer()
                    Text("v\(appVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 2)

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
                    Divider().padding(.vertical, 2)

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
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider().padding(.vertical, 2)

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

                Divider().padding(.vertical, 2)

                // Shortcut submenus
                holdShortcutMenu
                toggleShortcutMenu
                copyAgainShortcutMenu
                microphoneMenu

                Divider().padding(.vertical, 2)

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
            .padding(8)
        }
        .frame(width: 300)
        .frame(maxHeight: 620)
        .background(MenuWindowResolver { hostWindow = $0 })
    }

    private func warningRow(
        title: String,
        systemImage: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
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
