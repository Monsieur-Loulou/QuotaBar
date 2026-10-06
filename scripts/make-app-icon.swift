import AppKit
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 1024
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        NSColor(red: 0.13, green: 0.38, blue: 0.42, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 200, yRadius: 200).fill()
        NSColor.white.setStroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 348, y: 295))
        slash.line(to: NSPoint(x: 676, y: 729))
        slash.lineWidth = 70
        slash.lineCapStyle = .round
        slash.stroke()
        NSColor(red: 0.45, green: 0.79, blue: 0.81, alpha: 1).setStroke()
        let upper = NSBezierPath(ovalIn: NSRect(x: 285, y: 590, width: 150, height: 150))
        upper.lineWidth = 54
        upper.stroke()
        NSColor(red: 0.93, green: 0.65, blue: 0.51, alpha: 1).setStroke()
        let lower = NSBezierPath(ovalIn: NSRect(x: 590, y: 285, width: 150, height: 150))
        lower.lineWidth = 54
        lower.stroke()
        image.unlockFocus()
        guard let data = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("Icon render failed") }
        let suffix = scale == 2 ? "@2x" : ""
        try png.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
