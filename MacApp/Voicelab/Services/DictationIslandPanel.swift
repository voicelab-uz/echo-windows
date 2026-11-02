import AppKit

/// Controls remain clickable without stealing the original text field's focus.
@MainActor
final class DictationIslandPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // This borderless overlay attaches to the physical top edge on every display,
    // including those without a camera cutout. Do not constrain it below the menu bar.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// AppKit coordinates: the U-shaped surface starts at the physical screen edge.
@MainActor
enum IslandGeometry {
    static func layout(on screen: NSScreen) -> IslandLayout {
        let height = screen.safeAreaInsets.top
        guard height > 0 else { return IslandLayout() }
        let width: CGFloat
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
            right.minX > left.maxX
        {
            width = right.minX - left.maxX
        } else {
            width = 180
        }
        return IslandLayout(cameraWidth: width, cameraHeight: height)
    }

    static func frame(on screen: NSScreen, layout: IslandLayout) -> NSRect {
        var center = screen.frame.midX
        if layout.cameraHeight > 0,
            let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
            right.minX > left.maxX
        {
            center = (left.maxX + right.minX) / 2
        }
        // visibleFrame excludes the menu bar and leaves a gap on notchless Macs.
        // Always anchor to the full display; camera insets only affect the contents.
        let top = screen.frame.maxY
        let size = layout.panelSize
        return NSRect(
            x: center - size.width / 2, y: top - size.height,
            width: size.width, height: size.height)
    }

    static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    static func screen(nearest point: NSPoint) -> NSScreen? {
        NSScreen.screens.min { a, b in
            distance(point, to: a.frame) < distance(point, to: b.frame)
        }
    }

    private static func distance(_ point: NSPoint, to rect: NSRect) -> CGFloat {
        hypot(
            max(rect.minX - point.x, 0, point.x - rect.maxX),
            max(rect.minY - point.y, 0, point.y - rect.maxY))
    }
}
