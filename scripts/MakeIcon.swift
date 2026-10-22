import AppKit

let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor(srgbRed: 0.09, green: 0.11, blue: 0.15, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 190, yRadius: 190).fill()
let left = NSBezierPath()
left.move(to: NSPoint(x: 280, y: 690))
left.line(to: NSPoint(x: 480, y: 315))
left.lineWidth = 76
left.lineCapStyle = .round
NSColor(srgbRed: 0.55, green: 0.72, blue: 1, alpha: 1).setStroke()
left.stroke()
let right = NSBezierPath()
right.move(to: NSPoint(x: 510, y: 315))
right.line(to: NSPoint(x: 744, y: 730))
right.lineWidth = 76
right.lineCapStyle = .round
NSColor(srgbRed: 0.53, green: 0.8, blue: 0.63, alpha: 1).setStroke()
right.stroke()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = bitmap.representation(using: .png, properties: [:])!
var icns = Data("icns".utf8)
var total = UInt32(16 + png.count).bigEndian
withUnsafeBytes(of: &total) { icns.append(contentsOf: $0) }
icns.append(Data("ic10".utf8))
var length = UInt32(8 + png.count).bigEndian
withUnsafeBytes(of: &length) { icns.append(contentsOf: $0) }
icns.append(png)
try icns.write(to: URL(fileURLWithPath: output))
