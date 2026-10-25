import Foundation
import os.log

enum LLMAPITransport {
    /// Holder for the one session every provider request goes through:
    /// transcription uploads, post-processing, context, and model listing.
    ///
    /// Sharing a single session lets the upload and the post-processing call
    /// that follows it reuse the same pooled (HTTP/2-multiplexed) connection
    /// to the provider, so a dictation pays TCP+TLS setup (~100–300 ms) at
    /// most once instead of once per request kind. ``prewarmConnection(baseURL:apiKey:)``
    /// moves even that one-off cost off the release-to-paste path.
    ///
    /// The session is swapped only when there is evidence the *connection
    /// itself* failed (see ``isConnectionLevelFailure(_:)``); a valid HTTP
    /// response — even 429/5xx — proves the connection works, so HTTP-status
    /// errors never rotate.
    ///
    /// Rotation retires the old session with `finishTasksAndInvalidate()`:
    /// in-flight tasks on it finish undisturbed, and it is never reused for
    /// new work. `invalidateAndCancel()` is deliberately avoided — it would
    /// kill unrelated requests that happen to share the session.
    private static let sessionStateLock = NSLock()
    private static var sessionStorage: URLSession = makeEphemeralSession()
    private static var sessionGeneration = 0
    /// Last prewarm per host, so back-to-back dictations don't each fire one
    /// while the pooled connection is still demonstrably warm.
    private static var lastPrewarmByHost: [String: Date] = [:]
    private static let prewarmThrottleInterval: TimeInterval = 15

    /// Returns the current shared session. Callers must treat it as
    /// read-only; rotation happens exclusively through
    /// ``rotateSessionAfterConnectionFailure(reason:)`` so an in-flight request
    /// can never have its session invalidated underneath it by a concurrent
    /// retry path.
    private static func currentSession() -> URLSession {
        sessionStateLock.lock()
        defer { sessionStateLock.unlock() }
        return sessionStorage
    }

    /// Swaps in a fresh shared session after a connection-level failure and
    /// retires the previous one. The retired session finishes its existing
    /// tasks before invalidating, so a concurrently in-flight request on the
    /// old generation completes normally.
    static func rotateSessionAfterConnectionFailure(reason: String) {
        sessionStateLock.lock()
        let oldSession = sessionStorage
        sessionGeneration += 1
        let generation = sessionGeneration
        sessionStorage = makeEphemeralSession()
        // The new session has no pooled connections, so any prewarm recorded
        // against the old one no longer holds.
        lastPrewarmByHost.removeAll()
        sessionStateLock.unlock()
        os_log(
            .info,
            log: transportLog,
            "rotating shared session (generation %ld → %ld): %{public}@",
            generation - 1,
            generation,
            reason
        )
        oldSession.finishTasksAndInvalidate()
    }

    /// Opens a pooled connection to `baseURL`'s host ahead of need, so the
    /// transcription upload and post-processing call that follow a dictation
    /// start on a warm TCP+TLS connection instead of paying the handshake
    /// after the user releases the key.
    ///
    /// Fire-and-forget: issues a low-priority authenticated `GET /models` (the
    /// same lightweight endpoint key validation uses) and ignores the outcome
    /// — any response at all leaves a connection in the session's pool.
    /// Throttled per host, and never retried or used to rotate the session.
    static func prewarmConnection(baseURL: String, apiKey: String) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let base = URL(string: trimmedBaseURL),
              let scheme = base.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = base.host?.lowercased(), !host.isEmpty else {
            return
        }

        let now = Date()
        sessionStateLock.lock()
        if let last = lastPrewarmByHost[host], now.timeIntervalSince(last) < prewarmThrottleInterval {
            sessionStateLock.unlock()
            return
        }
        lastPrewarmByHost[host] = now
        let session = sessionStorage
        sessionStateLock.unlock()

        var request = URLRequest(url: base.appendingPathComponent("models"))
        request.timeoutInterval = 5
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedKey.isEmpty {
            request.setValue("Bearer \(trimmedKey)", forHTTPHeaderField: "Authorization")
        }

        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                os_log(.debug, log: transportLog, "prewarm to %{public}@ failed: %{public}@", host, error.localizedDescription)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                os_log(.debug, log: transportLog, "prewarm to %{public}@ done (HTTP %ld)", host, status)
            }
        }
        task.priority = URLSessionTask.lowPriority
        task.resume()
    }

    /// True only for failures that indicate the connection or transport is
    /// broken and should not be trusted for the next attempt: lost network,
    /// DNS failure, unreachable host, connection dropped mid-flight.
    ///
    /// Deliberately excludes:
    /// - HTTP status errors (a response proves the connection is healthy),
    /// - `URLError.cancelled` (our own cancellation, not a connection fault),
    /// - `URLError.timedOut` callers handle separately — a timeout usually
    ///   means server-side slowness, but the socket may be poisoned by a half-
    ///   written request, so the retry policy rotates as well (cheap: one
    ///   handshake) while still treating it as retryable.
    static func isConnectionLevelFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .networkConnectionLost,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .dataNotAllowed,
             .internationalRoamingOff,
             .resourceUnavailable,
             .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid:
            return true
        default:
            return false
        }
    }

    /// True when the error is our own cancellation rather than a transport
    /// fault — must never trigger rotation or retry.
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private static let transportLog = OSLog(subsystem: "com.inhaq.fluent", category: "Transport")

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        do {
            return try await currentSession().data(for: request)
        } catch {
            // These callers don't retry, but the next dictation's upload
            // would otherwise inherit the same broken pooled connection.
            if isConnectionLevelFailure(error) {
                rotateSessionAfterConnectionFailure(reason: "request failed: \((error as? URLError)?.code.rawValue ?? 0)")
            }
            throw error
        }
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        try await currentSession().upload(for: request, from: bodyData)
    }

    static func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        try await currentSession().upload(for: request, fromFile: fileURL)
    }

    /// Sends a request whose body is provided by `request.httpBodyStream`
    /// (see ``StreamingMultipartBody``). `URLSession.data(for:)` consumes the
    /// request's body stream, so this streams the multipart body to the server
    /// without buffering it in memory or on disk. Uses the shared persistent
    /// session for connection reuse.
    static func uploadStreaming(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await currentSession().data(for: request)
    }
}
