import Cocoa

final class HotkeyManager {
    private let backend = GlobalShortcutBackend()
    private let stateLock = NSLock()
    private var configuration = ShortcutConfiguration(
        hold: .defaultHold,
        toggle: .defaultToggle
    )
    private var inputState = ShortcutInputState()
    private var shortcutEventHandler: ((ShortcutEvent) -> Void)?
    private var escapeKeyHandler: (() -> Bool)?
    private var inputsReleasedHandler: (() -> Void)?

    var onShortcutEvent: ((ShortcutEvent) -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return shortcutEventHandler
        }
        set {
            stateLock.lock()
            shortcutEventHandler = newValue
            stateLock.unlock()
        }
    }

    var onEscapeKeyPressed: (() -> Bool)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return escapeKeyHandler
        }
        set {
            stateLock.lock()
            escapeKeyHandler = newValue
            stateLock.unlock()
        }
    }

    /// Fires once when the currently-pressed shortcut inputs transition from
    /// held to fully released — on the event-tap thread, the instant the tap
    /// observes the release. Callers must hop to their own queue. Reassigned
    /// per wait; the previous handler is consumed by the first transition.
    ///
    /// This replaces release *polling* for the paste path: the paste can be
    /// scheduled the moment keys come up rather than on the next 25 ms tick.
    var onShortcutInputsReleased: (() -> Void)? {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return inputsReleasedHandler
        }
        set {
            stateLock.lock()
            inputsReleasedHandler = newValue
            stateLock.unlock()
        }
    }

    var currentPressedModifiers: ShortcutModifiers {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputState.currentModifiers
    }

    var hasPressedShortcutInputs: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return inputState.hasPressedShortcutInputs(configuration: configuration)
    }

    func start(configuration: ShortcutConfiguration) throws {
        stop()
        stateLock.lock()
        self.configuration = configuration
        inputState = ShortcutInputState()
        stateLock.unlock()
        backend.onInputEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? .passthrough
        }
        backend.onEscapeKeyPressed = { [weak self] in
            guard let self else { return false }
            let handler = self.lockedEscapeKeyHandler()
            return handler?() ?? false
        }
        do {
            try backend.start()
        } catch {
            backend.onInputEvent = nil
            backend.onEscapeKeyPressed = nil
            stateLock.lock()
            inputState = ShortcutInputState()
            stateLock.unlock()
            throw error
        }
    }

    func stop() {
        // Clear the release handler BEFORE tearing down the backend: stop()
        // emits `.backendReset` through the event pipeline, which would
        // otherwise look like a held->released transition and fire a spurious
        // paste while the shortcut is still physically held.
        stateLock.lock()
        inputsReleasedHandler = nil
        stateLock.unlock()
        backend.stop()
        backend.onInputEvent = nil
        backend.onEscapeKeyPressed = nil
        stateLock.lock()
        inputState = ShortcutInputState()
        stateLock.unlock()
    }

    deinit {
        stop()
    }

    private func handleInputEvent(_ event: ShortcutInputEvent) -> ShortcutConsumeDecision {
        stateLock.lock()
        // A backend reset is bookkeeping, not a physical key release — never
        // run release detection for it (stop() clears the handler first, this
        // guards any other emitter).
        let releaseDetectionEligible = event != .backendReset
        let wasPressed = releaseDetectionEligible
            && inputState.hasPressedShortcutInputs(configuration: configuration)
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        let isPressed = inputState.hasPressedShortcutInputs(configuration: configuration)
        var releaseHandler: (() -> Void)?
        if wasPressed && !isPressed {
            releaseHandler = inputsReleasedHandler
            inputsReleasedHandler = nil
        }
        let handler = shortcutEventHandler
        stateLock.unlock()

        if let releaseHandler {
            releaseHandler()
        }
        for event in result.emittedEvents {
            handler?(event)
        }
        return result.consumeDecision
    }

    private func lockedEscapeKeyHandler() -> (() -> Bool)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return escapeKeyHandler
    }
}
