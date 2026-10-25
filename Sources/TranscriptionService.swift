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

    /// Whether the recording should be uploaded as lossless FLAC rather than
    /// WAV. FLAC is ~57% of the WAV's size, which matters when the upload
    /// crosses the internet. Self-hosted servers on loopback/LAN gain nothing
    /// from it, and some (e.g. whisper.cpp's server without `--convert`) only
    /// accept WAV, so those keep WAV. Force WAV everywhere with
    /// `defaults write com.inhaq.fluent upload_audio_format wav`.
    var prefersCompressedUpload: Bool {
        if UserDefaults.standard.string(forKey: "upload_audio_format")?.lowercased() == "wav" {
            return false
        }
        guard let host = baseURL.host?.lowercased() else { return false }
        return !Self.isLocalNetworkHost(host)
    }

    /// True for loopback, link-local, private-range, and mDNS hosts.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }
        if host.contains(":") {
            // IPv6: loopback, unique-local (fc00::/7), link-local (fe80::/10).
            return host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80:")
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254):
            return true
        case (172, 16...31):
            return true
        default:
            return false
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
    /// endpoint via `URLSession`, returning the validated transcript.
    ///
    /// Retries exactly once, and only for **pre-acceptance** failures — cases
    /// where the request provably never reached the provider's processing
    /// pipeline: connection-level `URLError`s (lost network, DNS, unreachable
    /// host) and non-HTTP responses. The session rotates first when the
    /// connection itself is suspect.
    ///
    /// Deliberately NOT retried: timeouts, HTTP 429, and HTTP 5xx. For those,
    /// the provider may have received and processed the audio, so a blind
    /// resend risks duplicate transcription work (and billing) with no
    /// idempotency-key support on these endpoints to prevent it. Permanent
    /// failures (401/403/404/413, malformed requests, parse errors) and
    /// cancellation are also never retried.
    ///
    /// Every attempt constructs a fresh `URLRequest`, multipart boundary, and
    /// body: a consumed `httpBodyStream` cannot be replayed, and a reused
    /// boundary would be invalid across requests anyway.
    ///
    /// The overall budget stays identical to the pre-retry behavior: all
    /// attempts share one deadline equal to ``transcribe(fileURL:)``'s existing
    /// outer timeout race, so two attempts can never stretch a dictation to
    /// 2× the configured timeout. The outer race remains the authoritative cap.
    private func transcribeAudioWithURLSession(fileURL: URL) async throws -> String {
        let url = baseURL
            .appendingPathComponent("audio")
            .appendingPathComponent("transcriptions")
        let deadline = Date().addingTimeInterval(transcriptionTimeoutSeconds)

        var attempt = 0
        while true {
            try Task.checkCancellation()

            attempt += 1
            let boundary = UUID().uuidString
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = transcriptionTimeoutSeconds
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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

                // Never fight our own cancellation or the outer timeout race.
                guard !LLMAPITransport.isCancellation(error), !Task.isCancelled else {
                    throw error
                }

                let decision = Self.retryDecision(for: error)
                guard attempt < Self.maxTranscriptionAttempts, decision.shouldRetry else {
                    throw error
                }

                if decision.rotateSession {
                    LLMAPITransport.rotateSessionAfterConnectionFailure(
                        reason: Self.rotationReason(for: error)
                    )
                }

                // Backoff: provider-requested Retry-After wins over the nominal
                // jittered base delay, both clamped to the remaining overall
                // deadline minus the smallest useful attempt window. No time
                // left means the failure stands — matching today's behavior.
                let nominalDelay = Self.jitteredBaseBackoffSeconds()
                let backoff = max(nominalDelay, decision.retryAfterSeconds ?? 0)
                let minimumUsefulAttemptWindow: TimeInterval = 2
                let remainingBudget = deadline.timeIntervalSinceNow - minimumUsefulAttemptWindow
                guard remainingBudget > 0 else {
                    os_log(.info, log: transcriptionLog, "transcription attempt %ld failed (%{public}@); no deadline budget left for a retry", attempt, error.localizedDescription)
                    throw error
                }
                let delay = min(backoff, remainingBudget)
                os_log(
                    .info,
                    log: transcriptionLog,
                    "transcription attempt %ld failed (%{public}@) — retrying in %.0fms",
                    attempt,
                    error.localizedDescription,
                    delay * 1000
                )
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Maximum number of transcription attempts per dictation: the original
    /// request plus one retry.
    private static let maxTranscriptionAttempts = 2

    /// Nominal backoff between attempts, jittered ±40% so simultaneous
    /// failures across clients don't re-synchronize on the same beat.
    private static func jitteredBaseBackoffSeconds() -> TimeInterval {
        let base = 0.15
        let jitter = Double.random(in: 0.6...1.4)
        return base * jitter
    }

    private struct TranscriptionRetryDecision {
        let shouldRetry: Bool
        let rotateSession: Bool
        let retryAfterSeconds: TimeInterval?
    }

    /// Classifies an upload/transcription failure for the one-shot retry.
    ///
    /// Only **pre-acceptance** failures retry — cases where the request
    /// provably never reached the provider's processing pipeline:
    ///
    /// | Failure                            | Retry | Rotate |
    /// |------------------------------------|-------|--------|
    /// | Connection lost / DNS / cannot-connect | Yes | Yes  |
    /// | Non-HTTP response (no status at all)   | Yes | Yes  |
    /// | Timeout                                | No* | —   |
    /// | HTTP 429 / 5xx                         | No  | No   |
    /// | 401/403/404/413, parse, malformed      | No  | No   |
    /// | Cancellation                           | No  | No   |
    ///
    /// \* A timeout means the provider may already have accepted and processed
    /// the audio; these endpoints have no idempotency key, so resending risks
    /// duplicate work/billing. The dictation surfaces its error instead.
    private static func retryDecision(for error: Error) -> TranscriptionRetryDecision {
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .submissionFailed(_, let statusCode, _):
                guard statusCode == nil else {
                    // Any HTTP response (429/5xx included) proves the provider
                    // received the request — resending could duplicate it.
                    return TranscriptionRetryDecision(shouldRetry: false, rotateSession: false, retryAfterSeconds: nil)
                }
                // Non-HTTP response ("No response from server"): the transport
                // returned something unusable — distrust the connection and
                // retry on a fresh one.
                return TranscriptionRetryDecision(shouldRetry: true, rotateSession: true, retryAfterSeconds: nil)
            default:
                return TranscriptionRetryDecision(shouldRetry: false, rotateSession: false, retryAfterSeconds: nil)
            }
        }

        if let urlError = error as? URLError {
            if urlError.code == .timedOut {
                // Ambiguous acceptance: the request may be processing server-
                // side. Never resend without idempotency support.
                return TranscriptionRetryDecision(shouldRetry: false, rotateSession: false, retryAfterSeconds: nil)
            }
            if isConnectionLevelFailure(urlError) {
                return TranscriptionRetryDecision(shouldRetry: true, rotateSession: true, retryAfterSeconds: nil)
            }
            return TranscriptionRetryDecision(shouldRetry: false, rotateSession: false, retryAfterSeconds: nil)
        }

        return TranscriptionRetryDecision(shouldRetry: false, rotateSession: false, retryAfterSeconds: nil)
    }

    /// Human-readable reason for a session rotation, used in logs.
    private static func rotationReason(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "connection-level failure: \(urlError.code.rawValue)"
        }
        if let transcriptionError = error as? TranscriptionError,
           case .submissionFailed(_, let statusCode, _) = transcriptionError, statusCode == nil {
            return "non-HTTP response from provider"
        }
        return "unclassified connection fault"
    }

    /// Mirrors ``LLMAPITransport/isConnectionLevelFailure(_:)`` for URLError
    /// inputs already narrowed by the caller.
    private static func isConnectionLevelFailure(_ urlError: URLError) -> Bool {
        LLMAPITransport.isConnectionLevelFailure(urlError)
    }

    /// Streamed-body upload (`stream_multipart_upload` user default) that
    /// avoids the multipart temp-file round-trip entirely.
    ///
    /// Off by default: the one-shot `httpBodyStream` has no
    /// `needNewBodyStream` handling, so a URLSession-level redirect or request
    /// replay cannot get a fresh stream. The default temp-file path is fully
    /// replayable. The streaming producer itself is wire-verified (byte-
    /// identical to the temp-file body) and safe to opt into:
    /// `defaults write com.inhaq.fluent stream_multipart_upload -bool true`
    private static var streamingUploadEnabled: Bool {
        let stored = UserDefaults.standard.object(forKey: "stream_multipart_upload")
        return stored as? Bool ?? false
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
    /// success. Non-200 errors carry the status code and any `Retry-After`
    /// header so the retry policy can classify them precisely.
    private func validateTranscriptionResponse(data: Data, response: URLResponse, fileURL: URL) throws -> String {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.submissionFailed(message: "No response from server", statusCode: nil, retryAfterSeconds: nil)
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
            let retryAfter = Self.retryAfterSeconds(from: httpResponse)
            throw TranscriptionError.submissionFailed(
                message: Self.friendlyHTTPMessage(
                    status: httpResponse.statusCode,
                    host: baseURL.host
                ),
                statusCode: httpResponse.statusCode,
                retryAfterSeconds: retryAfter
            )
        }

        return try parseTranscript(from: data)
    }

    /// Parses a `Retry-After` header in seconds form (the only form these
    /// providers emit). Returns nil for absent or unparseable values.
    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let rawValue = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespaces) else {
            return nil
        }
        return TimeInterval(rawValue)
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
        if fileName.lowercased().hasSuffix(".flac") {
            return "audio/flac"
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
    /// The provider answered with a non-200 HTTP response (or nothing usable
    /// at all). `statusCode` is nil when no HTTP response was available.
    /// `retryAfterSeconds` carries a parsed `Retry-After` header for 429s.
    case submissionFailed(message: String, statusCode: Int?, retryAfterSeconds: TimeInterval?)
    case transcriptionFailed(String)
    case transcriptionTimedOut(TimeInterval)
    case pollFailed(String)
    case audioPreparationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let msg): return "Invalid provider URL: \(msg)"
        case .uploadFailed(let msg): return "Upload failed: \(msg)"
        case .submissionFailed(let msg, _, _): return "Submission failed: \(msg)"
        case .transcriptionFailed(let msg): return "Transcription failed: \(msg)"
        case .transcriptionTimedOut(let seconds): return "Transcription timed out after \(Int(seconds))s"
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
