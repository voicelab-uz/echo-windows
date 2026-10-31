import AppKit
// usage: svg2png <in.svg> <out.png> <size> <hexColor>
let a = CommandLine.arguments
let input = URL(fileURLWithPath: a[1]), output = URL(fileURLWithPath: a[2])
let size = CGFloat(Double(a[3])!)
let hex = a[4].replacingOccurrences(of: "#", with: "")
let keepColors = hex == "none"
let v = keepColors ? 0 : UInt32(hex, radix: 16)!
let color = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                    blue: CGFloat(v & 255) / 255, alpha: 1)
guard let svg = NSImage(contentsOf: input) else { fputs("cannot read \(a[1])\n", stderr); exit(1) }
let px = Int(size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let rect = NSRect(x: 0, y: 0, width: size, height: size)
svg.draw(in: rect)
// Tint: keep the icon's shape (alpha), fill with the brand color.
if !keepColors {
    color.set()
    rect.fill(using: .sourceIn)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: output)
