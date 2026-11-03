import AppKit

@main
struct ApplicationBundleDragRegression {
    @MainActor
    static func main() {
        // Exercise AppKit's real pasteboard writer/reader contract, including escaping.
        // Settings must receive the original file URL, not a promised/cache copy.
        let original = URL(fileURLWithPath: "/Applications/Echo user's build/Echo.app", isDirectory: true)
        let item = ApplicationBundleDragView.draggingItem(for: original)
        guard let writer = item.item as? NSPasteboardWriting else {
            preconditionFailure("The drag must offer an AppKit pasteboard writer.")
        }
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        precondition(pasteboard.writeObjects([writer]))
        precondition(pasteboard.types?.contains(.fileURL) == true)
        precondition(!(pasteboard.types ?? []).contains { $0.rawValue.lowercased().contains("promise") })
        let received = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        precondition(received == [original], "The receiving app must get the exact original bundle URL.")

        let view = ApplicationBundleDragView(applicationURL: original)
        precondition(!view.mouseDownCanMoveWindow, "Dragging the app must not move the floating guide.")
        precondition(view.acceptsFirstMouse(for: nil), "The guide must work while Settings is focused.")
        print("PASS: native app drag preserves the original file URL, has no file promise, and works from an inactive panel.")
    }
}
