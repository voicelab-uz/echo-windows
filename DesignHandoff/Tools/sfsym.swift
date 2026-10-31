import AppKit
// usage: sfsym <symbol> <out.png> <size> <hexColor>  (reference only — SF Symbols are Apple-only)
let a = CommandLine.arguments
let size = CGFloat(Double(a[3])!)
let v = UInt32(a[4].replacingOccurrences(of: "#", with: ""), radix: 16)!
let color = NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255,
                    blue: CGFloat(v & 255) / 255, alpha: 1)
let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.8, weight: .regular)
let img = NSImage(systemSymbolName: a[1], accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
let px = Int(size)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let r = NSRect(x: 0, y: 0, width: size, height: size)
let fit = img.size.width > img.size.height
    ? NSRect(x: 0, y: (size - size * img.size.height / img.size.width) / 2, width: size, height: size * img.size.height / img.size.width)
    : NSRect(x: (size - size * img.size.width / img.size.height) / 2, y: 0, width: size * img.size.width / img.size.height, height: size)
img.draw(in: fit)
color.set(); r.fill(using: .sourceIn)
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))
