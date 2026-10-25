import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for pixels in [16, 32, 64, 128, 256, 512, 1024] {
    let image = NSImage(size: NSSize(width: pixels, height: pixels))
    image.lockFocus()
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    NSColor(calibratedRed: 0.12, green: 0.33, blue: 0.77, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 210, yRadius: 210).fill()
    NSColor.white.setStroke()
    let screen = NSBezierPath(roundedRect: NSRect(x: 214, y: 310, width: 596, height: 430), xRadius: 34, yRadius: 34)
    screen.lineWidth = 42; screen.stroke()
    let stand = NSBezierPath(); stand.lineWidth = 42; stand.lineCapStyle = .round
    stand.move(to: NSPoint(x: 512, y: 310)); stand.line(to: NSPoint(x: 512, y: 215))
    stand.move(to: NSPoint(x: 382, y: 215)); stand.line(to: NSPoint(x: 642, y: 215)); stand.stroke()
    let arrow = NSBezierPath(); arrow.lineWidth = 44; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    arrow.move(to: NSPoint(x: 355, y: 525)); arrow.line(to: NSPoint(x: 665, y: 525))
    arrow.move(to: NSPoint(x: 560, y: 630)); arrow.line(to: NSPoint(x: 665, y: 525)); arrow.line(to: NSPoint(x: 560, y: 420)); arrow.stroke()
    image.unlockFocus()
    let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
    let png = bitmap.representation(using: .png, properties: [:])!
    if pixels <= 512 { try png.write(to: directory.appendingPathComponent("icon_\(pixels)x\(pixels).png")) }
    if pixels >= 32 { try png.write(to: directory.appendingPathComponent("icon_\(pixels/2)x\(pixels/2)@2x.png")) }
}
