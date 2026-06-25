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

    /// Guards `isFinished` so shutdown can be requested safely from any thread.
    private let lock = NSLock()
    private var isFinished = false

    init?(prefix: Data, fileURL: URL, suffix: Data, chunkSize: Int = 64 * 1024) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        // In Swift, `NSNumber.intValue` maps to Objective-C `integerValue`
        // (`NSInteger`), which is `Int` (64-bit on macOS), so it doesn't
        // truncate large file sizes when computing `Content-Length`.
        guard let fileSize = (attributes?[.size] as? NSNumber)?.intValue else { return nil }

        // Open the file up front so a read failure surfaces here and the caller
        // can fall back to the temp-file path, instead of silently sending a
        // truncated body that still advertises the full `Content-Length`.
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }

        var input: InputStream?
        var output: OutputStream?
        Stream.getBoundStreams(
            withBufferSize: chunkSize,
            inputStream: &input,
            outputStream: &output
        )
        guard let input, let output else {
            try? handle.close()
            return nil
        }

        self.inputStream = input
        self.outputStream = output
        self.prefix = prefix
        self.suffix = suffix
        self.fileURL = fileURL
        self.chunkSize = chunkSize
        self.fileHandle = handle
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
    /// Keeps draining within a single `.hasSpaceAvailable` event: a partial
    /// write (or a short prefix chunk) does not necessarily trigger another
    /// space-available callback, so we loop until `write()` reports the buffer
    /// is full (returns `0`), the body is fully drained, or an error occurs.
    private func pump() {
        while true {
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
                // Loop again to keep filling the stream's buffer.
            } else if written < 0 {
                finish()
                return
            } else {
                // written == 0 means no space right now; wait for the next
                // .hasSpaceAvailable event.
                return
            }
        }
    }

    /// Returns the next slice of the body, advancing through prefix -> file
    /// chunks -> suffix -> done. Returns empty `Data` once fully drained.
    private func nextChunk() -> Data {
        switch stage {
        case .prefix:
            stage = .file
            return prefix
        case .file:
            // The file handle is opened in `init`; if a read fails partway
            // through we tear the stream down rather than skipping to the
            // closing boundary and sending a truncated body.
            if let handle = fileHandle {
                if let chunk = try? handle.read(upToCount: chunkSize) {
                    if !chunk.isEmpty {
                        return chunk
                    }
                } else {
                    os_log(.error, log: uploadLog,
                           "streaming body file read failed; aborting upload")
                    finish()
                    return Data()
                }
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

    /// Thread-safe shutdown hook. Safe to call from any thread and any number
    /// of times. Use this from the upload caller (e.g. in a `defer`) so the
    /// producer thread and bound streams are always torn down, even when the
    /// upload throws or the task is cancelled before the stream callbacks run.
    func cancel() {
        if let thread, thread.isExecuting, Thread.current != thread {
            // Hop onto the producer thread so all stream operations stay on the
            // run loop that scheduled the stream.
            perform(#selector(finish), on: thread, with: nil, waitUntilDone: false)
        } else {
            finish()
        }
    }

    @objc private func finish() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        if outputStream.streamStatus != .closed {
            outputStream.close()
            outputStream.remove(from: .current, forMode: .default)
        }
        try? fileHandle?.close()
        fileHandle = nil
        thread?.cancel()
    }
}
