import AppKit

/// The Echo app-icon mark (two overlapping pills) as a menu bar template image.
/// Drawn in code so it stays crisp at any scale and takes the system's menu bar tint.
@MainActor
enum MenuBarIcon {
    static let mark = makeMark(recording: false)
    static let recording = makeMark(recording: true)

    private static func makeMark(recording: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // Proportions taken from the 512 pt app icon: both pills are 152 wide,
            // the left one is 240 tall, the right one 290 tall, bottoms aligned,
            // overlapping by about 30. Scale so the taller pill spans 14 pt.
            let height: CGFloat = 14
            let scale = height / 290
            let pillWidth = 152 * scale
            let leftHeight = 240 * scale
            let overlap = 30 * scale
            let totalWidth = pillWidth * 2 - overlap
            let originX = ((rect.width - totalWidth) / 2).rounded(.down) + 0.5
            let originY = ((rect.height - height) / 2).rounded(.down)
            let left = CGRect(x: originX, y: originY, width: pillWidth, height: leftHeight)
            let right = CGRect(x: originX + pillWidth - overlap, y: originY, width: pillWidth, height: height)

            context.setFillColor(NSColor.black.cgColor)
            context.addPath(capsule(right))
            context.fillPath()
            // Carve a hairline around the front pill so the two shapes stay readable at 18 pt.
            context.setBlendMode(.destinationOut)
            context.addPath(capsule(left.insetBy(dx: -1, dy: -1)))
            context.fillPath()
            context.setBlendMode(.normal)
            context.addPath(capsule(left))
            context.fillPath()

            if recording {
                // A small knocked-out dot on the taller pill signals an active recording.
                let dot = CGRect(x: right.midX - 2, y: right.maxY - 6, width: 4, height: 4)
                context.setBlendMode(.destinationOut)
                context.fillEllipse(in: dot.insetBy(dx: -1, dy: -1))
                context.setBlendMode(.normal)
                context.fillEllipse(in: dot)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Echo"
        return image
    }

    private static func capsule(_ rect: CGRect) -> CGPath {
        let radius = min(rect.width, rect.height) / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
