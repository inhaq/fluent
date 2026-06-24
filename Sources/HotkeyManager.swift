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
        let result = ShortcutMatcher.reduce(
            state: inputState,
            event: event,
            configuration: configuration
        )
        inputState = result.state
        let handler = shortcutEventHandler
        stateLock.unlock()

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
