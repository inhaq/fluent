import Foundation

enum LLMAPITransport {
    private static let requestSession: URLSession = {
        makeEphemeralSession()
    }()

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    static func data(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        try await requestSession.data(for: request)
    }

    static func upload(
        for request: URLRequest,
        from bodyData: Data
    ) async throws -> (Data, URLResponse) {
        // Use a fresh session for each upload so a bad reused connection cannot
        // poison subsequent transcription uploads.
        let session = makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: bodyData)
    }

    static func upload(
        for request: URLRequest,
        fromFile fileURL: URL
    ) async throws -> (Data, URLResponse) {
        // Use a fresh session for each upload so a bad reused connection cannot
        // poison subsequent transcription uploads.
        let session = makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, fromFile: fileURL)
    }

    /// Sends a request whose body is provided by `request.httpBodyStream`
    /// (see ``StreamingMultipartBody``). `URLSession.data(for:)` consumes the
    /// request's body stream, so this streams the multipart body to the server
    /// without buffering it in memory or on disk. Uses a fresh ephemeral
    /// session for the same connection-isolation reason as the file upload.
    static func uploadStreaming(
        for request: URLRequest
    ) async throws -> (Data, URLResponse) {
        let session = makeEphemeralSession()
        defer { session.finishTasksAndInvalidate() }
        return try await session.data(for: request)
    }
}
