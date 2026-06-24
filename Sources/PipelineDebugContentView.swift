import SwiftUI
import AppKit

func imageFromDataURL(_ dataURL: String) -> NSImage? {
    guard let data = base64ImageData(fromDataURL: dataURL) else { return nil }
    return NSImage(data: data)
}

struct PipelineDebugContentView: View {
    let statusMessage: String
    let postProcessingStatus: String
    let contextSummary: String
    let contextScreenshotStatus: String
    let contextScreenshotDataURL: String?
    let rawTranscript: String
    let postProcessedTranscript: String
    let postProcessingPrompt: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !statusMessage.isEmpty {
                debugRow(title: "Status", value: statusMessage)
            }

            if !postProcessingStatus.isEmpty {
                debugRow(title: "Post-Processing", value: postProcessingStatus)
            }

            if !postProcessingPrompt.isEmpty {
                debugRow(title: "Post-Processing Prompt", value: postProcessingPrompt, copyText: postProcessingPrompt)
            }

            if !contextSummary.isEmpty {
                debugRow(title: "Context", value: contextSummary)
            }

            if !contextScreenshotStatus.isEmpty || contextScreenshotDataURL != nil {
                screenshotSection(
                    status: contextScreenshotStatus,
                    dataURL: contextScreenshotDataURL
                )
            }

            if !rawTranscript.isEmpty {
                debugRow(title: "Raw Transcript", value: rawTranscript, copyText: rawTranscript)
            }

            if !postProcessedTranscript.isEmpty {
                debugRow(title: "Post-Processed Transcript", value: postProcessedTranscript, copyText: postProcessedTranscript)
            }

            if contextSummary.isEmpty && rawTranscript.isEmpty && postProcessedTranscript.isEmpty && postProcessingPrompt.isEmpty {
                Text("No debug data for this entry.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func debugRow(title: String, value: String, copyText: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.body.bold())
            ScrollView {
                Text(value)
                    .textSelection(.enabled)
                    .font(.system(size: 15, weight: .regular, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            .padding(10)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))

            if let copyText {
                Button("Copy \(title)") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                }
                .font(.body)
            }
        }
    }

    private func screenshotSection(status: String, dataURL: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Context Screenshot")
                .font(.body.bold())
            Text("Status: \(status)")
                .font(.caption)
                .foregroundStyle(isScreenshotUnavailable(status) ? .red : .secondary)

            if let dataURL {
                // Decode off the main thread and cache the result so opening or
                // re-rendering this panel never stalls the UI decoding the
                // base64 payload.
                DataURLImageView(dataURL: dataURL) { image in
                    loadedScreenshot(image: image, dataURL: dataURL)
                } placeholder: {
                    screenshotBox {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading screenshot…")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
            } else {
                screenshotBox {
                    Text("No screenshot image available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func loadedScreenshot(image: NSImage, dataURL: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, minHeight: 180, maxHeight: 320, alignment: .center)
                    .padding(10)
            }
            .frame(maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))

            if let payloadBytes = base64PayloadByteCount(forDataURL: dataURL) {
                Text("Screenshot payload: \(payloadBytes / 1024) KB (Base64)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button("Open in Preview") {
                    openImageInPreview(image)
                }
                .font(.body)

                Button("Copy Screenshot") {
                    copyImageToPasteboard(image)
                }
                .font(.body)
            }
        }
    }

    private func screenshotBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
    }

    private func isScreenshotUnavailable(_ status: String) -> Bool {
        let lowered = status.lowercased()
        return lowered.contains("could not") || lowered.contains("no screenshot") || lowered.contains("not available")
    }

    private func openImageInPreview(_ image: NSImage) {
        guard let imageData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: imageData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            return
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voice-to-text-context-screenshot.png", isDirectory: false)
        do {
            try pngData.write(to: tempURL)
            NSWorkspace.shared.open(tempURL)
        } catch {
            return
        }
    }

    private func copyImageToPasteboard(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }
}
