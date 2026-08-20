import ApplicationServices

/// Helpers for talking to other applications over the Accessibility API.
///
/// `AXUIElementCopyAttributeValue` is **synchronous cross-process IPC**: it
/// posts a message to the target application's run loop and blocks until that
/// app answers. The system default messaging timeout is 6 seconds, so a
/// beachballing (or merely slow) frontmost app can stall whichever of our
/// threads made the call — and some of these calls run on the main thread the
/// instant the dictation hotkey fires.
///
/// Every `AXUIElement` this app creates must therefore carry an explicit
/// timeout. Create them through ``AccessibilityIPC/applicationElement(for:)``
/// rather than calling `AXUIElementCreateApplication` directly so the bound
/// cannot be forgotten at a new call site.
enum AccessibilityIPC {
    /// Per-message ceiling for Accessibility IPC, in seconds.
    ///
    /// A healthy application answers an attribute query in single-digit
    /// milliseconds; even Electron and JVM apps land well inside 100 ms. 250 ms
    /// leaves an order of magnitude of headroom while capping a full selection
    /// snapshot (four chained queries) at ~1 s instead of the default 24 s.
    ///
    /// The tradeoff is deliberate: if a target app cannot answer in time we
    /// degrade to a snapshot without selected text, which is far better than
    /// failing to start recording at all.
    static let messagingTimeout: Float = 0.25

    /// An `AXUIElement` for `processIdentifier` with ``messagingTimeout``
    /// already applied. The timeout governs every message subsequently sent to
    /// this element and to elements copied out of it.
    static func applicationElement(for processIdentifier: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return element
    }
}
