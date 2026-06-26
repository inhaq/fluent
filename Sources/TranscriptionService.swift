import Foundation
import os.log

private let transcriptionLog = OSLog(subsystem: "com.inhaq.fluent", category: "Transcription")

class TranscriptionService {
    private let apiKey: String
    private let baseURL: URL
    private let transcriptionModel: String
    private let language: String?
    /// Optional biasing prompt sent to Whisper. Whisper uses this as a hint for
    /// spelling and rare/domain terms (names, jargon, acronyms), which sharply
    /// improves accuracy on the user's custom vocabulary. Capped to Whisper's
    /// ~224-token context window (see `init`).
    private let prompt: String?
    private let transcriptionResponseFormat = "verbose_json"
    private var transcriptionTimeoutSeconds: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "transcription_timeout_seconds")
        return override > 0 ? override : 20
    }

    /// Creates a transcription client for an OpenAI-compatible
    /// `audio/transcriptions` endpoint.
    /// - Parameters:
    ///   - apiKey: Bearer token for the provider.
    ///   - baseURL: Provider base URL; normalized and validated.
    ///   - transcriptionModel: Whisper model id (defaults to `whisper-large-v3`).
    ///   - language: Optional ISO language hint; `nil` lets Whisper auto-detect.
    ///   - prompt: Optional biasing prompt (e.g. custom vocabulary) trimmed and
    ///     capped to ~800 characters to stay within Whisper's context window.
    init(
        apiKey: String,
        baseURL: String = "https://api.groq.com/openai/v1",
        transcriptionModel: String = "whisper-large-v3",
        language: String? = nil,
        prompt: String? = nil
    ) throws {
        self.apiKey = apiKey
        self.baseURL = try Self.normalizedBaseURL(from: baseURL)
        let trimmedModel = transcriptionModel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcriptionModel = trimmedModel.isEmpty ? "whisper-large-v3" : trimmedModel
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.language = (trimmedLanguage?.isEmpty == false) ? trimmedLanguage : nil
        // Whisper's prompt window is ~224 tokens. Trim to a safe character
        // budget so a large vocabulary list never overflows or gets rejected.
        let trimmedPrompt = prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedPrompt, !trimmedPrompt.isEmpty {
            self.prompt = String(trimmedPrompt.prefix(800))
        } else {
            self.prompt = nil
        }
    }

    // Validate API key by hitting a lightweight endpoint
    /// Validates an API key by issuing a lightweight authenticated request to
    /// the provider's `models` endpoint. Returns `true` only on HTTP 200.
    static func validateAPIKey(_ key: String, baseURL: String = "https://api.groq.com/openai/v1") async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard let baseURL = try? normalizedBaseURL(from: baseURL) else { return false }

        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        request.timeoutInterval = 10
        request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await LLMAPITransport.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return status == 200
        } catch {
            return false
        }
    }

    /// Uploads the recorded audio file for transcription and returns the
    /// transcribed text, racing the request against a configurable timeout and
    /// honoring cancellation.
    func transcribe(fileURL: URL) async throws -> String {
        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let timeoutSeconds = transcriptionTimeoutSeconds
        let raceState = TranscriptionTimeoutRaceState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                raceState.setContinuation(continuation)

                let transcriptionTask = Task { [weak self] in
                    do {
                        guard let self else {
                            throw TranscriptionError.transcriptionFailed("Transcription service deallocated")
                        }
                        let result = try await self.transcribeAudio(fileURL: fileURL)
                        raceState.finish(.success(result))
                    } catch {
                        raceState.finish(.failure(Self.transcriptionTimeoutErrorIfNeeded(
                            error,
                            timeoutSeconds: timeoutSeconds
                        )))
                    }
                }

                let timeoutTask = Task {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                        raceState.finish(.failure(TranscriptionError.transcriptionTimedOut(timeoutSeconds)))
                    } catch is CancellationError {
                    } catch {
                        raceState.finish(.failure(error))
                    }
                }

                raceState.setTasks([transcriptionTask, timeoutTask])
            }
        } onCancel: {
            raceState.cancel()
        }
    }

    /// Performs the underlying transcription request for the given audio file.
    private func transcribeAudio(fileURL: URL) async throws -> String {
        return try await transcribeAudioWithURLSession(fileURL: fileURL)
    }

    /// Issues the multipart upload to the provider's `audio/transcriptions`
    /// endpoint via `URLSession` and returns the validated transcript.
    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = transcriptionTimeoutSeconds
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        do {
            let (data, response): (Data, URLResponse)
            if Self.streamingUploadEnabled {
                (data, response) = try await uploadStreamed(
                    request: request,
                    audioFileURL: fileURL,
                    boundary: boundary
                )
            } else {
                (data, response) = try await uploadViaTempFile(
                    request: request,
                    audioFileURL: fileURL,
                    boundary: boundary
                )
            }
            return try validateTranscriptionResponse(data: data, response: response, fileURL: fileURL)
        } catch {
            let nsError = error as NSError
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload failed for %{public}@ (bytes=%{public}lld): domain=%{public}@ code=%ld desc=%{public}@",
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL),
                nsError.domain,
                nsError.code,
                error.localizedDescription
            )
            throw error
        }
    }

    /// Opt-in (`stream_multipart_upload` user default) streamed-body upload that
    /// avoids the multipart temp file entirely. Off by default so the proven
    /// file-upload path remains the standard.
    private static var streamingUploadEnabled: Bool {
        UserDefaults.standard.bool(forKey: "stream_multipart_upload")
    }

    /// Builds the multipart body on disk and uploads it from the file. This is
    /// the default, most-reliable path (`URLSession.upload(fromFile:)`).
    private func uploadViaTempFile(
        request: URLRequest,
        audioFileURL: URL,
        boundary: String
    ) async throws -> (Data, URLResponse) {
        let multipartFileURL = try makeMultipartBodyFile(
            audioFileURL: audioFileURL,
            fileName: audioFileURL.lastPathComponent,
            model: transcriptionModel,
            responseFormat: transcriptionResponseFormat,
            language: language,
            prompt: prompt,
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: multipartFileURL)
        }
        return try await LLMAPITransport.upload(for: request, fromFile: multipartFileURL)
    }

    /// Streams the multipart body to the server with neither a full in-memory
    /// copy nor a temp file (see ``StreamingMultipartBody``).
    private func uploadStreamed(
        request: URLRequest,
        audioFileURL: URL,
        boundary: String
    ) async throws -> (Data, URLResponse) {
        let prefix = multipartPrefixData(
            fileName: audioFileURL.lastPathComponent,
            model: transcriptionModel,
            responseFormat: transcriptionResponseFormat,
            language: language,
            prompt: prompt,
            boundary: boundary
        )
        let suffix = multipartSuffixData(boundary: boundary)

        guard let body = StreamingMultipartBody(
            prefix: prefix,
            fileURL: audioFileURL,
            suffix: suffix
        ) else {
            // Fall back to the reliable temp-file path if the audio file can't
            // be sized/streamed for some reason.
            return try await uploadViaTempFile(
                request: request,
                audioFileURL: audioFileURL,
                boundary: boundary
            )
        }

        var streamingRequest = request
        streamingRequest.httpBodyStream = body.inputStream
        streamingRequest.setValue(String(body.contentLength), forHTTPHeaderField: "Content-Length")
        body.start()
        // Always tear the producer down, even if the upload throws or the task
        // is cancelled. `cancel()` is thread-safe and idempotent, so the normal
        // end-of-stream shutdown still wins on the success path.
        defer { body.cancel() }

        return try await LLMAPITransport.uploadStreaming(for: streamingRequest)
    }

    /// Validates the HTTP response from a transcription upload, mapping
    /// non-200 statuses to user-readable errors, and parses the transcript on
    /// success.
    private func validateTranscriptionResponse(data: Data, response: URLResponse, fileURL: URL) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed("No response from server")
        }

        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: data, encoding: .utf8) ?? ""
            os_log(
                .error,
                log: transcriptionLog,
                "URLSession upload returned HTTP %ld for %{public}@ (bytes=%{public}lld) body=%{public}@",
                httpResponse.statusCode,
                fileURL.lastPathComponent,
                fileSizeBytes(for: fileURL),
                responseBody
            )
            throw TranscriptionError.submissionFailed(Self.friendlyHTTPMessage(
                status: httpResponse.statusCode,
                host: baseURL.host
            ))
        }

        return try parseTranscript(from: data)
    }
    /// Returns the MIME content type for a given audio file name based on its
    /// extension, defaulting to `audio/mp4`.
    private func audioContentType(for fileName: String) -> String {
        if fileName.lowercased().hasSuffix(".wav") {
            return "audio/wav"
        }
        if fileName.lowercased().hasSuffix(".mp3") {
            return "audio/mpeg"
        }
        if fileName.lowercased().hasSuffix(".m4a") {
            return "audio/mp4"
        }
        return "audio/mp4"
    }

    /// Returns the size of the file at `fileURL` in bytes, or `-1` if it cannot
    /// be determined.
    private func fileSizeBytes(for fileURL: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? -1
    }

    /// Builds the multipart body on disk instead of in memory. A recorded WAV
    /// can be many MB; reading it into `Data` and then appending it into a
    /// second multipart `Data` doubles peak memory during the critical
    /// transcribe-after-stop path.
    private func makeMultipartBodyFile(
        audioFileURL: URL,
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        prompt: String?,
        boundary: String
    ) throws -> URL {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".multipart")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let output = try FileHandle(forWritingTo: outputURL)
        defer {
            try? output.close()
        }

        try output.write(contentsOf: multipartPrefixData(
            fileName: fileName,
            model: model,
            responseFormat: responseFormat,
            language: language,
            prompt: prompt,
            boundary: boundary
        ))
        try appendFile(audioFileURL, to: output)
        try output.write(contentsOf: multipartSuffixData(boundary: boundary))

        return outputURL
    }

    /// The multipart body up to (and including) the file part's header, i.e.
    /// everything that precedes the raw audio bytes. Shared by the temp-file
    /// and streamed upload paths so both produce a byte-identical body.
    private func multipartPrefixData(
        fileName: String,
        model: String,
        responseFormat: String,
        language: String?,
        prompt: String?,
        boundary: String
    ) -> Data {
        var body = ""

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"model\"\r\n\r\n"
        body += "\(model)\r\n"

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"response_format\"\r\n\r\n"
        body += "\(responseFormat)\r\n"

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"temperature\"\r\n\r\n"
        body += "0\r\n"

        if let language, !language.isEmpty {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"language\"\r\n\r\n"
            body += "\(language)\r\n"
        }

        if let prompt, !prompt.isEmpty {
            body += "--\(boundary)\r\n"
            body += "Content-Disposition: form-data; name=\"prompt\"\r\n\r\n"
            body += "\(prompt)\r\n"
        }

        body += "--\(boundary)\r\n"
        body += "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n"
        body += "Content-Type: \(audioContentType(for: fileName))\r\n\r\n"

        return Data(body.utf8)
    }

    /// The multipart body that follows the raw audio bytes (the closing
    /// boundary).
    private func multipartSuffixData(boundary: String) -> Data {
        Data("\r\n--\(boundary)--\r\n".utf8)
    }

    private func appendFile(_ sourceURL: URL, to output: FileHandle) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer {
            try? input.close()
        }

        while true {
            let chunk = try input.read(upToCount: 1024 * 1024) ?? Data()
            guard !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
        }
    }

    /// Map a non-200 HTTP status into a one-line user-readable message.
    /// Used for transcription submission failures so the menu bar shows
    /// "Invalid API key for api.openai.com" instead of raw JSON.
    static func friendlyHTTPMessage(status: Int, host: String?) -> String {
        let provider = host ?? "the provider"
        switch status {
        case 401:
            return "Invalid API key for \(provider). Open Settings to fix it."
        case 403:
            return "Key lacks permission for this endpoint at \(provider) (HTTP 403). Check the key's scopes."
        case 404:
            return "Endpoint not found at \(provider) (HTTP 404). Base URL is likely wrong for this provider."
        case 413:
            return "Audio file too large for \(provider) (HTTP 413). Try a shorter recording."
        case 429:
            return "Rate limit reached at \(provider) (HTTP 429). Wait a moment and try again."
        case 500..<600:
            return "Provider error at \(provider) (HTTP \(status)). Try again in a moment."
        default:
            return "Request failed at \(provider) (HTTP \(status))."
        }
    }

    private static func transcriptionTimeoutErrorIfNeeded(
        _ error: Error,
        timeoutSeconds: TimeInterval
    ) -> Error {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return TranscriptionError.transcriptionTimedOut(timeoutSeconds)
        }
        return error
    }

    private static func normalizedBaseURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL is empty.")
        }

        guard var components = URLComponents(string: trimmed) else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        guard let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw TranscriptionError.invalidBaseURL("Provider URL must use http or https.")
        }

        guard let host = components.host, !host.isEmpty else {
            throw TranscriptionError.invalidBaseURL("Provider URL must include a host.")
        }

        components.scheme = scheme
        if components.path == "/" {
            components.path = ""
        } else {
            components.path = components.path.replacingOccurrences(
                of: "/+$",
                with: "",
                options: .regularExpression
            )
        }

        guard let normalizedURL = components.url else {
            throw TranscriptionError.invalidBaseURL("Provider URL is malformed.")
        }

        return normalizedURL
    }

    // MARK: Robust transcript filtering (Whisper paper, §4.5 "Decoding")
    //
    // Whisper ("Robust Speech Recognition via Large-Scale Weak Supervision")
    // is an encoder–decoder transformer trained with weak supervision; its
    // characteristic failure mode is hallucinating text on silent/low-speech
    // audio. The paper's robust-decoding heuristics identify a failed /
    // non-speech segment from three per-segment signals that the provider
    // returns in verbose_json:
    //   - no_speech_prob   : probability the segment contains no speech
    //   - avg_logprob      : mean token log-probability (model confidence)
    //   - compression_ratio: gzip ratio of the text (high => repetitive/looped)
    //
    // Applying the paper's defaults (no_speech > 0.6, avg_logprob < -1.0,
    // compression_ratio > 2.4) drops hallucinated segments while preserving
    // genuine — even quiet, lower-confidence — speech. This generalizes far
    // beyond a hardcoded phrase list: a hallucination is caught by its
    // statistics, and a real utterance (speech detected, reasonable confidence,
    // low repetition) is kept regardless of the exact words.
    private let noSpeechThreshold = 0.6
    private let logProbThreshold = -1.0
    private let compressionRatioThreshold = 2.4

    // Secondary net for phrases Whisper notoriously emits on silence. Only used
    // to drop a segment that ALSO looks non-speech (moderate no_speech_prob),
    // so a genuine "thank you" / "you" is never discarded.
    private let hallucinationPhrases: Set<String> = [
        "thank you",
        "thank you for watching",
        "thank you very much",
        "thank you so much",
        "thanks for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitles by the amara.org community",
        "you"
    ]

    private struct WhisperSegment {
        let text: String
        let avgLogprob: Double
        let compressionRatio: Double
        let noSpeechProb: Double
    }

    /// Parses the transcript from a provider response. For `verbose_json` with
    /// segments we apply the Whisper paper's robust-decoding heuristics to drop
    /// hallucinated/non-speech segments; otherwise we fall back to the raw text.
    private func parseTranscript(from data: Data) throws -> String {
        if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            if let segments = json["segments"] as? [[String: Any]], !segments.isEmpty {
                return filteredTranscript(fromSegments: segments)
            }
            if let text = json["text"] as? String {
                // No per-segment metadata available: return the text unfiltered
                // rather than risk dropping real speech with a blunt phrase match.
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let plainText = String(data: data, encoding: .utf8) ?? ""
        let text = plainText
                .components(separatedBy: .newlines)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.pollFailed("Invalid response")
        }

        return text
    }

    /// Rebuilds the transcript from Whisper segments, discarding those the
    /// paper's heuristics flag as hallucination / non-speech. Segments missing
    /// metrics are treated as speech (kept) so we never over-filter.
    private func filteredTranscript(fromSegments rawSegments: [[String: Any]]) -> String {
        let segments = rawSegments.map { segment in
            WhisperSegment(
                text: segment["text"] as? String ?? "",
                avgLogprob: segment["avg_logprob"] as? Double ?? 0,
                compressionRatio: segment["compression_ratio"] as? Double ?? 0,
                noSpeechProb: segment["no_speech_prob"] as? Double ?? 0
            )
        }

        let kept = segments.filter { !isHallucinatedSegment($0) }
        // Whisper doesn't guarantee each segment's text carries its own leading
        // space, so trim each one and join with a single space to avoid merging
        // words across segment boundaries (and to collapse incidental padding).
        let rebuilt = kept
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return rebuilt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Applies the Whisper paper's robust-decoding signals to decide whether a
    /// single segment is a hallucination / non-speech and should be dropped.
    private func isHallucinatedSegment(_ segment: WhisperSegment) -> Bool {
        // Paper's non-speech rule: confidently non-speech AND low confidence.
        if segment.noSpeechProb > noSpeechThreshold && segment.avgLogprob < logProbThreshold {
            return true
        }

        // Repetition/looping hallucination: a high gzip ratio with low model
        // confidence. (The provider already does the paper's temperature
        // fallback, so a still-high compression ratio signals real gibberish.)
        if segment.compressionRatio > compressionRatioThreshold && segment.avgLogprob < -0.5 {
            return true
        }

        // Secondary phrase net for the classic silence hallucinations, gated on
        // a moderate no_speech_prob so genuine short utterances survive.
        let normalized = segment.text
            .lowercased()
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
        if hallucinationPhrases.contains(normalized) && segment.noSpeechProb > 0.5 {
            return true
        }

        return false
    }
}

enum TranscriptionError: LocalizedError {
    case invalidBaseURL(String)
    case uploadFailed(String)
    case submissionFailed(String)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let msg): return "Invalid provider URL: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg): return "Submission failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .pollFailed(let msg): return "Polling failed: \(msg)"
        case .audioPreparationFailed(let msg): return "Audio preparation failed: \(msg)"
        }
    }
}

private final class TranscriptionTimeoutRaceState {
    private let lock = NSLock()
    private var didFinish = false
    private var continuation: CheckedContinuation<String, Error>?
    private var tasks: [Task<Void, Never>] = []

    func setContinuation(_ continuation: CheckedContinuation<String, Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        if didFinish {
            lock.unlock()
            tasks.forEach { $0.cancel() }
            return
        }

        self.tasks = tasks
        lock.unlock()
    }

    func finish(_ result: Result<String, Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()

        tasks.forEach { $0.cancel() }

        switch result {
        case .success(let value):
            continuation?.resume(returning: value)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }
}

private struct PreparedUploadAudio {
    let fileURL: URL
    let deleteOnCleanup: Bool

    func cleanup() {
        guard deleteOnCleanup else { return }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
