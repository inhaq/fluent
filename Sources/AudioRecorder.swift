import Accelerate
import AVFoundation
import CoreMedia
import Foundation
import os.log

private let recordingLog = OSLog(subsystem: "com.zachlatta.freeflow", category: "Recording")

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

final class AudioRecorder: NSObject, ObservableObject, AVCaptureAudioDataOutputSampleBufferDelegate {
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
    private let sessionQueue = DispatchQueue(label: "com.zachlatta.freeflow.capture.session")
    private let sampleBufferQueue = DispatchQueue(label: "com.zachlatta.freeflow.capture.samples")
    private var activeAudioFile: AVAudioFile?
    private var activeAudioFormat: AVAudioFormat?
    private var recordedFrameCount: AVAudioFramePosition = 0
    private var loggedCaptureFormat = false
    private var fileWriteError: Error?
    private var isSessionInterrupted = false
    // Cached source format for the active capture session. Building an
    // AVAudioFormat from the sample buffer's format description on every
    // callback (~100x/sec) is wasteful; the format is constant for the
    // lifetime of a session, so cache it keyed by the format description.
    private var cachedSourceFormatDescription: CMFormatDescription?
    private var cachedSourceFormat: AVAudioFormat?
    // UID of the device the current capture session is configured for. Lets the
    // recording path reuse a pre-warmed session only when the device matches.
    private var currentDeviceUID: String?
    // True while an idle session is kept running ahead of recording (prewarm).
    private var isPrewarmed = false
    private var prewarmCooldownTimer: DispatchSourceTimer?
    private static let prewarmIdleTimeout: TimeInterval = 20.0
    // Throttle state for publishing the live audio level to the UI.
    private var lastAudioLevelPublish: CFAbsoluteTime = 0
    private static let audioLevelPublishInterval: CFTimeInterval = 1.0 / 30.0

    @Published var isRecording = false
    private let _recording = OSAllocatedUnfairLock(initialState: false)
    @Published var audioLevel: Float = 0.0
    private let liveLevelNormalizerLock = OSAllocatedUnfairLock(initialState: LiveAudioLevelNormalizer())

    var onRecordingReady: (() -> Void)?
    var onRecordingFailure: ((Error) -> Void)?
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

        let runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let wrapped = error.map { AudioRecorderError.failedToStartCaptureSession($0.localizedDescription) }
                ?? AudioRecorderError.failedToStartCaptureSession("Unknown runtime error")
            self?.reportRecordingFailure(wrapped)
        }
        sessionObservers.append(runtimeObserver)

        let interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterrupted(notification)
        }
        sessionObservers.append(interruptionObserver)

        let interruptionEndedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: nil
        ) { [weak self] notification in
            self?.handleSessionInterruptionEnded(notification)
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
        isSessionInterrupted = false
        isPrewarmed = false
        currentDeviceUID = nil

        audioDataOutput?.setSampleBufferDelegate(nil, queue: nil)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }

        captureSession = nil
        currentInput = nil
        audioDataOutput = nil
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
            guard !self.isSessionInterrupted else {
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

    private func handleSessionInterrupted(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = true
            self.cancelWatchdog()
            os_log(.info, log: recordingLog, "capture session interrupted — waiting for recovery")
        }
    }

    private func handleSessionInterruptionEnded(_ notification: Notification) {
        _ = notification
        sessionQueue.async {
            guard self._recording.withLock({ $0 }) else { return }
            self.isSessionInterrupted = false
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

        // Reuse a pre-warmed, already-running session for the same device so
        // recording starts without paying AVCaptureSession.startRunning() again.
        if isPrewarmed,
           let session = captureSession,
           session.isRunning,
           currentDeviceUID == device.uniqueID {
            isPrewarmed = false
            resetFileWritingStateLocked()
            tempFileURL = outputURL
            os_log(.info, log: recordingLog, "reusing pre-warmed capture session for %{public}@", device.localizedName)
            return
        }

        try configureSessionLocked(device: device)
        isPrewarmed = false
        resetFileWritingStateLocked()
        tempFileURL = outputURL
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
        isSessionInterrupted = false
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
        fileWriteErrorLock.withLock { _ in
            fileWriteError = nil
        }
    }

    /// Pre-warms an idle capture session so the next ``startRecording`` can skip
    /// the `AVCaptureSession.startRunning()` cost (the dominant first-record
    /// latency). While warm the session runs but every sample buffer is dropped
    /// in ``captureOutput`` because `_recording` is false (nothing is written or
    /// metered). To bound battery use and the time the system mic-in-use
    /// indicator stays lit, a warm session auto-cools-down after
    /// ``prewarmIdleTimeout`` if no recording starts. No-op while recording.
    func prewarm(deviceUID: String? = nil) {
        sessionQueue.async {
            guard !self._recording.withLock({ $0 }) else { return }
            do {
                let device = try self.preferredCaptureDevice(for: deviceUID, reason: "prewarm")
                if let session = self.captureSession,
                   session.isRunning,
                   self.currentDeviceUID == device.uniqueID {
                    // Already warm with the right device; just refresh the timer.
                    self.isPrewarmed = true
                    self.schedulePrewarmCooldownLocked()
                    return
                }
                try self.configureSessionLocked(device: device)
                self.isPrewarmed = true
                self.schedulePrewarmCooldownLocked()
                os_log(.info, log: recordingLog, "capture session pre-warmed with %{public}@", device.localizedName)
            } catch {
                os_log(.error, log: recordingLog, "prewarm failed: %{public}@", error.localizedDescription)
                self.teardownSessionLocked()
                self.isPrewarmed = false
            }
        }
    }

    /// Tears down a pre-warmed idle session. No-op while recording (the active
    /// recording owns the session).
    func stopPrewarm() {
        sessionQueue.async {
            guard self.isPrewarmed, !self._recording.withLock({ $0 }) else { return }
            self.cancelPrewarmCooldownLocked()
            self.teardownSessionLocked()
            self.isPrewarmed = false
            os_log(.info, log: recordingLog, "pre-warmed capture session torn down")
        }
    }

    private func schedulePrewarmCooldownLocked() {
        cancelPrewarmCooldownLocked()
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + Self.prewarmIdleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.isPrewarmed, !self._recording.withLock({ $0 }) else { return }
            self.cancelPrewarmCooldownLocked()
            self.teardownSessionLocked()
            self.isPrewarmed = false
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
            self.cancelWatchdog()
            self.teardownSessionLocked()
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
            self.cancelWatchdog()
            self.teardownSessionLocked()
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

    func cleanup() {
        let cleanup = {
            if let url = self.tempFileURL {
                try? FileManager.default.removeItem(at: url)
                self.tempFileURL = nil
            }
        }

        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) != nil {
            cleanup()
        } else {
            sessionQueue.sync(execute: cleanup)
        }
    }

    /// Enhances a recorded PCM WAV for speech recognition and writes the result
    /// to a new temporary WAV. Two stages are applied:
    ///
    /// 1. An 80 Hz first-order high-pass filter that removes DC offset and
    ///    sub-speech rumble (HVAC, mic handling, desk thumps). Whisper's mel
    ///    front-end is robust to absolute loudness but sensitive to SNR, so
    ///    stripping low-frequency energy outside the speech band raises the
    ///    effective SNR of quiet/soft speech and improves word recognition.
    /// 2. Loudness normalization toward a consistent target RMS, with a peak
    ///    ceiling and a capped makeup gain, so faint dictation reaches the model
    ///    at a predictable level. It never attenuates.
    ///
    /// The operation is intentionally conservative and self-healing:
    /// - Silent clips (RMS below ``silenceRMSFloor``) are skipped so we never
    ///   amplify the noise floor.
    /// - Makeup gain is capped (``maxMakeupGain``) and limited so the peak can
    ///   never exceed ``peakCeiling``. If the high-passed signal already
    ///   overshoots the ceiling, enhancement is abandoned (returns `nil`) so the
    ///   caller uploads the original rather than a clipped version. A final
    ///   hard clip to [-1, 1] only guards the float-to-Int16 write.
    /// - Any failure returns `nil`.
    ///
    /// - Returns: A new temporary WAV URL the caller should upload (and delete
    ///   afterward), or `nil` when enhancement was skipped or failed — in which
    ///   case the caller must upload the original file unchanged.
    static func enhancedWAV(at sourceURL: URL) -> URL? {
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
            let sampleRate = Float(format.sampleRate)
            let rc = 1 / (2 * Float.pi * highPassCutoffHz)
            let dt = 1 / sampleRate
            let alpha = rc / (rc + dt)
            for channel in 0..<channelCount {
                let samples = channels[channel]
                var previousInput = samples[0]
                var previousOutput: Float = 0
                for index in 0..<frames {
                    let input = samples[index]
                    let output = alpha * (previousOutput + input - previousInput)
                    samples[index] = output
                    previousInput = input
                    previousOutput = output
                }
            }

            // --- Stage 2: measure post-filter loudness/peak, apply safe gain ---
            var summedMeanSquare: Float = 0
            var peak: Float = 0
            for channel in 0..<channelCount {
                var meanSquare: Float = 0
                vDSP_measqv(channels[channel], 1, &meanSquare, vDSP_Length(frames))
                summedMeanSquare += meanSquare
                var channelPeak: Float = 0
                vDSP_maxmgv(channels[channel], 1, &channelPeak, vDSP_Length(frames))
                peak = max(peak, channelPeak)
            }
            let rms = sqrt(summedMeanSquare / Float(channelCount))
            guard rms > 0, peak > 0 else { return nil }

            // Target the desired RMS, but never amplify beyond the cap and
            // never let the loudest sample exceed the ceiling. If the
            // high-passed signal already overshoots the ceiling, bail out so
            // the caller uploads the untouched original rather than a clipped
            // version.
            let peakLimitedGain = peakCeiling / peak
            guard peakLimitedGain >= 1 else {
                return nil
            }
            // Never attenuate (floor at 1), and keep the peak under the ceiling.
            let desiredGain = max(targetRMS / rms, 1)
            let gain = min(desiredGain, maxMakeupGain, peakLimitedGain)

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
                var floats = [Float](repeating: 0, count: samples)
                vDSP_vflt16(pointer, 1, &floats, 1, vDSP_Length(samples))
                var meanSquare: Float = 0
                vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(samples))
                // floats are the raw Int16 magnitudes; normalize by dividing the
                // mean-square by 32768^2 (equivalent to scaling each sample by
                // 1/32768 before squaring).
                sumOfSquares += (Double(meanSquare) / (32768.0 * 32768.0)) * Double(samples)
                totalSamples += samples
            case .pcmFormatInt32:
                let samples = Int(audioBuffer.mDataByteSize) / MemoryLayout<Int32>.size
                guard samples > 0 else { continue }
                let pointer = baseAddress.assumingMemoryBound(to: Int32.self)
                var floats = [Float](repeating: 0, count: samples)
                vDSP_vflt32(pointer, 1, &floats, 1, vDSP_Length(samples))
                var meanSquare: Float = 0
                vDSP_measqv(floats, 1, &meanSquare, vDSP_Length(samples))
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
