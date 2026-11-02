import SwiftUI

/// Rendering fills behind the physical camera to avoid a subpixel seam.
/// Hit-testing alone cuts out the hardware area using a counter-wound path.
struct CameraIslandShape: Shape {
    var cameraWidth: CGFloat
    var cameraHeight: CGFloat
    var shoulder: CGFloat
    var bottomRadius: CGFloat
    var excludesCamera = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set {
            shoulder = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let shoulder = min(max(0, shoulder), rect.height / 2)
        let radius = min(max(0, bottomRadius), rect.height / 2, (rect.width - shoulder * 2) / 2)
        let left = rect.minX + shoulder
        let right = rect.maxX - shoulder
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: right, y: rect.minY + shoulder),
            control: CGPoint(x: right, y: rect.minY))
        path.addLine(to: CGPoint(x: right, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: right - radius, y: rect.maxY),
            control: CGPoint(x: right, y: rect.maxY))
        path.addLine(to: CGPoint(x: left + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.maxY - radius),
            control: CGPoint(x: left, y: rect.maxY))
        path.addLine(to: CGPoint(x: left, y: rect.minY + shoulder))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.minY),
            control: CGPoint(x: left, y: rect.minY))
        path.closeSubpath()

        guard excludesCamera, cameraHeight > 0 else { return path }
        let cameraLeft = rect.midX - cameraWidth / 2
        let cameraRight = rect.midX + cameraWidth / 2
        let cameraBottom = rect.minY + cameraHeight
        let corner = min(8, cameraHeight / 2, cameraWidth / 2)
        path.move(to: CGPoint(x: cameraLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: cameraLeft, y: cameraBottom - corner))
        path.addQuadCurve(
            to: CGPoint(x: cameraLeft + corner, y: cameraBottom),
            control: CGPoint(x: cameraLeft, y: cameraBottom))
        path.addLine(to: CGPoint(x: cameraRight - corner, y: cameraBottom))
        path.addQuadCurve(
            to: CGPoint(x: cameraRight, y: cameraBottom - corner),
            control: CGPoint(x: cameraRight, y: cameraBottom))
        path.addLine(to: CGPoint(x: cameraRight, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
