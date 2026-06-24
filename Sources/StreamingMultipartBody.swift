import Foundation
import os.log

private let uploadLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Upload")

/// Streams a `multipart/form-data` request body to `URLSession` without ever
/// holding the whole body in memory *or* writing a temporary copy to disk.
///
/// The temp-file approach (`makeMultipartBodyFile`) already fixed the peak
/// memory of building the body in RAM, but it still does a full disk
/// round-trip: write the entire multipart body to a `.multipart` temp file,
/// then upload it. This producer removes that disk I/O by feeding the body to
/// `URLSession` lazily as it pulls bytes:
///
///   [in-memory prefix: form fields + file header]
///     -> [audio file, read straight from disk in chunks]
///       -> [in-memory suffix: closing boundary]
///
/// `URLSession`/CFNetwork requires an HTTP body stream that is scheduled on a
/// run loop and emits space-available events, so a passive `InputStream`
/// subclass does not work reliably. Instead we use a connected pair from
/// `Stream.getBoundStreams(...)`: `inputStream` is handed to the request, and a
/// dedicated producer thread writes into the bound `outputStream` whenever
/// space is available. Only one ``chunkSize`` slice is resident at a time.
///
/// The owner must keep a strong reference to the instance for the lifetime of
/// the upload (the producer thread holds a weak reference to `self`).
final class StreamingMultipartBody: NSObject, StreamDelegate {
    /// Hand this to `URLRequest.httpBodyStream`.
    let inputStream: InputStream
    /// Total body length, suitable for the `Content-Length` header.
    let contentLength: Int

    private let outputStream: OutputStream
    private let prefix: Data
    private let suffix: Data
    private let fileURL: URL
    private let chunkSize: Int

    // Producer state (only touched on the producer thread once started).
    private enum Stage { case prefix, file, suffix, done }
    private var stage: Stage = .prefix
    private var pending = Data()
    private var pendingOffset = 0
    private var fileHandle: FileHandle?
    private var thread: Thread?

    init?(prefix: Data, fileURL: URL, suffix: Data, chunkSize: Int = 64 * 1024) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let fileSize = (attributes?[.size] as? NSNumber)?.intValue else { return nil }

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(
            withBufferSize: chunkSize,
            inputStream: &input,
            outputStream: &output
        )
        guard let input, let output else { return nil }

        self.inputStream = input
        self.outputStream = output
        self.prefix = prefix
        self.suffix = suffix
        self.fileURL = fileURL
        self.chunkSize = chunkSize
        self.contentLength = prefix.count + fileSize + suffix.count
        super.init()
    }

    /// Spins up the producer thread that pumps bytes into the bound output
    /// stream. Call once, after handing `inputStream` to the request.
    func start() {
        let thread = Thread { [weak self] in
            guard let self else { return }
            self.outputStream.delegate = self
            self.outputStream.schedule(in: .current, forMode: .default)
            self.outputStream.open()
            // Drive the run loop until the output stream is closed (either
            // because we finished writing the body or URLSession tore down the
            // read side).
            while self.outputStream.streamStatus != .closed && !Thread.current.isCancelled {
                RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }
        thread.name = "com.zachlatta.freeflow.upload.body"
        self.thread = thread
        thread.start()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        guard aStream === outputStream else { return }
        switch eventCode {
        case .hasSpaceAvailable:
            pump()
        case .errorOccurred:
            os_log(.error, log: uploadLog, "streaming body output error: %{public}@",
                   aStream.streamError?.localizedDescription ?? "unknown")
            finish()
        case .endEncountered:
            finish()
        default:
            break
        }
    }

    /// Writes as much of the body as the output stream will currently accept.
    private func pump() {
        if pendingOffset >= pending.count {
            pending = nextChunk()
            pendingOffset = 0
            if pending.isEmpty {
                // Entire body has been written.
                finish()
                return
            }
        }

        let remaining = pending.count - pendingOffset
        let written = pending.withUnsafeBytes { raw -> Int in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return outputStream.write(base + pendingOffset, maxLength: remaining)
        }

        if written > 0 {
            pendingOffset += written
        } else if written < 0 {
            finish()
        }
        // written == 0 means no space right now; wait for the next
        // .hasSpaceAvailable event.
    }

    /// Returns the next slice of the body, advancing through prefix -> file
    /// chunks -> suffix -> done. Returns empty `Data` once fully drained.
    private func nextChunk() -> Data {
        switch stage {
        case .prefix:
            stage = .file
            return prefix
        case .file:
            if fileHandle == nil {
                fileHandle = try? FileHandle(forReadingFrom: fileURL)
            }
            if let handle = fileHandle,
               let chunk = try? handle.read(upToCount: chunkSize),
               !chunk.isEmpty {
                return chunk
            }
            try? fileHandle?.close()
            fileHandle = nil
            stage = .suffix
            return nextChunk()
        case .suffix:
            stage = .done
            return suffix
        case .done:
            return Data()
        }
    }

    private func finish() {
        guard outputStream.streamStatus != .closed else { return }
        outputStream.close()
        outputStream.remove(from: .current, forMode: .default)
        try? fileHandle?.close()
        fileHandle = nil
        thread?.cancel()
    }
}
