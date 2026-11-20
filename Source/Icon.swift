import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let frame = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210)
NSGradient(starting: NSColor(red: 0.21, green: 0.15, blue: 0.38, alpha: 1), ending: NSColor(red: 0.085, green: 0.075, blue: 0.15, alpha: 1))!.draw(in: frame, angle: -55)
NSColor(red: 0.67, green: 0.56, blue: 1, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 230, y: 270, width: 564, height: 445), xRadius: 65, yRadius: 65).fill()
NSColor(red: 0.15, green: 0.11, blue: 0.27, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 262, y: 302, width: 500, height: 381), xRadius: 39, yRadius: 39).fill()
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 457, y: 390))
triangle.line(to: NSPoint(x: 457, y: 593))
triangle.line(to: NSPoint(x: 620, y: 492))
triangle.close()
NSColor(red: 0.80, green: 0.73, blue: 1, alpha: 1).setFill()
triangle.fill()
for (x, y, size) in [(733.0, 770.0, 48.0), (270.0, 785.0, 24.0), (790.0, 208.0, 23.0)] {
    let star = NSBezierPath()
    star.move(to: NSPoint(x: x, y: y + size))
    star.line(to: NSPoint(x: x + size * 0.27, y: y + size * 0.27))
    star.line(to: NSPoint(x: x + size, y: y))
    star.line(to: NSPoint(x: x + size * 0.27, y: y - size * 0.27))
    star.line(to: NSPoint(x: x, y: y - size))
    star.line(to: NSPoint(x: x - size * 0.27, y: y - size * 0.27))
    star.line(to: NSPoint(x: x - size, y: y))
    star.line(to: NSPoint(x: x - size * 0.27, y: y + size * 0.27))
    star.close()
    star.fill()
}
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("work/icon.png"))
var chunks = Data()
func bigEndian(_ value: UInt32) -> Data {
    var bytes = value.bigEndian
    return withUnsafeBytes(of: &bytes) { Data($0) }
}
for (size, type) in [(16, "icp4"), (32, "icp5"), (64, "icp6"), (128, "ic07"), (256, "ic08"), (512, "ic09"), (1024, "ic10")] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    let png = rep.representation(using: .png, properties: [:])!
    chunks.append(Data(type.utf8))
    chunks.append(bigEndian(UInt32(png.count + 8)))
    chunks.append(png)
}
var icns = Data("icns".utf8)
icns.append(bigEndian(UInt32(chunks.count + 8)))
icns.append(chunks)
try icns.write(to: root.appendingPathComponent("Source/AppIcon.icns"))
