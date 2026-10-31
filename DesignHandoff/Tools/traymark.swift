import AppKit
// usage: traymark <out.png> <size> <hexColor> [recording]
// Exact port of the Mac menu bar mark (Voicelab/Shared/MenuBarIcon.swift), drawn at any size.
let a = CommandLine.arguments
let size = CGFloat(Double(a[2])!)
let v = UInt32(a[3].replacingOccurrences(of: "#", with: ""), radix: 16)!
let recording = a.count > 4 && a[4] == "recording"
let color = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                    blue: CGFloat(v & 255) / 255, alpha: 1)
let px = Int(size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
func capsule(_ r: CGRect) -> CGPath {
    let radius = min(r.width, r.height) / 2
    return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let context = NSGraphicsContext.current!.cgContext
let k = size / 18                      // the Mac draws on an 18 pt canvas
let height: CGFloat = 14 * k
let scale = height / 290
let pillWidth = 152 * scale, leftHeight = 240 * scale, overlap = 30 * scale
let totalWidth = pillWidth * 2 - overlap
let originX = (size - totalWidth) / 2, originY = (size - height) / 2
let left = CGRect(x: originX, y: originY, width: pillWidth, height: leftHeight)
let right = CGRect(x: originX + pillWidth - overlap, y: originY, width: pillWidth, height: height)
context.setFillColor(color.cgColor)
context.addPath(capsule(right)); context.fillPath()
context.setBlendMode(.destinationOut)
context.addPath(capsule(left.insetBy(dx: -1 * k, dy: -1 * k))); context.fillPath()
context.setBlendMode(.normal)
context.addPath(capsule(left)); context.fillPath()
if recording {
    let dot = CGRect(x: right.midX - 2 * k, y: right.maxY - 6 * k, width: 4 * k, height: 4 * k)
    context.setBlendMode(.destinationOut)
    context.fillEllipse(in: dot.insetBy(dx: -1 * k, dy: -1 * k))
    context.setBlendMode(.normal)
    context.fillEllipse(in: dot)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[1]))
