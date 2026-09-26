import AppKit
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.36, blue: 0.85, alpha: 1),
           ending: NSColor(calibratedRed: 0.02, green: 0.62, blue: 0.55, alpha: 1))!.draw(in: path, angle: -60)
let cfg = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let sym = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud.fill", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
    let tinted = NSImage(size: sym.size); tinted.lockFocus()
    sym.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set(); NSRect(origin: .zero, size: sym.size).fill(using: .sourceAtop); tinted.unlockFocus()
    tinted.draw(in: NSRect(x: (size - sym.size.width)/2, y: (size - sym.size.height)/2 + 10, width: sym.size.width, height: sym.size.height))
}
let label = "" as NSString
let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 120, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.9)]
let ls = label.size(withAttributes: attrs)
label.draw(at: NSPoint(x: (size - ls.width)/2, y: 150), withAttributes: attrs)
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
