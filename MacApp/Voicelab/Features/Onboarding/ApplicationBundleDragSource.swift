import AppKit
import SwiftUI

/// Drags the installed app itself. SwiftUI's item-provider file drag can materialize
/// a second .app in its cache, which Settings may register instead of the running app.
struct ApplicationBundleDragSource: NSViewRepresentable {
    let applicationURL: URL

    func makeNSView(context: Context) -> ApplicationBundleDragView {
        ApplicationBundleDragView(applicationURL: applicationURL)
    }

    func updateNSView(_ view: ApplicationBundleDragView, context: Context) {
        view.applicationURL = applicationURL
    }
}

@MainActor
final class ApplicationBundleDragView: NSView, NSDraggingSource {
    var applicationURL: URL
    private var mouseDownLocation: NSPoint?
    private var isDragging = false

    init(applicationURL: URL) {
        self.applicationURL = applicationURL
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let origin = mouseDownLocation else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - origin.x, location.y - origin.y) >= 4 else { return }
        let item = Self.draggingItem(for: applicationURL)
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        item.setDraggingFrame(NSRect(x: location.x - 18, y: location.y - 18, width: 36, height: 36),
                              contents: icon)
        isDragging = true
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
    }

    static func draggingItem(for applicationURL: URL) -> NSDraggingItem {
        // NSURL writes public.file-url immediately. No file promise, provider, or copy.
        NSDraggingItem(pasteboardWriter: applicationURL as NSURL)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownLocation = nil
        isDragging = false
        // Drop acceptance is not proof of permission. The guide continues its OS trust check.
    }
}
