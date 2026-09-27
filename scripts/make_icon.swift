import AppKit

// A file archive rather than a cloud: three saved copies sit inside a sturdy storage tray.
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

func rounded(_ rect: NSRect, _ radius: CGFloat, _ color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

let background = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                              xRadius: 184, yRadius: 184)
NSGradient(starting: NSColor(calibratedRed: 0.06, green: 0.17, blue: 0.31, alpha: 1),
           ending: NSColor(calibratedRed: 0.08, green: 0.35, blue: 0.40, alpha: 1))!
    .draw(in: background, angle: -55)

// The stagger is visible at Dock size and reads as stored versions at small sizes.
rounded(NSRect(x: 356, y: 390, width: 366, height: 390), 34,
        NSColor(calibratedRed: 0.22, green: 0.73, blue: 0.74, alpha: 1))
rounded(NSRect(x: 304, y: 360, width: 366, height: 390), 34,
        NSColor(calibratedRed: 0.67, green: 0.88, blue: 0.88, alpha: 1))
rounded(NSRect(x: 254, y: 330, width: 366, height: 390), 34,
        NSColor(calibratedRed: 0.97, green: 0.98, blue: 0.98, alpha: 1))

// A single line on the front sheet survives downscaling without making it look like a document app.
rounded(NSRect(x: 318, y: 588, width: 220, height: 23), 11,
        NSColor(calibratedRed: 0.12, green: 0.47, blue: 0.52, alpha: 1))

// Open storage tray and its thick lip.
rounded(NSRect(x: 220, y: 218, width: 584, height: 292), 55,
        NSColor(calibratedRed: 0.05, green: 0.54, blue: 0.57, alpha: 1))
rounded(NSRect(x: 207, y: 472, width: 610, height: 60), 26,
        NSColor(calibratedRed: 0.15, green: 0.77, blue: 0.75, alpha: 1))

// Amber version marker: one restrained accent that distinguishes the app in the Dock.
let marker = NSBezierPath(ovalIn: NSRect(x: 454, y: 292, width: 116, height: 116))
NSColor(calibratedRed: 0.99, green: 0.72, blue: 0.30, alpha: 1).setFill()
marker.fill()
let hand = NSBezierPath()
hand.lineWidth = 12
hand.lineCapStyle = .round
hand.move(to: NSPoint(x: 512, y: 375))
hand.line(to: NSPoint(x: 512, y: 350))
hand.line(to: NSPoint(x: 534, y: 338))
NSColor(calibratedRed: 0.13, green: 0.25, blue: 0.34, alpha: 1).setStroke()
hand.stroke()

image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
