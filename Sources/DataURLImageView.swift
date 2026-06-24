import SwiftUI
import AppKit

/// Process-wide cache of decoded screenshot images keyed by their `data:` URL.
/// Decoding base64 screenshots (often hundreds of KB) is expensive, so we keep
/// the resulting `NSImage` around to avoid re-decoding on every SwiftUI render.
final class DataURLImageCache {
    static let shared = DataURLImageCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 32
    }

    func image(forKey key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: NSImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString)
    }
}

/// Returns the decoded byte count of a base64 `data:` URL payload *without*
/// allocating/decoding the data. Used for size labels that previously decoded
/// the entire payload a second time just to count bytes.
func base64PayloadByteCount(forDataURL dataURL: String) -> Int? {
    guard let commaIndex = dataURL.lastIndex(of: ",") else { return nil }
    let base64 = dataURL[dataURL.index(after: commaIndex)...]
    let length = base64.count
    guard length > 0 else { return nil }
    let padding = base64.suffix(2).filter { $0 == "=" }.count
    return (length / 4) * 3 - padding
}

/// Loads an `NSImage` from a base64 `data:` URL off the main thread and caches
/// the result. Centralizes the decode so the UI never blocks the main thread
/// decoding screenshots (the cause of stalls when opening the Run Log / Debug
/// surfaces).
@MainActor
final class DataURLImageLoader: ObservableObject {
    @Published private(set) var image: NSImage?
    private var loadedKey: String?

    func load(_ dataURL: String?) async {
        guard let dataURL, !dataURL.isEmpty else {
            image = nil
            loadedKey = nil
            return
        }

        // Already showing the right image.
        if loadedKey == dataURL, image != nil { return }

        if let cached = DataURLImageCache.shared.image(forKey: dataURL) {
            image = cached
            loadedKey = dataURL
            return
        }

        // Switching to a different, not-yet-decoded image: clear the stale one so
        // the placeholder shows instead of briefly rendering the previous screenshot.
        image = nil
        loadedKey = nil

        let decoded = await Task.detached(priority: .userInitiated) {
            imageFromDataURL(dataURL)
        }.value

        // Guard against the dataURL changing while we were decoding.
        guard !Task.isCancelled else { return }

        if let decoded {
            DataURLImageCache.shared.store(decoded, forKey: dataURL)
        }
        image = decoded
        loadedKey = dataURL
    }
}

/// Displays an image decoded from a base64 `data:` URL, loading it
/// asynchronously and caching the result. `content` receives the decoded
/// `NSImage` (so callers can also wire up copy/open actions); `placeholder` is
/// shown while loading or if decoding fails.
struct DataURLImageView<Content: View, Placeholder: View>: View {
    private let dataURL: String?
    private let content: (NSImage) -> Content
    private let placeholder: () -> Placeholder

    @StateObject private var loader = DataURLImageLoader()

    init(
        dataURL: String?,
        @ViewBuilder content: @escaping (NSImage) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.dataURL = dataURL
        self.content = content
        self.placeholder = placeholder
    }

    var body: some View {
        Group {
            if let image = loader.image {
                content(image)
            } else {
                placeholder()
            }
        }
        .task(id: dataURL) {
            await loader.load(dataURL)
        }
    }
}
