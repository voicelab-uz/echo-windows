import AppKit
import QuartzCore
import SwiftUI

/// Reveals the live window beneath a temporary, in-memory image of its old appearance.
/// The existing SwiftUI hierarchy (including scroll and editor state) stays in place.
@MainActor
final class AppearanceTransition: NSObject {
    weak var anchor: NSView?
    private var overlay: NSView?
    private var animationTask: Task<Void, Never>?
    private var destination: String?

    func change(to appearance: String, reduceMotion: Bool, apply: () -> Void) {
        guard overlay == nil else { return }
        guard !reduceMotion,
            let anchor, let window = anchor.window,
            let surface = window.contentView?.superview,
            window.isVisible, !window.isMiniaturized,
            let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)
        else {
            apply()
            return
        }

        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        guard let image = bitmap.cgImage else {
            apply()
            return
        }

        let snapshot = AppearanceSnapshotView(frame: surface.bounds)
        // Host our own layer so an AppKit redraw cannot replace the captured image.
        let layer = CALayer()
        snapshot.layer = layer
        snapshot.wantsLayer = true
        layer.contents = image
        layer.contentsScale = window.backingScaleFactor
        layer.contentsGravity = .resize
        surface.addSubview(snapshot, positioned: .above, relativeTo: nil)

        // Convert after attachment: the toolbar and content can use different coordinate systems.
        let origin = snapshot.convert(NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), from: anchor)
        let bounds = snapshot.bounds
        let radius =
            hypot(
                max(abs(origin.x - bounds.minX), abs(bounds.maxX - origin.x)),
                max(abs(origin.y - bounds.minY), abs(bounds.maxY - origin.y))
            ) + 2
        let expands = appearance == "light"
        let start = maskPath(bounds: bounds, origin: origin, radius: expands ? 0.01 : radius, hole: expands)
        let end = maskPath(bounds: bounds, origin: origin, radius: expands ? radius : 0.01, hole: expands)
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.fillRule = .evenOdd
        mask.fillColor = NSColor.black.cgColor
        mask.path = start
        layer.mask = mask
        overlay = snapshot
        destination = appearance

        for name in [
            NSWindow.willCloseNotification, NSWindow.willMiniaturizeNotification,
            NSWindow.willStartLiveResizeNotification, NSWindow.didResizeNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(cancel), name: name, object: window)
        }

        apply()

        animationTask = Task { @MainActor [weak self, weak snapshot] in
            // Let SwiftUI apply the new color scheme under the still-opaque snapshot first.
            try? await Task.sleep(for: .milliseconds(32))
            guard !Task.isCancelled, let self, let snapshot, self.overlay === snapshot else { return }
            let duration = 0.58
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            mask.path = end
            let reveal = CABasicAnimation(keyPath: "path")
            reveal.fromValue = start
            reveal.toValue = end
            reveal.duration = duration
            reveal.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            mask.add(reveal, forKey: "appearanceReveal")
            CATransaction.commit()

            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self.cancel()
        }
    }

    func cancelIfDestinationChanged(to appearance: String) {
        if let destination, destination != appearance { cancel() }
    }

    @objc func cancel() {
        animationTask?.cancel()
        animationTask = nil
        overlay?.removeFromSuperview()
        overlay = nil
        destination = nil
        NotificationCenter.default.removeObserver(self)
    }

    private func maskPath(bounds: CGRect, origin: CGPoint, radius: CGFloat, hole: Bool) -> CGPath {
        let path = CGMutablePath()
        if hole { path.addRect(bounds) }
        path.addEllipse(
            in: CGRect(x: origin.x - radius, y: origin.y - radius, width: radius * 2, height: radius * 2))
        return path
    }
}

private final class AppearanceSnapshotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func accessibilityHitTest(_ point: NSPoint) -> Any? { nil }
}

/// Measures the actual toolbar button without imposing any window layout constraints.
struct AppearanceTransitionAnchor: NSViewRepresentable {
    let transition: AppearanceTransition

    func makeCoordinator() -> AppearanceTransition { transition }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.setAccessibilityElement(false)
        transition.anchor = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        transition.anchor = nsView
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: AppearanceTransition) {
        coordinator.cancel()
        coordinator.anchor = nil
    }
}
