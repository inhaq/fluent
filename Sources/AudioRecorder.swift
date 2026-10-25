import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.inhaq.fluent", category: "Recording")

struct AudioDevice: Identifiable {
    let id: String
    let uid: String
    let name: String

    fileprivate static func captureDevices() -> [AVCaptureDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            deviceTypes = [.microphone, .external]
        } else {
            deviceTypes = [.builtInMicrophone, .externalUnknown]
        }

        return AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func availableInputDevices() -> [AudioDevice] {
        var seenUIDs = Set<String>()
        return captureDevices()
            .compactMap { device in
                let uid = device.uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = device.localizedName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !uid.isEmpty, !name.isEmpty, seenUIDs.insert(uid).inserted else {
                    return nil
                }
                return AudioDevice(id: uid, uid: uid, name: name)
            }
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }
}

/// Stateful first-order 80 Hz high-pass filter applied incrementally, one
/// capture buffer at a time.
///
/// Implements `y[n] = alpha * (y[n-1] + x[n] - x[n-1])` — the same recurrence
/// as the whole-file pass in ``AudioRecorder/applyHighPass(to:frames:alpha:)``
/// — but carries the previous two inputs and outputs across calls so the
/// concatenated per-buffer output matches the whole-file result. The vectorized
/// form uses `vDSP_deq22`, which reads its two samples of history from the head
/// of the input/output arrays; each call seeds those slots with the carried
/// state (the very first call after ``reset()`` seeds the same way the
/// whole-file path does: x[-1] = first sample, y[-1] = 0).
///
/// Scratch buffers grow to the largest chunk seen and are then reused — capture
/// callbacks fire ~100×/sec and must not allocate. Instances are not
/// thread-safe: use one per serial queue.
struct StreamingHighPassFilter {
    private let alpha: Float
    private var previousInput0: Float = 0 // x[-1]
    private var previousInput1: Float = 0 // x[-2]
    private var previousOutput0: Float = 0 // y[-1]
    private var previousOutput1: Float = 0 // y[-2]
    private var inputScratch: [Float] = []
    private var outputScratch: [Float] = []
    private var hasProcessedAnyChunk = false

    init(cutoffHz: Float, sampleRate: Float) {
        let rc = 1 / (2 * Float.pi * cutoffHz)
        let dt = 1 / sampleRate
        alpha = rc / (rc + dt)
    }

    mutating func reset() {
        previousInput0 = 0
        previousInput1 = 0
        previousOutput0 = 0
        previousOutput1 = 0
        hasProcessedAnyChunk = false
    }

    /// Filters `frameCount` samples in place.
    mutating func applyInPlace(_ samples: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard frameCount > 0 else { return }
        if inputScratch.count < frameCount + 2 {
            inputScratch = [Float](repeating: 0, count: frameCount + 2)
            outputScratch = [Float](repeating: 0, count: frameCount + 2)
        }

        let coefficients: [Float] = [alpha, -alpha, 0, -alpha, 0]

        inputScratch.withUnsafeMutableBufferPointer { input in
            outputScratch.withUnsafeMutableBufferPointer { output in
                input.baseAddress!.advanced(by: 2).update(from: samples, count: frameCount)
                if hasProcessedAnyChunk {
                    input[0] = previousInput1
                    input[1] = previousInput0
                    output[0] = previousOutput1
                    output[1] = previousOutput0
                } else {
                    // First chunk ever: match the whole-file path's initial
                    // conditions exactly (x[-1] = x[0], y[-1] = 0).
                    input[0] = input[2]
                    input[1] = input[2]
                    output[0] = 0
                    output[1] = 0
                }
                vDSP_deq22(
                    input.baseAddress!, 1,
                    coefficients.withUnsafeBufferPointer { $0.baseAddress! },
                    output.baseAddress!, 1,
                    vDSP_Length(frameCount)
                )
                samples.update(from: output.baseAddress!.advanced(by: 2), count: frameCount)
                previousInput0 = input[frameCount + 1]
                previousInput1 = input[frameCount]
                previousOutput0 = output[frameCount + 1]
                previousOutput1 = output[frameCount]
            }
        }
        hasProcessedAnyChunk = true
    }
}

/// Int16-domain application of ``StreamingHighPassFilter`` for the recording
/// file writer: Int16 → Float scratch → filter → rounded/clipped back to Int16.
///
/// The recording file is Int16 (`recordingTargetFormat`), while the filter runs
/// in Float, so every chunk makes one scratch round-trip. The float scratch is
/// caller-owned and grows geometrically; no steady-state allocations. Rounding
/// uses `vDSP_vfixr16` (round-to-nearest) to track what AVAudioFile's own
/// float→Int16 conversion would have produced.
enum FileAudioHighPass {
    static func applyToInt16(
        _ source: UnsafePointer<Int16>,
        destination: UnsafeMutablePointer<Int16>,
        frameCount: Int,
        filter: inout StreamingHighPassFilter,
        floatScratch: inout [Float]
    ) {
        guard frameCount > 0 else { return }
        if floatScratch.count < frameCount {
            floatScratch = [Float](repeating: 0, count: frameCount)
        }
        vDSP_vflt16(source, 1, &floatScratch, 1, vDSP_Length(frameCount))
        floatScratch.withUnsafeMutableBufferPointer { scratch in
            filter.applyInPlace(scratch.baseAddress!, frameCount: frameCount)
        }
        // Clip before conversion so an out-of-range sample can never wrap.
        var lower: Float = -32_768
        var upper: Float = 32_767
        floatScratch.withUnsafeMutableBufferPointer { scratch in
            vDSP_vclip(scratch.baseAddress!, 1, &lower, &upper, scratch.baseAddress!, 1, vDSP_Length(frameCount))
            vDSP_vfixr16(scratch.baseAddress!, 1, destination, 1, vDSP_Length(frameCount))
        }
    }
}

enum AudioRecorderError: LocalizedError {
    case invalidInputFormat(String)
    case missingInputDevice
    case noAudioBuffersReceived
    case failedToCreateCaptureInput(String)
    case failedToStartCaptureSession(String)
    case failedToBeginFileRecording(String)

    var errorDescription: String? {
        switch self {
        case .invalidInputFormat(let details):
            return "Invalid input format: \(details)"
        case .missingInputDevice:
            return "No audio input device available."
        case .noAudioBuffersReceived:
            return "No audio buffers were received from the selected microphone."
        case .failedToCreateCaptureInput(let details):
            return "Could not open the selected microphone: \(details)"
        case .failedToStartCaptureSession(let details):
            return "Could not start the capture session: \(details)"
        case .failedToBeginFileRecording(let details):
            return "Could not begin recording audio: \(details)"
        }
    }
}

/// Lifecycle of the capture session. All reads/writes happen on
/// `sessionQueue`.
///
/// - `noSession`: nothing retained.
/// - `configuredStopped`: a fully configured session retained from the previous
///   dictation, stopped. The microphone hardware is not running (verified:
///   `kAudioDevicePropertyDeviceIsRunningSomewhere` stays false, so the system
///   mic indicator stays dark), but every expensive step except
///   `startRunning()` is already done. The next dictation pays only that call
///   (~40 ms measured) instead of rebuilding the whole session (~235 ms).
/// - `runningPrewarm`: the opt-in pre-warm feature — an idle session left
///   *running* so even `startRunning()` is skipped. Auto-cools down after
///   ``prewarmIdleTimeout`` because it keeps the mic indicator lit.
/// - `recording`: an active dictation owns the session.
/// - `interrupted`: recording was active and the system interrupted capture;
///   recovery resumes recording when the interruption ends.
///
/// There is deliberately no "invalid" case: a poisoned retained session (idle
/// runtime error, idle interruption) is torn down immediately, landing on
/// `.noSession` — the next trigger rebuilds from scratch.
private enum CaptureSessionState {
    case noSession
    case configuredStopped
    case runningPrewarm
    case recording
    case interrupted
}

/// Records microphone input to a normalized 16 kHz mono PCM16 WAV.
///
/// `@unchecked Sendable` documents an invariant this type already relies on: it
/// is inherently cross-thread (an `AVCaptureAudioDataOutput` delegate driven on
/// `sampleBufferQueue`, driven for setup/teardown on `sessionQueue`, and read
/// from post-processing tasks), and every piece of mutable state is guarded —
/// session/file state on `sessionQueue`, recording flags, converters, buffer
/// counts, and the level normalizer behind `OSAllocatedUnfairLock`, and the
/// `@Published` properties assigned on the main queue.
///
/// This is not the same situation as the annotation on `AppState`, which guards
/// nothing and is a genuine hazard. The stricter alternative here would be to
/// move the recording file's lifetime into its own `Sendable` lease type instead
/// of guarding it in place; worth doing, but not a change to make on the way out
/// the door.
final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private static let sessionQueueKey = DispatchSpecificKey<UInt8>()
    private var captureSession: AVCaptureSession?
    private var currentInput: AVCaptureDeviceInput?
    private var audioDataOutput: AVCaptureAudioDataOutput?
    private var sessionObservers: [NSObjectProtocol] = []
    private var tempFileURL: URL?
    private var recordingStartTime: CFAbsoluteTime = 0
    private let _bufferCount = OSAllocatedUnfairLock(initialState: 0)
    private let fileWriteErrorLock = OSAllocatedUnfairLock(initialState: ())
    private var watchdogTimer: DispatchSourceTimer?
    // Lifecycle of the retained capture session. Guarded by sessionQueue.
    private var captureSessionState: CaptureSessionState = .noSession
    /// Identity of the session the currently-installed observers belong to.
    /// Guarded by sessionQueue; lets queued notifications from a replaced
    /// session be recognized and dropped instead of acting on a newer one.
    private var currentSessionIdentity: ObjectIdentifier?
    // Explicit QoS on both capture queues. A queue created without `qos:` gets
    // .unspecified and infers priority from whoever enqueues — which for the
    // sample-buffer queue is AVFoundation, and on Apple Silicon that can land
    // the audio path on efficiency cores. The sample queue decodes, converts,
    // and writes ~100 buffers/sec, so it gets .userInteractive; session
    // setup/teardown is user-blocking but not per-frame, so .userInitiated.
    private let sessionQueue = DispatchQueue(
        label: "com.inhaq.fluent.capture.session",
        qos: .userInitiated
    )
    private let sampleBufferQueue = DispatchQueue(
        label: "com.inhaq.fluent.capture.samples",
        qos: .userInteractive
    )
    private var activeAudioFile: AVAudioFile?
    private var activeAudioFormat: AVAudioFormat?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var loggedCaptureFormat = false
    private var fileWriteError: Error?
    // Cached source format for the active capture session. Building an
    // AVAudioFormat from the sample buffer's format description on every
    // callback (~100x/sec) is wasteful; the format is constant for the
    // lifetime of a session, so cache it keyed by the format description.
    private var cachedSourceFormatDescription: CMFormatDescription?
    private var cachedSourceFormat: AVAudioFormat?
    // UID of the device the current capture session is configured for. Lets the
    // recording path reuse a retained session only when the device matches.
    private var currentDeviceUID: String?
    private var prewarmCooldownTimer: DispatchSourceTimer?
    private static let prewarmIdleTimeout: TimeInterval = 20.0
    // Reusable Float scratch for integer -> float conversion in rmsLevel.
    // Capture buffers arrive ~100x/sec and Int16/Int32 sources previously
    // allocated (and zero-filled) a fresh [Float] on every one. Only ever
    // touched on sampleBufferQueue, which is serial.
    private var floatScratch: [Float] = []
    // High-pass filtering of file-bound audio happens incrementally during
    // capture (see appendDecodedBufferToFile) so the stop path no longer pays a
    // full-file filter pass. State lives here; both are only ever touched on
    // sampleBufferQueue (filter) or sessionQueue before recording starts
    // (reset), with reset ordered before _recording goes live.
    private var fileHighPassFilter = StreamingHighPassFilter(cutoffHz: 80, sampleRate: 16_000)
    private var fileHighPassFloatScratch: [Float] = []
    /// Whether every file-bound buffer of the current recording was actually
    /// high-passed. Set false by any bypass path (copy allocation failure,
    /// missing channel data) so the enhancement stage knows to run the
    /// whole-file filter instead of trusting an unfiltered recording.
    private let fileHighPassSucceededLock = OSAllocatedUnfairLock(initialState: true)
    // Throttle state for publishing the live audio level to the UI.
    private var lastAudioLevelPublish: CFAbsoluteTime = 0
    private static let audioLevelPublishInterval: CFTimeInterval = 1.0 / 30.0

    @Published var isRecording = false
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
    /// Fires once per successful ``startRecording`` — on `sessionQueue`, before
    /// ``startRecording`` returns — with whether an existing retained session
    /// was reused (`true`) or freshly built (`false`). The owner uses this for
    /// pipeline signposts. Reset by callers alongside the other callbacks.
    var onSessionPrepared: ((_ reusedExistingSession: Bool) -> Void)?
    /// Fires on the sample-buffer queue with a 24 kHz mono PCM16 chunk for
    /// each incoming audio buffer (matching OpenAI Realtime's default PCM
    /// input rate). Set before ``startRecording`` to stream audio out-of-band
    /// to a realtime transcription socket. The recorder writes a normalized
    /// 16 kHz mono PCM16 WAV file independently for upload-based transcription.
    var onPCM16Samples: ((Data) -> Void)?
    private let recordingConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
    private let pcm16ConverterLock = OSAllocatedUnfairLock<AVAudioConverter?>(initialState: nil)
    private let recordingTargetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        )!
    }()
    private let pcm16TargetFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        )!
    }()
    private var readyFired = false
    private var failureReported = false
    private static let watchdogTimeout: TimeInterval = 2.0
    private static let sampleRateLogLimit = 40

    /// Sample-rate conversion quality for the downsamplers (mic -> 16 kHz file
    /// and mic -> 24 kHz realtime PCM16). Defaults to `.max`, which avoids
    /// aliasing artifacts that hurt word recognition, but is the most
    /// CPU-intensive setting and runs on every capture buffer (~100x/sec). It
    /// can be lowered without a rebuild for profiling via the
    /// `audio_sample_rate_converter_quality` user default
    /// (min/low/medium/high/max) so the right quality/CPU tradeoff is decided
    /// with Instruments instead of guesswork.
    private static func configuredConverterQuality() -> AVAudioQuality {
        switch UserDefaults.standard.string(forKey: "audio_sample_rate_converter_quality")?.lowercased() {
        case "min": return .min
        case "low": return .low
        case "medium": return .medium
        case "high": return .high
        case "max": return .max
        default: return .max
        }
    }

    override init() {
        super.init()
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: 1)
    }

    deinit {
        let cleanup = {
            self.cancelWatchdog()
            self.cancelPrewarmCooldownLocked()
            self.teardownSessionLocked()
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    private static func captureDevice(forUID uid: String) -> AVCaptureDevice? {
        AudioDevice.captureDevices().first(where: { $0.uniqueID == uid })
    }

    private static func defaultCaptureDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(for: .audio) ?? AudioDevice.captureDevices().first
    }

    private func preferredCaptureDevice(
        for requestedDeviceUID: String?,
        reason: String
    ) throws -> AVCaptureDevice {
        guard let requestedDeviceUID, !requestedDeviceUID.isEmpty, requestedDeviceUID != "default" else {
            guard let device = Self.defaultCaptureDevice() else {
                throw AudioRecorderError.missingInputDevice
            }
            os_log(.info, log: recordingLog, "%{public}@ — using system default device: %{public}@", reason, device.localizedName)
            return device
        }

        if let device = Self.captureDevice(forUID: requestedDeviceUID) {
            os_log(.info, log: recordingLog, "%{public}@ — keeping selected device: %{public}@ [uid=%{public}@]", reason, device.localizedName, device.uniqueID)
            return device
        }

        guard let fallbackDevice = Self.defaultCaptureDevice() else {
            throw AudioRecorderError.missingInputDevice
        }

        os_log(
            .info,
            log: recordingLog,
            "%{public}@ — selected device unavailable [uid=%{public}@], falling back to system default: %{public}@ [uid=%{public}@]",
            reason,
            requestedDeviceUID,
            fallbackDevice.localizedName,
            fallbackDevice.uniqueID
        )
        return fallbackDevice
    }

    private func installSessionObservers(for session: AVCaptureSession) {
        removeSessionObservers()

        // Scope every observer to the session instance it was installed for.
        // Notifications can already be queued when a newer session takes over
        // (retained-session reuse makes that window real); without this check
        // a stale runtime error would tear down or fail the NEWER recording.
        let sessionIdentity = ObjectIdentifier(session)
        currentSessionIdentity = sessionIdentity

        let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let wrapped = error.map { AudioRecorderError.failedToStartCaptureSession($0.localizedDescription) }
                ?? AudioRecorderError.failedToStartCaptureSession("Unknown runtime error")
            self?.handleRuntimeError(wrapped, fromSession: sessionIdentity)
        }
        sessionObservers.append(runtimeObserver)

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterrupted(notification, fromSession: sessionIdentity)
        }
        sessionObservers.append(interruptionObserver)

        let interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification, fromSession: sessionIdentity)
        }
        sessionObservers.append(interruptionEndedObserver)
    }

    private func removeSessionObservers() {
        for observer in sessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        sessionObservers.removeAll()
    }

    private func teardownSessionLocked() {
        removeSessionObservers()
        currentSessionIdentity = nil
        currentDeviceUID = nil

        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }

        captureSession = nil
        currentInput = nil
        audioDataOutput = nil
        cancelPrewarmCooldownLocked()
        captureSessionState = .noSession
    }

    /// Transitions a finished recording (or an active pre-warm) into the
    /// retained idle state: stopped but fully configured, so the next dictation
    /// pays only `startRunning()`.
    ///
    /// Observers and the output delegate stay attached — the system mic
    /// indicator is driven by whether the device is running, which it is not in
    /// this state, and idle runtime errors are handled silently by
    /// ``handleRuntimeError(_:)``. Nothing here may surface user-visible
    /// failures: no recording is in progress.
    private func retireSessionToConfiguredStopLocked() {
        cancelWatchdog()
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
        captureSessionState = .configuredStopped
    }

    /// A runtime error while a recording is active fails that recording.
    ///
    /// While idle (`configuredStopped`/`runningPrewarm`), the same error only
    /// means the retained session is unusable: tear it down silently and let
    /// the next trigger rebuild. Surfacing it as a recording failure would be
    /// wrong — there is no recording to fail.
    ///
    /// Notifications from a replaced session are dropped: by the time the
    /// queued block runs, `currentSessionIdentity` may already belong to a
    /// newer recording, which must never be torn down by stale events.
    private func handleRuntimeError(_ error: AudioRecorderError, fromSession identity: ObjectIdentifier) {
        sessionQueue.async {
            guard self.currentSessionIdentity == identity else {
                os_log(.info, log: recordingLog, "dropping runtime error from a replaced capture session")
                return
            }
            guard self._recording.withLock({ $0 }) else {
                os_log(.info, log: recordingLog, "idle capture session hit a runtime error — invalidating retained session: %{public}@", error.localizedDescription)
                self.teardownSessionLocked()
                return
            }
            os_log(.error, log: recordingLog, "capture session runtime error during recording: %{public}@", error.localizedDescription)
            self.reportRecordingFailure(error)
        }
    }

    private func reportRecordingFailure(_ error: Error, completion: ((URL?) -> Void)? = nil) {
        sessionQueue.async {
            guard !self.failureReported else { return }
            self.failureReported = true
            self.cancelWatchdog()
            self._recording.withLock { $0 = false }

            let completion = completion
            let discardURL = self.finishAudioFileLocked(discard: true)
            self.teardownSessionLocked()
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            if let discardURL {
                try? FileManager.default.removeItem(at: discardURL)
            }

            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                self.onRecordingFailure?(error)
                completion?(nil)
            }
        }
    }

    private func startBufferWatchdog() {
        let baselineCount = _bufferCount.withLock { $0 }
        cancelWatchdog()

        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.watchdogTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self._recording.withLock({ $0 }) else { return }
            guard self.captureSessionState != .interrupted else {
                os_log(.info, log: recordingLog, "watchdog suspended while capture session is interrupted")
                return
            }

            let count = self._bufferCount.withLock { $0 }
            if count == baselineCount {
                os_log(.error, log: recordingLog, "watchdog: no new buffers after %.1fs — giving up", Self.watchdogTimeout)
                self.reportRecordingFailure(AudioRecorderError.noAudioBuffersReceived)
            } else {
                os_log(.info, log: recordingLog, "watchdog: %d new buffers after %.1fs — healthy", count - baselineCount, Self.watchdogTimeout)
            }
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func cancelWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    private func finishAudioFileLocked(discard: Bool) -> URL? {
        var finalizedURL: URL?
        var shouldKeepFile = false

        // Drain all queued sample-buffer callbacks before releasing the writer.
        sampleBufferQueue.sync {
            finalizedURL = self.tempFileURL
            shouldKeepFile = !discard && self.recordedFrameCount > 0 && self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError == nil
            }
            self.activeAudioFile = nil
            self.activeAudioFormat = nil
            self.cachedSourceFormatDescription = nil
            self.cachedSourceFormat = nil
            self.lastAudioLevelPublish = 0
        }

        defer {
            self.recordedFrameCount = 0
            self.fileWriteErrorLock.withLock { _ in
                self.fileWriteError = nil
            }
            if !shouldKeepFile {
                self.tempFileURL = nil
            }
        }

        return shouldKeepFile ? finalizedURL : nil
    }

    private func handleSessionInterrupted(_ notification: Notification, fromSession identity: ObjectIdentifier) {
        _ = notification
        sessionQueue.async {
            guard self.currentSessionIdentity == identity else {
                os_log(.info, log: recordingLog, "dropping interruption from a replaced capture session")
                return
            }
            if self._recording.withLock({ $0 }) {
                self.captureSessionState = .interrupted
                self.cancelWatchdog()
                os_log(.info, log: recordingLog, "capture session interrupted — waiting for recovery")
            } else {
                // An interruption while idle invalidates the retained session;
                // never revive it. The next trigger rebuilds from scratch.
                os_log(.info, log: recordingLog, "idle capture session interrupted — dropping retained session")
                self.teardownSessionLocked()
            }
        }
    }

    private func handleSessionInterruptionEnded(_ notification: Notification, fromSession identity: ObjectIdentifier) {
        _ = notification
        sessionQueue.async {
            guard self.currentSessionIdentity == identity else { return }
            guard self.captureSessionState == .interrupted else { return }
            self.captureSessionState = .recording
            os_log(.info, log: recordingLog, "capture session interruption ended — restarting watchdog")
            self.startBufferWatchdog()
        }
    }

    private struct DecodedSampleBuffer {
        let buffer: AVAudioPCMBuffer
        let sourceFormat: AVAudioFormat
    }

    /// Decodes an incoming capture sample buffer into a single PCM buffer that
    /// is shared by the file writer, the realtime PCM16 stream, and the level
    /// meter. The source `AVAudioFormat` is cached (keyed by the format
    /// description) because rebuilding it on every callback is wasteful and the
    /// format is constant for the lifetime of a capture session.
    ///
    /// Returns `nil` for empty (zero-frame) buffers.
    private func decodeSampleBuffer(_ sampleBuffer: CMSampleBuffer) throws -> DecodedSampleBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw AudioRecorderError.invalidInputFormat("Could not determine audio format from sample buffer.")
        }

        let sourceFormat: AVAudioFormat
        if let cachedSourceFormatDescription,
           let cachedSourceFormat,
           CMFormatDescriptionEqual(cachedSourceFormatDescription, otherFormatDescription: formatDescription) {
            sourceFormat = cachedSourceFormat
        } else {
            sourceFormat = try validatedPCMBufferFormat(
                AVAudioFormat(cmAudioFormatDescription: formatDescription),
                context: "capture sample buffer"
            )
            cachedSourceFormatDescription = formatDescription
            cachedSourceFormat = sourceFormat
        }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        let inputBuffer = try makePCMBuffer(from: sampleBuffer, format: sourceFormat, frameCount: frameCount)
        return DecodedSampleBuffer(buffer: inputBuffer, sourceFormat: sourceFormat)
    }

    private func appendDecodedBufferToFile(
        _ inputBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat
    ) throws {
        if let fileWriteError = fileWriteErrorLock.withLock({ _ in
            self.fileWriteError
        }) {
            throw fileWriteError
        }

        guard let outputURL = tempFileURL else {
            throw AudioRecorderError.failedToBeginFileRecording("Missing temporary output URL.")
        }

        let targetFormat = recordingTargetFormat
        if !loggedCaptureFormat {
            loggedCaptureFormat = true
            os_log(
                .info,
                log: recordingLog,
                "capture audio format source=%{public}@ %.0fHz %u ch interleaved=%{public}@ target=%{public}@ %.0fHz %u ch interleaved=%{public}@ conversion=%{public}@",
                String(describing: sourceFormat.commonFormat),
                sourceFormat.sampleRate,
                sourceFormat.channelCount,
                String(sourceFormat.isInterleaved),
                String(describing: targetFormat.commonFormat),
                targetFormat.sampleRate,
                targetFormat.channelCount,
                String(targetFormat.isInterleaved),
                String(sourceFormat != targetFormat)
            )
        }
        if activeAudioFile == nil {
            let settings = pcmFileSettings(for: targetFormat)
            let audioFile = try AVAudioFile(
                forWriting: outputURL,
                settings: settings,
                commonFormat: targetFormat.commonFormat,
                interleaved: targetFormat.isInterleaved
            )
            activeAudioFile = audioFile
            activeAudioFormat = targetFormat
            os_log(.info, log: recordingLog, "audio file writer created at %{public}@", outputURL.path)
        }

        guard let activeAudioFile else {
            throw AudioRecorderError.failedToBeginFileRecording("Audio file writer was not initialized.")
        }

        if sourceFormat == targetFormat {
            // The decoded buffer is shared with the realtime stream and the
            // level meter, so it must never be mutated — filter a copy.
            let frameCount = Int(inputBuffer.frameLength)
            if let sourceInt16 = inputBuffer.int16ChannelData?[0],
               let filteredCopy = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: inputBuffer.frameCapacity) {
                filteredCopy.frameLength = inputBuffer.frameLength
                if let destinationInt16 = filteredCopy.int16ChannelData?[0] {
                    FileAudioHighPass.applyToInt16(
                        sourceInt16,
                        destination: destinationInt16,
                        frameCount: frameCount,
                        filter: &fileHighPassFilter,
                        floatScratch: &fileHighPassFloatScratch
                    )
                    try activeAudioFile.write(from: filteredCopy)
                    recordedFrameCount += AVAudioFramePosition(frameCount)
                    return
                }
            }
            // Copy/filter path unavailable (unexpected); write unfiltered
            // rather than dropping audio — and record that this recording is
            // NOT pre-filtered, so enhancement applies the whole-file pass.
            fileHighPassSucceededLock.withLock { $0 = false }
            try activeAudioFile.write(from: inputBuffer)
            recordedFrameCount += AVAudioFramePosition(inputBuffer.frameLength)
            return
        }

        let outputBuffer = try convertRecordingBuffer(
            inputBuffer,
            from: sourceFormat,
            to: targetFormat
        )
        guard outputBuffer.frameLength > 0 else { return }
        // outputBuffer is freshly allocated by the converter for this call, so
        // it can be filtered in place. The shared decoded buffer is untouched:
        // captureOutput passes it onward to the realtime emit and level meter
        // after this returns.
        if let int16Samples = outputBuffer.int16ChannelData?[0] {
            FileAudioHighPass.applyToInt16(
                int16Samples,
                destination: int16Samples,
                frameCount: Int(outputBuffer.frameLength),
                filter: &fileHighPassFilter,
                floatScratch: &fileHighPassFloatScratch
            )
        } else {
            // Cannot filter this buffer; mark the recording unfiltered so the
            // enhancement stage compensates with the whole-file pass.
            fileHighPassSucceededLock.withLock { $0 = false }
        }
        try activeAudioFile.write(from: outputBuffer)
        recordedFrameCount += AVAudioFramePosition(outputBuffer.frameLength)
    }

    private func validatedPCMBufferFormat(
        _ format: AVAudioFormat,
        context: String
    ) throws -> AVAudioFormat {
        let isPCM = format.commonFormat == .pcmFormatFloat32
            || format.commonFormat == .pcmFormatFloat64
            || format.commonFormat == .pcmFormatInt16
            || format.commonFormat == .pcmFormatInt32

        guard isPCM else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) is not PCM (commonFormat=\(String(describing: format.commonFormat)), settings=\(format.settings))."
            )
        }

        guard format.channelCount > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported zero channels."
            )
        }

        guard format.sampleRate > 0 else {
            throw AudioRecorderError.invalidInputFormat(
                "\(context) reported an invalid sample rate (\(format.sampleRate))."
            )
        }

        return format
    }

    private func pcmFileSettings(for format: AVAudioFormat) -> [String: Any] {
        let isFloat = isFloatFormat(format.commonFormat)
        let bitDepth = bitDepth(for: format.commonFormat)

        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVLinearPCMBitDepthKey: bitDepth,
            AVLinearPCMIsFloatKey: isFloat,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !format.isInterleaved,
        ]
    }

    private func isFloatFormat(_ commonFormat: AVAudioCommonFormat) -> Bool {
        commonFormat == .pcmFormatFloat32 || commonFormat == .pcmFormatFloat64
    }

    private func bitDepth(for commonFormat: AVAudioCommonFormat) -> Int {
        switch commonFormat {
        case .pcmFormatFloat64:
            64
        case .pcmFormatFloat32, .pcmFormatInt32:
            32
        case .pcmFormatInt16:
            16
        default:
            0
        }
    }

    private func makePCMBuffer(
        from sampleBuffer: CMSampleBuffer,
        format: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not allocate PCM buffer for format \(format.settings).")
        }
        inputBuffer.frameLength = frameCount
        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: inputBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not copy sample buffer data (OSStatus \(copyStatus)).")
        }
        return inputBuffer
    }

    private struct ConversionResult {
        let buffer: AVAudioPCMBuffer
        let status: String
    }

    private func convertRecordingBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let converter = recordingConverterLock.withLock { existing -> AVAudioConverter? in
            if let existing, existing.inputFormat == sourceFormat {
                return existing
            }
            let new = AVAudioConverter(from: sourceFormat, to: targetFormat)
            // Use a high-quality sample-rate conversion so downsampling a
            // 44.1/48 kHz mic to Whisper's 16 kHz does not introduce aliasing
            // artifacts that degrade word recognition. Quality is configurable
            // (defaults to .max) so it can be profiled — see
            // configuredConverterQuality().
            new?.sampleRateConverterQuality = Self.configuredConverterQuality().rawValue
            existing = new
            return new
        }
        guard let converter else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not create recording converter.")
        }

        return try convertBuffer(
            inputBuffer,
            from: sourceFormat,
            using: converter,
            to: targetFormat
        ).buffer
    }

    private func convertBuffer(
        _ inputBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        using converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) throws -> ConversionResult {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw AudioRecorderError.failedToBeginFileRecording("Could not allocate converted audio buffer.")
        }

        var suppliedInput = false
        var converterError: NSError?
        let status = converter.convert(to: outputBuffer, error: &converterError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let converterError {
            throw AudioRecorderError.failedToBeginFileRecording("Audio conversion failed: \(converterError.localizedDescription)")
        }
        guard status != .error, outputBuffer.frameLength > 0 else {
            throw AudioRecorderError.failedToBeginFileRecording("Audio conversion produced no data.")
        }
        return ConversionResult(buffer: outputBuffer, status: String(describing: status))
    }

    private func makeSession(deviceUID: String?, outputURL: URL) throws {
        cancelPrewarmCooldownLocked()
        let device = try preferredCaptureDevice(for: deviceUID, reason: "start recording")

        // Reuse a retained session for the same device so the trigger pays only
        // `startRunning()` (measured ~40 ms) instead of a full rebuild
        // (~105 ms configure + ~130 ms cold start). Two idle flavors reuse:
        //
        // - `.configuredStopped`: the default post-dictation retention. The
        //   mic is not running while idle, so the system indicator stays dark.
        // - `.runningPrewarm`: the opt-in pre-warm, still running. Recording
        //   begins without even `startRunning()`.
        switch captureSessionState {
        case .runningPrewarm where currentDeviceUID == device.uniqueID:
            guard let session = captureSession, session.isRunning else { break }
            resetFileWritingStateLocked()
            tempFileURL = outputURL
            captureSessionState = .recording
            onSessionPrepared?(true)
            os_log(.info, log: recordingLog, "reusing running pre-warmed session for %{public}@", device.localizedName)
            return
        case .configuredStopped where currentDeviceUID == device.uniqueID:
            guard let session = captureSession else { break }
            resetFileWritingStateLocked()
            tempFileURL = outputURL
            session.startRunning()
            if session.isRunning {
                captureSessionState = .recording
                onSessionPrepared?(true)
                os_log(.info, log: recordingLog, "reused retained stopped session for %{public}@ — startRunning only", device.localizedName)
                return
            }
            // startRunning() failed on a stale retained session (device
            // vanished mid-idle, route change). Fall through to a full rebuild.
            os_log(.info, log: recordingLog, "retained session failed to start — rebuilding")
        default:
            break
        }

        try configureSessionLocked(device: device)
        resetFileWritingStateLocked()
        tempFileURL = outputURL
        captureSessionState = .recording
        onSessionPrepared?(false)
    }

    /// Builds, configures, and starts a capture session for `device`. Shared by
    /// the recording start path and pre-warming. Does not touch file-writing
    /// state or `tempFileURL`; callers do that when they actually begin
    /// recording.
    private func configureSessionLocked(device: AVCaptureDevice) throws {
        teardownSessionLocked()

        let session = AVCaptureSession()
        let dataOutput = AVCaptureAudioDataOutput()
        dataOutput.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: recordingTargetFormat.sampleRate,
            AVNumberOfChannelsKey: Int(recordingTargetFormat.channelCount),
            AVLinearPCMBitDepthKey: bitDepth(for: recordingTargetFormat.commonFormat),
            AVLinearPCMIsFloatKey: isFloatFormat(recordingTargetFormat.commonFormat),
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: !recordingTargetFormat.isInterleaved,
        ]
        dataOutput.setSampleBufferDelegate(self, queue: sampleBufferQueue)

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioRecorderError.failedToCreateCaptureInput(error.localizedDescription)
        }

        session.beginConfiguration()
        var needsCommitConfiguration = true
        defer {
            if needsCommitConfiguration {
                session.commitConfiguration()
            }
        }

        guard session.canAddInput(input) else {
            throw AudioRecorderError.failedToCreateCaptureInput("Session rejected device input for \(device.localizedName).")
        }
        session.addInput(input)

        guard session.canAddOutput(dataOutput) else {
            throw AudioRecorderError.failedToStartCaptureSession("Session rejected audio data output.")
        }
        session.addOutput(dataOutput)

        session.commitConfiguration()
        needsCommitConfiguration = false

        captureSession = session
        currentInput = input
        audioDataOutput = dataOutput
        currentDeviceUID = device.uniqueID
        recordingConverterLock.withLock { $0 = nil }
        pcm16ConverterLock.withLock { $0 = nil }
        installSessionObservers(for: session)

        os_log(.info, log: recordingLog, "configured capture session with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)

        session.startRunning()
        guard session.isRunning else {
            throw AudioRecorderError.failedToStartCaptureSession("Session failed to enter running state.")
        }

        os_log(.info, log: recordingLog, "capture session running with device %{public}@ [uid=%{public}@]", device.localizedName, device.uniqueID)
    }

    /// Clears the per-recording file-writer state so a (possibly reused)
    /// session writes a fresh output file.
    private func resetFileWritingStateLocked() {
        activeAudioFile = nil
        activeAudioFormat = nil
        recordedFrameCount = 0
        loggedCaptureFormat = false
        fileHighPassFilter.reset()
        fileHighPassSucceededLock.withLock { $0 = true }
        fileWriteErrorLock.withLock { _ in
            fileWriteError = nil
        }
    }

    /// Whether the finished recording was fully high-passed during capture.
    /// Read after ``stopRecording`` completes (the sample queue is drained by
    /// then); written only on the sample queue under a lock.
    var lastRecordingHighPassApplied: Bool {
        fileHighPassSucceededLock.withLock { $0 }
    }

    /// Pre-warms an idle capture session so the next ``startRecording`` can skip
    /// even `startRunning()`. While warm the session runs but every sample
    /// buffer is dropped in ``captureOutput`` because `_recording` is false
    /// (nothing is written or metered). This state keeps the system mic
    /// indicator lit, so it is strictly opt-in and auto-cools-down after
    /// ``prewarmIdleTimeout``. The default idle retention is
    /// ``CaptureSessionState/configuredStopped``, which stays dark. No-op while
    /// recording.
    func prewarm(deviceUID: String? = nil) {
        sessionQueue.async {
            guard !self._recording.withLock({ $0 }) else { return }
            do {
                let device = try self.preferredCaptureDevice(for: deviceUID, reason: "prewarm")
                if let session = self.captureSession,
                   session.isRunning,
                   self.currentDeviceUID == device.uniqueID,
                   self.captureSessionState == .runningPrewarm || self.captureSessionState == .recording {
                    // Already warm with the right device; just refresh the timer.
                    if self.captureSessionState != .recording {
                        self.captureSessionState = .runningPrewarm
                        self.schedulePrewarmCooldownLocked()
                    }
                    return
                }
                try self.configureSessionLocked(device: device)
                self.captureSessionState = .runningPrewarm
                self.schedulePrewarmCooldownLocked()
                os_log(.info, log: recordingLog, "capture session pre-warmed with %{public}@", device.localizedName)
            } catch {
                os_log(.error, log: recordingLog, "prewarm failed: %{public}@", error.localizedDescription)
                self.teardownSessionLocked()
            }
        }
    }

    /// Tears down a pre-warmed idle session. No-op while recording (the active
    /// recording owns the session).
    func stopPrewarm() {
        sessionQueue.async {
            guard self.captureSessionState == .runningPrewarm, !self._recording.withLock({ $0 }) else { return }
            self.cancelPrewarmCooldownLocked()
            self.teardownSessionLocked()
            os_log(.info, log: recordingLog, "pre-warmed capture session torn down")
        }
    }

    private func schedulePrewarmCooldownLocked() {
        cancelPrewarmCooldownLocked()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.prewarmIdleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.captureSessionState == .runningPrewarm, !self._recording.withLock({ $0 }) else { return }
            self.teardownSessionLocked()
            os_log(.info, log: recordingLog, "pre-warm idle timeout — cooling down")
        }
        timer.resume()
        prewarmCooldownTimer = timer
    }

    private func cancelPrewarmCooldownLocked() {
        prewarmCooldownTimer?.cancel()
        prewarmCooldownTimer = nil
    }

    func startRecording(deviceUID: String? = nil) throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        recordingStartTime = t0
        _bufferCount.withLock { $0 = 0 }
        readyFired = false
        failureReported = false
        liveLevelNormalizerLock.withLock { $0.reset() }

        os_log(.info, log: recordingLog, "startRecording() entered")

        let tempDir = FileManager.default.temporaryDirectory
        let outputURL = tempDir.appendingPathComponent(UUID().uuidString + ".wav")

        do {
            try sessionQueue.sync {
                try self.makeSession(deviceUID: deviceUID, outputURL: outputURL)
                self._recording.withLock { $0 = true }
                self.startBufferWatchdog()
            }
        } catch {
            if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
                tempFileURL = nil
            } else {
                sessionQueue.sync {
                    tempFileURL = nil
                }
            }
            throw error
        }

        DispatchQueue.main.async {
            self.isRecording = true
            self.audioLevel = 0.0
        }
        os_log(.info, log: recordingLog, "startRecording() complete: %.3fms total", (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    func stopRecording(completion: @escaping (URL?) -> Void) {
        let count = _bufferCount.withLock { $0 }
        let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
        os_log(.info, log: recordingLog, "stopRecording() called: %.3fms after start, %d buffers received", elapsed, count)

        sessionQueue.async {
            self.retireSessionToConfiguredStopLocked()
            let outputURL = self.finishAudioFileLocked(discard: false)
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
                completion(outputURL)
            }
        }
    }

    func cancelRecording() {
        sessionQueue.async {
            // A clean cancel keeps the configured session for the next
            // dictation, exactly like a normal stop.
            self.retireSessionToConfiguredStopLocked()
            let discardURL = self.finishAudioFileLocked(discard: true)
            self._recording.withLock { $0 = false }
            self.liveLevelNormalizerLock.withLock { $0.reset() }
            if let discardURL {
                try? FileManager.default.removeItem(at: discardURL)
            }
            DispatchQueue.main.async {
                self.isRecording = false
                self.audioLevel = 0.0
            }
        }
    }

    /// Number of readers currently holding the finished recording file, plus the
    /// recordings a `cleanup()` still owes a deletion for.
    ///
    /// Post-processing reads the recording after `stopRecording` hands back its
    /// URL, while `cleanup()` can be called concurrently from the cancel path.
    /// Deleting the file mid-read produced a spurious transcription failure, so
    /// deletion is deferred until the last reader releases it.
    private struct RecordingFileRetain {
        var readers = 0
        /// Deferred deletions, held by URL rather than as a "cleanup pending"
        /// flag. By the time the last reader releases, `tempFileURL` may already
        /// belong to a *newer* recording — a flag would make the release delete
        /// that one instead of the file cleanup was called for.
        var deferredDeletions: Set<URL> = []
    }

    private let recordingFileRetain = OSAllocatedUnfairLock(initialState: RecordingFileRetain())

    /// Registers a reader of the finished recording file, holding off any
    /// concurrent ``cleanup()`` until ``releaseRecordingFile()`` balances it.
    ///
    /// Prefer ``withRecordingFileRetained(_:)`` for synchronous scopes. The
    /// explicit pair exists for `async` readers, whose span (an upload, say)
    /// cannot be expressed as a single non-escaping closure.
    func retainRecordingFile() {
        recordingFileRetain.withLock { $0.readers += 1 }
    }

    /// Balances ``retainRecordingFile()``, performing any deletion that arrived
    /// while the file was held once the last reader lets go.
    func releaseRecordingFile() {
        let pending = recordingFileRetain.withLock { state -> Set<URL> in
            state.readers -= 1
            guard state.readers == 0 else { return [] }
            let deletions = state.deferredDeletions
            state.deferredDeletions.removeAll()
            return deletions
        }
        for url in pending {
            removeRecordingFile(at: url)
        }
    }

    /// Runs `body` with the finished recording file guaranteed to exist for its
    /// duration. A concurrent ``cleanup()`` is honoured once `body` returns.
    func withRecordingFileRetained<T>(_ body: () -> T) -> T {
        retainRecordingFile()
        defer { releaseRecordingFile() }
        return body()
    }

    /// Discards the recording at `url` — the file a session was handed by
    /// ``stopRecording(completion:)``.
    ///
    /// Every caller that still holds its own recording URL must use this rather
    /// than ``cleanup()``. Post-processing outlives the session that started it:
    /// by the time it finishes, the user may have begun a new dictation, and
    /// `cleanup()` targets whatever recording is current — so a late caller
    /// would delete the *new* recording out from under it.
    func discardRecording(at url: URL) {
        deleteOrDefer(url)
    }

    /// Discards whatever recording is current. For callers with no URL of their
    /// own — a start failure, or a stop that produced no file.
    func cleanup() {
        // Resolve the file *now*, before deciding whether to defer, so a
        // deferred deletion stays pinned to the recording that was live when
        // cleanup was called.
        guard let target = onSessionQueue({ self.tempFileURL }) else { return }
        deleteOrDefer(target)
    }

    /// Deletes `url` unless a reader is holding the recording, in which case the
    /// deletion is handed to whichever release drops the last lease.
    private func deleteOrDefer(_ url: URL) {
        let deferDeletion = recordingFileRetain.withLock { state -> Bool in
            guard state.readers > 0 else { return false }
            state.deferredDeletions.insert(url)
            return true
        }
        guard !deferDeletion else { return }
        removeRecordingFile(at: url)
    }

    /// Deletes `url`, clearing ``tempFileURL`` only if it still refers to it.
    private func removeRecordingFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        onSessionQueue {
            if self.tempFileURL == url {
                self.tempFileURL = nil
            }
        }
    }

    private func onSessionQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            return body()
        }
        return sessionQueue.sync(execute: body)
    }

    /// Applies `y[n] = alpha * (y[n-1] + x[n] - x[n-1])` in place.
    ///
    /// Expressed as a biquad for `vDSP_deq22` rather than a scalar loop. The
    /// loop form ran 960,000 iterations for a 60-second recording, directly on
    /// the path between the user releasing the dictation key and text appearing:
    /// measured 116 ms at -Onone and 3.6 ms at -O, versus 1.5 ms here. Accelerate
    /// is also precompiled, so this stays fast regardless of build flags.
    ///
    /// Output matches the scalar form to float rounding (verified: 0.04704714 vs
    /// 0.04704712 at the midpoint of a 60 s signal).
    private static func applyHighPass(
        to samples: UnsafeMutablePointer<Float>,
        frames: Int,
        alpha: Float
    ) {
        guard frames > 0 else { return }
        guard frames > 2 else {
            // Too short for the biquad's 2-sample history; do it directly.
            var previousInput = samples[0]
            var previousOutput: Float = 0
            for index in 0..<frames {
                let input = samples[index]
                let output = alpha * (previousOutput + input - previousInput)
                samples[index] = output
                previousInput = input
                previousOutput = output
            }
            return
        }

        // vDSP_deq22 computes:
        //   C[n] = A[n]*B[0] + A[n-1]*B[1] + A[n-2]*B[2] - C[n-1]*B[3] - C[n-2]*B[4]
        // Note that the feedback terms are SUBTRACTED, so the y[n-1] coefficient
        // is -alpha, not +alpha.
        let coefficients: [Float] = [alpha, -alpha, 0, -alpha, 0]
        var input = [Float](repeating: 0, count: frames + 2)
        var output = [Float](repeating: 0, count: frames + 2)

        input.withUnsafeMutableBufferPointer { buffer in
            buffer.baseAddress!.advanced(by: 2).update(from: samples, count: frames)
            // Seed x[-1] = samples[0] and y[-1] = 0 to match the scalar form's
            // initial conditions exactly.
            buffer[0] = samples[0]
            buffer[1] = samples[0]
        }

        coefficients.withUnsafeBufferPointer { coefficientBuffer in
            input.withUnsafeBufferPointer { inputBuffer in
                output.withUnsafeMutableBufferPointer { outputBuffer in
                    vDSP_deq22(
                        inputBuffer.baseAddress!,
                        1,
                        coefficientBuffer.baseAddress!,
                        outputBuffer.baseAddress!,
                        1,
                        vDSP_Length(frames)
                    )
                }
            }
        }

        output.withUnsafeBufferPointer { buffer in
            samples.update(from: buffer.baseAddress!.advanced(by: 2), count: frames)
        }
    }

    /// Loudness targeting result for the normalization stage.
    struct LoudnessTarget {
        /// The RMS the gain stage should target: the speech-active RMS when
        /// measurement was confident, otherwise the whole-file RMS (legacy
        /// behavior).
        let effectiveRMS: Float
        let usedSpeechWeighting: Bool
        let speechFrameFraction: Double
        let snrMarginDB: Double
    }

    /// Speech-aware loudness targeting for the normalization stage.
    ///
    /// The legacy whole-file RMS treats pauses as signal: a whisperer who
    /// dictates in short bursts measures far quieter than they speak, so the
    /// gain stage under-boosts their speech — or, when it does reach for more
    /// gain, spends the budget amplifying silence. This estimator instead:
    ///
    /// 1. Computes per-frame mean squares (25 ms frames).
    /// 2. Estimates the noise floor conservatively from leading/trailing
    ///    "edge" frames (a dictation usually starts and ends in room tone),
    ///    falling back to a low percentile of all frames; the higher (more
    ///    conservative) estimate wins.
    /// 3. Counts speech frames above floor + margin and requires *meaningful*
    ///    separation between speech energy and that floor.
    /// 4. Falls back to the whole-file RMS unless every confidence gate passes,
    ///    so uncertain audio is never amplified aggressively — continuous
    ///    whisper with no discernible floor must not have its noise floor
    ///    boosted to look like speech.
    ///
    /// Pure function of the frame energies — unit-testable without audio I/O.
    static func loudnessTarget(
        frameMeanSquares: [Float],
        sampleRate: Double
    ) -> LoudnessTarget {
        let wholeFileFallback = { (frames: [Float]) -> LoudnessTarget in
            let mean = frames.reduce(Float(0), +) / Float(max(frames.count, 1))
            return LoudnessTarget(effectiveRMS: sqrt(mean), usedSpeechWeighting: false, speechFrameFraction: 0, snrMarginDB: 0)
        }
        guard frameMeanSquares.count >= 4 else {
            return wholeFileFallback(frameMeanSquares)
        }
        let frameSeconds = 0.025
        // ~0.5 s worth of frames on each side (leading/trailing room tone).
        // NOTE: this is seconds converted to a frame COUNT — not a fraction
        // of all frames. An earlier draft multiplied sample rate by frame
        // duration here, producing windows so large they overlapped the
        // speech and poisoned the floor estimate on short recordings.
        let framesPerEdgeWindow = max(2, Int((0.5 / frameSeconds).rounded()))
        let n = frameMeanSquares.count

        func dB(_ linear: Float) -> Double {
            10 * log10(Double(max(linear, .leastNormalMagnitude)))
        }

        // Noise floor candidates: edge-window median (leading+trailing) and a
        // low overall percentile. Conservative = take the higher estimate.
        let sorted = frameMeanSquares.sorted()
        var floorCandidates: [Float] = []
        let edgeCount = min(framesPerEdgeWindow * 2, n)
        if edgeCount >= 4 {
            var edgeFrames = Array(frameMeanSquares.prefix(framesPerEdgeWindow))
            edgeFrames.append(contentsOf: frameMeanSquares.suffix(framesPerEdgeWindow))
            edgeFrames.sort()
            let median = edgeFrames[edgeFrames.count / 2]
            floorCandidates.append(median)
        }
        floorCandidates.append(sorted[max(0, Int(Double(n) * 0.10))])
        let noiseFloorLinear = floorCandidates.max() ?? sorted[0]
        let floorDB = dB(noiseFloorLinear)

        // Speech frames: meaningfully above the floor.
        let marginDB = 8.0
        let thresholdDB = floorDB + marginDB
        var speechEnergies: [Float] = []
        speechEnergies.reserveCapacity(n)
        for energy in frameMeanSquares where dB(energy) > thresholdDB {
            speechEnergies.append(energy)
        }
        let speechFraction = Double(speechEnergies.count) / Double(n)

        // Confidence gates — any miss falls back to legacy behavior.
        let minimumSpeechFrames = 4
        guard speechEnergies.count >= minimumSpeechFrames, speechFraction >= 0.02 else {
            return LoudnessTarget(effectiveRMS: sqrt(frameMeanSquares.reduce(0, +) / Float(n)), usedSpeechWeighting: false, speechFrameFraction: speechFraction, snrMarginDB: 0)
        }

        // Measured separation: robust high speech percentile vs floor.
        speechEnergies.sort()
        let speechHighDB = dB(speechEnergies[min(speechEnergies.count - 1, (speechEnergies.count * 9) / 10)])
        let snrMarginDB = speechHighDB - floorDB
        guard snrMarginDB >= 6.0 else {
            return LoudnessTarget(effectiveRMS: sqrt(frameMeanSquares.reduce(0, +) / Float(n)), usedSpeechWeighting: false, speechFrameFraction: speechFraction, snrMarginDB: snrMarginDB)
        }

        let speechRMS = sqrt(speechEnergies.reduce(0, +) / Float(speechEnergies.count))
        return LoudnessTarget(effectiveRMS: speechRMS, usedSpeechWeighting: true, speechFrameFraction: speechFraction, snrMarginDB: snrMarginDB)
    }

    /// Enhances a recorded PCM WAV for speech recognition and writes the result
    /// to a new temporary upload file: lossless FLAC when `compress` is set,
    /// otherwise WAV.
    ///
    /// - Parameter highPassAppliedDuringCapture: `true` when the recording was
    ///   written through ``StreamingHighPassFilter`` during capture — the
    ///   production path since the high-pass moved out of the stop path. The
    ///   80 Hz filter is already in the file, so Stage 1 here would
    ///   double-filter. `false` runs the whole-file Stage 1 pass; that mode is
    ///   retained as the reference implementation for the streaming-vs-
    ///   whole-file equivalence harness (and as a fallback if the incremental
    ///   path ever needs disabling).
    /// - Parameter compress: Write FLAC instead of WAV. FLAC is lossless — the
    ///   provider decodes the same 16-bit samples — but measured at ~57% of the
    ///   enhanced WAV's size on real dictations, so the upload on the
    ///   release-to-paste path moves ~43% fewer bytes. Encoding costs ~0.7 ms
    ///   per second of audio. When set, a recording too hot to boost is still written
    ///   (at unity gain) so it gets the smaller upload too. Falls back to WAV
    ///   if the FLAC encoder fails.
    ///
    /// Remaining stages: loudness normalization toward a consistent target RMS,
    /// with a peak ceiling and a capped makeup gain, so faint dictation reaches
    /// the model at a predictable level. It never attenuates.
    ///
    /// The operation is intentionally conservative and self-healing:
    /// - Silent clips (RMS below ``silenceRMSFloor``) are skipped so we never
    ///   amplify the noise floor.
    /// - Makeup gain is capped (``maxMakeupGain``) and limited so the peak can
    ///   never exceed ``peakCeiling``. If the signal already overshoots the
    ///   ceiling, enhancement is abandoned (returns `nil`) so the caller
    ///   uploads the original rather than a clipped version. A final hard clip
    ///   to [-1, 1] only guards the float-to-Int16 write.
    /// - Any failure returns `nil`.
    ///
    /// - Returns: A new temporary WAV URL the caller should upload (and delete
    ///   afterward), or `nil` when enhancement was skipped or failed — in which
    ///   case the caller must upload the original file unchanged.
    static func enhancedAudioForUpload(
        at sourceURL: URL,
        highPassAppliedDuringCapture: Bool,
        compress: Bool
    ) -> URL? {
        let targetRMS: Float = 0.125      // ~ -18 dBFS, a comfortable speech level
        let peakCeiling: Float = 0.97     // ~ -0.26 dBFS, leaves headroom
        let maxMakeupGain: Float = 11.0   // ~ +21 dB cap so we don't blow up noise
        let silenceRMSFloor: Float = 0.0009
        let highPassCutoffHz: Float = 80  // below the speech fundamental range

        do {
            let inputFile = try AVAudioFile(forReading: sourceURL)
            let format = inputFile.processingFormat
            let frameCount = AVAudioFrameCount(inputFile.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                return nil
            }
            try inputFile.read(into: buffer)

            let frames = Int(buffer.frameLength)
            let channelCount = Int(format.channelCount)
            guard frames > 0, channelCount > 0, let channels = buffer.floatChannelData else {
                return nil
            }

            // Skip pure silence so we never high-pass/amplify the noise floor.
            var preSummedMeanSquare: Float = 0
            for channel in 0..<channelCount {
                var meanSquare: Float = 0
                vDSP_measqv(channels[channel], 1, &meanSquare, vDSP_Length(frames))
                preSummedMeanSquare += meanSquare
            }
            guard sqrt(preSummedMeanSquare / Float(channelCount)) > silenceRMSFloor else {
                return nil
            }

            // --- Stage 1: first-order high-pass (in place, per channel) ---
            // y[n] = alpha * (y[n-1] + x[n] - x[n-1])
            //
            // Skipped when the recording was already filtered incrementally
            // during capture (see StreamingHighPassFilter).
            if !highPassAppliedDuringCapture {
                let sampleRate = Float(format.sampleRate)
                let rc = 1 / (2 * Float.pi * highPassCutoffHz)
                let dt = 1 / sampleRate
                let alpha = rc / (rc + dt)
                for channel in 0..<channelCount {
                    Self.applyHighPass(to: channels[channel], frames: frames, alpha: alpha)
                }
            }

            // --- Stage 2: measure post-filter loudness/peak, apply safe gain ---
            var peak: Float = 0
            for channel in 0..<channelCount {
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(frames))
                peak = max(peak, channelPeak)
            }
            guard peak > 0 else { return nil }

            // Speech-aware loudness targeting (see ``loudnessTarget(frameMeanSquares:sampleRate:)``):
            // frame energies averaged across channels, then a conservative
            // speech-active RMS — falling back to the whole-file RMS whenever
            // speech can't be distinguished from the noise floor.
            //
            // frameLength is clamped to the buffer length so a sub-25 ms
            // recording still yields one full-signal frame. Without the clamp,
            // an empty frame array would make the fallback compute sqrt(0) and
            // drive desiredGain to infinity — pinning the gain to the makeup
            // cap instead of the measured level.
            let frameLength = max(1, min(Int((format.sampleRate * 0.025).rounded()), frames))
            let frameTotal = frames / frameLength
            var frameMeanSquares: [Float] = []
            frameMeanSquares.reserveCapacity(frameTotal)
            for frame in 0..<frameTotal {
                let start = frame * frameLength
                var sum: Float = 0
                for channel in 0..<channelCount {
                    var meanSquare: Float = 0
                    vDSP_measqv(channels[channel] + start, 1, &meanSquare, vDSP_Length(frameLength))
                    sum += meanSquare
                }
                frameMeanSquares.append(sum / Float(channelCount))
            }
            let target = Self.loudnessTarget(frameMeanSquares: frameMeanSquares, sampleRate: format.sampleRate)
            os_log(
                .info,
                log: recordingLog,
                "loudness target: method=%{public}@ speech_fraction=%.2f snr_margin=%.1fdB rms=%.5f",
                target.usedSpeechWeighting ? "speech-weighted" : "whole-file",
                target.speechFrameFraction,
                target.snrMarginDB,
                target.effectiveRMS
            )

            // Target the desired RMS, but never amplify beyond the cap and
            // never let the loudest sample exceed the ceiling. If the
            // high-passed signal already overshoots the ceiling, bail out so
            // the caller uploads the untouched original rather than a clipped
            // version — unless we're compressing and the buffer *is* the
            // untouched original (no Stage 1 ran here), in which case it is
            // written at unity gain so the upload still shrinks.
            let peakLimitedGain = peakCeiling / peak
            guard peakLimitedGain >= 1 || (compress && highPassAppliedDuringCapture) else {
                return nil
            }
            // Never attenuate (floor at 1), and keep the peak under the ceiling.
            let desiredGain = max(targetRMS / target.effectiveRMS, 1)
            let gain = min(desiredGain, maxMakeupGain, max(peakLimitedGain, 1))

            if gain != 1 {
                for channel in 0..<channelCount {
                    var scalar = gain
                    vDSP_vsmul(channels[channel], 1, &scalar, channels[channel], 1, vDSP_Length(frames))
                }
            }

            // Hard safety clip so the float -> Int16 file write can never wrap.
            var low: Float = -1
            var high: Float = 1
            for channel in 0..<channelCount {
                vDSP_vclip(channels[channel], 1, &low, &high, channels[channel], 1, vDSP_Length(frames))
            }

            if compress, let flacURL = writeFLAC(buffer, format: inputFile.fileFormat) {
                return flacURL
            }
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".wav")
            let outputFile = try AVAudioFile(forWriting: outputURL, settings: inputFile.fileFormat.settings)
            try outputFile.write(from: buffer)
            return outputURL
        } catch {
            os_log(.info, log: recordingLog, "audio enhancement skipped: %{public}@", error.localizedDescription)
            return nil
        }
    }

    /// Encodes `buffer` as a 16-bit FLAC temp file, or returns `nil` (cleaning
    /// up any partial file) so the caller can fall back to WAV.
    ///
    /// Quantizes the buffer to the 16-bit grid first — the resolution the
    /// Int16 WAV write keeps, so decoded samples match it to within 1 LSB
    /// (rounding-mode differences only). Without
    /// it the gain stage leaves off-grid floats, the encoder preserves them at
    /// 24-bit precision, and the "compressed" file came out larger than the
    /// WAV. Clips shorter than a second stay WAV: Apple's encoder drops a
    /// stream shorter than one FLAC block (it wrote a header-only file), and
    /// there is nothing worth saving at that size anyway. The written file is
    /// re-opened and its length checked before it is trusted.
    private static func writeFLAC(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) -> URL? {
        guard Double(buffer.frameLength) >= format.sampleRate,
              buffer.format.commonFormat == .pcmFormatFloat32,
              let channels = buffer.floatChannelData else {
            return nil
        }
        let frameCount = vDSP_Length(buffer.frameLength)
        var length = Int32(buffer.frameLength)
        for channel in 0..<Int(buffer.format.channelCount) {
            var scale: Float = 32_768
            var inverseScale: Float = 1 / 32_768
            vDSP_vsmul(channels[channel], 1, &scale, channels[channel], 1, frameCount)
            vvnintf(channels[channel], channels[channel], &length)
            vDSP_vsmul(channels[channel], 1, &inverseScale, channels[channel], 1, frameCount)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".flac")
        do {
            // Scoped so the file is closed (and the FLAC stream finalized)
            // before the URL is handed to the uploader.
            do {
                let outputFile = try AVAudioFile(
                    forWriting: outputURL,
                    settings: [
                        AVFormatIDKey: kAudioFormatFLAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVLinearPCMBitDepthKey: 16
                    ],
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
                try outputFile.write(from: buffer)
            }
            let writtenFrames = try AVAudioFile(forReading: outputURL).length
            guard writtenFrames == AVAudioFramePosition(buffer.frameLength) else {
                throw NSError(domain: "FluentFLAC", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "wrote \(writtenFrames) of \(buffer.frameLength) frames"
                ])
            }
            return outputURL
        } catch {
            os_log(.info, log: recordingLog, "FLAC encode failed, falling back to WAV: %{public}@", error.localizedDescription)
            try? FileManager.default.removeItem(at: outputURL)
            return nil
        }
    }

    private func updateAudioLevel(from inputBuffer: AVAudioPCMBuffer) -> Float {
        let rms = rmsLevel(for: inputBuffer)
        let normalizedDisplayLevel = liveLevelNormalizerLock.withLock {
            $0.normalizedLevel(forRMS: rms)
        }

        publishAudioLevel(normalizedDisplayLevel)
        return rms
    }

    /// Publishes the live audio level to the UI at display rate. Capture
    /// buffers arrive ~100x/sec, but the overlay waveform only needs ~30 fps;
    /// dispatching every buffer to the main thread caused UI jank during
    /// recording. A return-to-zero (level == 0) is always published promptly so
    /// the meter never appears stuck.
    private func publishAudioLevel(_ level: Float) {
        let now = CFAbsoluteTimeGetCurrent()
        if level > 0 && (now - lastAudioLevelPublish) < Self.audioLevelPublishInterval {
            return
        }
        lastAudioLevelPublish = now
        DispatchQueue.main.async {
            self.audioLevel = level
        }
    }

    /// Runs `body` with a mutable Float buffer of at least `count` elements,
    /// growing the reusable scratch as needed. Must be called on
    /// `sampleBufferQueue`.
    private func withFloatScratch<T>(
        count: Int,
        _ body: (UnsafeMutablePointer<Float>) -> T
    ) -> T {
        if floatScratch.count < count {
            floatScratch = [Float](repeating: 0, count: count)
        }
        return floatScratch.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    private func rmsLevel(for buffer: AVAudioPCMBuffer) -> Float {
        let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var totalSamples = 0
        var sumOfSquares: Double = 0

        for audioBuffer in audioBuffers {
            guard let baseAddress = audioBuffer.mData, audioBuffer.mDataByteSize > 0 else {
                continue
            }

            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                guard samples > 0 else { continue }
                let pointer = baseAddress.assumingMemoryBound(to: Float.self)
                var meanSquare: Float = 0
                vDSP_measqv(pointer, 1, &meanSquare, vDSP_Length(samples))
                sumOfSquares += Double(meanSquare) * Double(samples)
                totalSamples += samples
            case .pcmFormatFloat64:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Double>.size
                guard samples > 0 else { continue }
                let pointer = baseAddress.assumingMemoryBound(to: Double.self)
                var meanSquare: Double = 0
                vDSP_measqvD(pointer, 1, &meanSquare, vDSP_Length(samples))
                sumOfSquares += meanSquare * Double(samples)
                totalSamples += samples
            case .pcmFormatInt16:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int16>.size
                guard samples > 0 else { continue }
                let pointer = baseAddress.assumingMemoryBound(to: Int16.self)
                let meanSquare = withFloatScratch(count: samples) { scratch -> Float in
                    vDSP_vflt16(pointer, 1, scratch, 1, vDSP_Length(samples))
                    var value: Float = 0
                    vDSP_measqv(scratch, 1, &value, vDSP_Length(samples))
                    return value
                }
                // scratch holds the raw Int16 magnitudes; normalize by dividing
                // the mean-square by 32768^2 (equivalent to scaling each sample
                // by 1/32768 before squaring).
                sumOfSquares += (Double(meanSquare) / (32768.0 * 32768.0)) * Double(samples)
                totalSamples += samples
            case .pcmFormatInt32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                guard samples > 0 else { continue }
                let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
                let meanSquare = withFloatScratch(count: samples) { scratch -> Float in
                    vDSP_vflt32(pointer, 1, scratch, 1, vDSP_Length(samples))
                    var value: Float = 0
                    vDSP_measqv(scratch, 1, &value, vDSP_Length(samples))
                    return value
                }
                sumOfSquares += (Double(meanSquare) / (2147483648.0 * 2147483648.0)) * Double(samples)
                totalSamples += samples
            default:
                continue
            }
        }

        guard totalSamples > 0 else { return 0 }
        return Float(sqrt(sumOfSquares / Double(totalSamples)))
    }

    private func emitPCM16IfNeeded(_ inputBuffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) {
        guard let handler = onPCM16Samples else { return }

        let converter = pcm16ConverterLock.withLock { existing -> AVAudioConverter? in
            if let existing, existing.inputFormat == sourceFormat {
                return existing
            }
            let new = AVAudioConverter(from: sourceFormat, to: pcm16TargetFormat)
            new?.sampleRateConverterQuality = Self.configuredConverterQuality().rawValue
            existing = new
            return new
        }
        guard let converter else { return }

        guard let conversion = try? convertBuffer(
            inputBuffer,
            from: sourceFormat,
            using: converter,
            to: pcm16TargetFormat
        ) else { return }
        let outputBuffer = conversion.buffer

        let outputFrames = Int(outputBuffer.frameLength)
        guard outputFrames > 0, let int16Ptr = outputBuffer.int16ChannelData?[0] else {
            return
        }
        let byteCount = outputFrames * MemoryLayout<Int16>.size
        let data = Data(bytes: int16Ptr, count: byteCount)
        handler(data)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard _recording.withLock({ $0 }) else { return }

        // Decode the incoming sample buffer exactly once and share the decoded
        // PCM buffer across the file writer, realtime stream, and level meter.
        // Previously each of these independently rebuilt the AVAudioFormat and
        // copied the PCM data (3x per buffer, ~100x/sec).
        let decoded: DecodedSampleBuffer?
        do {
            decoded = try decodeSampleBuffer(sampleBuffer)
            if let decoded {
                try appendDecodedBufferToFile(decoded.buffer, sourceFormat: decoded.sourceFormat)
            }
        } catch {
            fileWriteErrorLock.withLock { _ in
                fileWriteError = error
            }
            os_log(.error, log: recordingLog, "audio file write failed: %{public}@", error.localizedDescription)
            reportRecordingFailure(error)
            return
        }

        if let decoded {
            emitPCM16IfNeeded(decoded.buffer, sourceFormat: decoded.sourceFormat)
        }

        let count = _bufferCount.withLock { value -> Int in
            value += 1
            return value
        }

        let rms = decoded.map { updateAudioLevel(from: $0.buffer) } ?? 0
        if count <= Self.sampleRateLogLimit {
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: recordingLog, "buffer #%d at %.3fms, rms=%.6f", count, elapsed, rms)
        }

        if !readyFired && rms > 0 {
            readyFired = true
            let elapsed = (CFAbsoluteTimeGetCurrent() - recordingStartTime) * 1000
            os_log(.info, log: recordingLog, "FIRST non-silent buffer at %.3fms — recording ready", elapsed)
            DispatchQueue.main.async {
                self.onRecordingReady?()
            }
        }
    }
}
