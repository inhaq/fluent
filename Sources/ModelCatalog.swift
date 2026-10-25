import Foundation
import os.log

/// Live list of model IDs offered by the configured OpenAI-compatible
/// provider, fetched from `GET {baseURL}/models`.
///
/// Replaces maintaining a hardcoded list that goes stale every time the
/// provider ships a model. The last successful response per base URL is
/// persisted so the dropdowns stay populated offline and on launch;
/// ``ModelConfiguration/llmModels`` and ``ModelConfiguration/transcriptionModels``
/// are only used before the first successful fetch for a provider.
@MainActor
final class ModelCatalog: ObservableObject {
    static let shared = ModelCatalog()

    enum Status: Equatable {
        case idle
        case loading
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    /// All model IDs per normalized base URL, as last returned by the provider.
    @Published private(set) var modelsByBaseURL: [String: [String]]

    private static let storageKey = "model_catalog_cache_v1"
    /// Opening Settings repeatedly shouldn't refetch; a manual refresh bypasses this.
    private static let minimumRefreshInterval: TimeInterval = 5 * 60
    private var lastFetch: [String: Date] = [:]
    private let log = OSLog(subsystem: "com.inhaq.fluent", category: "ModelCatalog")

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let cached = try? JSONDecoder().decode([String: [String]].self, from: data) {
            modelsByBaseURL = cached
        } else {
            modelsByBaseURL = [:]
        }
    }

    func llmModels(baseURL: String) -> [String] {
        let ids = modelsByBaseURL[Self.normalize(baseURL)] ?? ModelConfiguration.llmModels
        return ids.filter(Self.isChatModel)
    }

    func transcriptionModels(baseURL: String) -> [String] {
        guard let ids = modelsByBaseURL[Self.normalize(baseURL)] else {
            return ModelConfiguration.transcriptionModels
        }
        return ids.filter(Self.isTranscriptionModel)
    }

    func hasLiveModels(baseURL: String) -> Bool {
        modelsByBaseURL[Self.normalize(baseURL)] != nil
    }

    /// Fetches the model lists for the chat provider and, when it differs,
    /// the transcription provider. Failures leave the cached lists untouched.
    func refresh(
        baseURL: String,
        apiKey: String,
        transcriptionBaseURL: String,
        transcriptionAPIKey: String,
        force: Bool = false
    ) async {
        var targets = [(baseURL, apiKey)]
        if Self.normalize(transcriptionBaseURL) != Self.normalize(baseURL) {
            targets.append((transcriptionBaseURL, transcriptionAPIKey))
        }

        let due = targets.filter { target in
            guard !force, let last = lastFetch[Self.normalize(target.0) + "|" + target.1] else { return true }
            return Date().timeIntervalSince(last) >= Self.minimumRefreshInterval
        }
        guard !due.isEmpty else { return }

        status = .loading
        defer { if status == .loading { status = .idle } }
        var failure: String?
        for (url, key) in due {
            do {
                let ids = try await Self.fetchModelIDs(baseURL: url, apiKey: key)
                guard !Task.isCancelled else { return }
                modelsByBaseURL[Self.normalize(url)] = ids
                lastFetch[Self.normalize(url) + "|" + key] = Date()
            } catch {
                if Task.isCancelled || LLMAPITransport.isCancellation(error) { return }
                os_log(.error, log: log, "model list fetch failed for %{public}@: %{public}@", url, error.localizedDescription)
                failure = failure ?? error.localizedDescription
            }
        }
        persist()
        status = failure.map(Status.failed) ?? .idle
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(modelsByBaseURL) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    // MARK: - Fetching

    private struct ModelsResponse: Decodable {
        struct Model: Decodable {
            let id: String
            /// Groq-specific; absent on most other providers.
            let active: Bool?
        }
        let data: [Model]
    }

    private enum FetchError: LocalizedError {
        case invalidURL
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "The API base URL is not a valid URL."
            case .http(401), .http(403):
                return "The provider rejected the API key."
            case .http(let code):
                return "The provider returned HTTP \(code)."
            }
        }
    }

    private static func fetchModelIDs(baseURL: String, apiKey: String) async throws -> [String] {
        guard let url = URL(string: normalize(baseURL) + "/models") else {
            throw FetchError.invalidURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // Local providers (Ollama, LM Studio) serve /models without a key.
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await LLMAPITransport.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw FetchError.http(http.statusCode)
        }
        let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
        return Set(decoded.data.filter { $0.active ?? true }.map(\.id)).sorted()
    }

    // MARK: - Classification

    private static func normalize(_ baseURL: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.isEmpty ? AppState.defaultAPIBaseURL : trimmed
    }

    static func isTranscriptionModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        return lowered.contains("whisper") || lowered.contains("transcribe")
    }

    /// Models that can't do chat completions (speech, safety classifiers,
    /// embeddings, images) are hidden from the text-model dropdowns.
    static func isChatModel(_ id: String) -> Bool {
        let lowered = id.lowercased()
        if isTranscriptionModel(lowered) { return false }
        let nonChatMarkers = ["tts", "orpheus", "prompt-guard", "embed", "moderation", "dall-e"]
        return !nonChatMarkers.contains { lowered.contains($0) }
    }
}
