import SwiftUI
import AppKit

/// A drop-in replacement for SwiftUI's `TextEditor` that fixes the macOS UX
/// problem where moving the pointer over a `TextEditor` traps the scroll wheel
/// and stops the surrounding `ScrollView` from scrolling.
///
/// The backing `NSScrollView` only consumes scroll-wheel events when it can
/// actually scroll its own content in the gesture's direction; otherwise it
/// forwards them up the responder chain so the enclosing page keeps scrolling.
/// Long editors still scroll their own content; short ones (the common case)
/// never block the page.
struct ScrollForwardingTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Font for the editor. SwiftUI's `.font(...)` modifier does not reach an
    /// `NSViewRepresentable`, so set the font here instead of via `.font()`.
    var font: NSFont = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ScrollChainingScrollView {
        let scrollView = ScrollChainingScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor

        let contentSize = scrollView.contentSize
        let textView = NSTextView(frame: NSRect(origin: .zero, size: contentSize))
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .textColor
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: ScrollChainingScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            let previousSelection = textView.selectedRange()
            textView.string = text
            let newLength = (text as NSString).length
            if previousSelection.location <= newLength {
                let clampedLength = min(previousSelection.length, newLength - previousSelection.location)
                textView.setSelectedRange(NSRange(location: previousSelection.location, length: max(0, clampedLength)))
            }
        }
        if textView.font != font {
            textView.font = font
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let parent: ScrollForwardingTextEditor
        weak var textView: NSTextView?

        init(_ parent: ScrollForwardingTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// An `NSScrollView` that only handles scroll-wheel events it can actually use,
/// forwarding the rest to the next responder so a parent scroll view continues
/// to scroll (a.k.a. scroll chaining).
final class ScrollChainingScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        if canScrollItself(for: event) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private func canScrollItself(for event: NSEvent) -> Bool {
        guard let documentView = documentView else { return false }

        let contentHeight = documentView.frame.height
        let visibleHeight = contentView.bounds.height
        // Content fits entirely: nothing to scroll, always forward to the page.
        guard contentHeight > visibleHeight + 0.5 else { return false }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return false }

        let offsetY = contentView.bounds.origin.y
        let maxOffsetY = contentHeight - visibleHeight

        if delta > 0 {
            // Scrolling toward the top: only consume if not already at the top.
            return offsetY > 0.5
        } else {
            // Scrolling toward the bottom: only consume if not already at the bottom.
            return offsetY < maxOffsetY - 0.5
        }
    }
}
