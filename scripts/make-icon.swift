import AppKit

@main
struct IconBuilder {
    static func main() throws {
        guard CommandLine.arguments.count >= 2 else { throw CocoaError(.fileWriteInvalidFileName) }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Canopy-\(UUID().uuidString).iconset")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try write(CanopyArtwork.icon(size: CGFloat(pixels)), to: temporary.appendingPathComponent(filename))
            }
        }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", temporary.path, "-o", CommandLine.arguments[1]]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        if CommandLine.arguments.count > 2 {
            try write(CanopyArtwork.icon(size: 1024), to: URL(fileURLWithPath: CommandLine.arguments[2]))
        }
        if CommandLine.arguments.count > 3 {
            try write(brandBoard(), to: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
    }

    private static func write(_ image: NSImage, to destination: URL) throws {
        // lockFocus images can be Retina-backed. Normalize to the requested
        // pixel dimensions so iconset filenames match on every build display.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                           pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
                                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw CocoaError(.fileWriteUnknown) }
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(origin: .zero, size: image.size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: destination, options: .atomic)
    }

    private static func brandBoard() -> NSImage {
        let image = NSImage(size: NSSize(width: 1200, height: 630))
        image.lockFocus()
        CanopyArtwork.paper.setFill(); NSRect(x: 0, y: 0, width: 1200, height: 630).fill()
        draw("A LITTLE SPACE ABOVE YOUR DAY", at: NSPoint(x: 66, y: 541), size: 12, weight: .semibold, color: CanopyArtwork.ink.withAlphaComponent(0.55))
        CanopyArtwork.icon(size: 256).draw(in: NSRect(x: 52, y: 230, width: 256, height: 256))
        draw(CanopyArtwork.name, at: NSPoint(x: 358, y: 365), size: 80, weight: .semibold, color: CanopyArtwork.ink)
        draw(CanopyArtwork.tagline, at: NSPoint(x: 364, y: 310), size: 28, weight: .regular, color: CanopyArtwork.ink.withAlphaComponent(0.65))
        draw("Screenshots, notes, and answers—within reach.", at: NSPoint(x: 365, y: 254), size: 18, weight: .regular, color: CanopyArtwork.ink.withAlphaComponent(0.55))
        for (index, item) in [(CanopyArtwork.ink, "SLATE"), (CanopyArtwork.accent, "SOFT BLUE"), (CanopyArtwork.paper, "CLOUD")].enumerated() {
            let x = CGFloat(66 + index * 350)
            item.0.setFill()
            let swatch = NSBezierPath(roundedRect: NSRect(x: x, y: 102, width: 308, height: 50), xRadius: 12, yRadius: 12)
            swatch.fill(); CanopyArtwork.ink.withAlphaComponent(0.12).setStroke(); swatch.lineWidth = 1; swatch.stroke()
            draw(item.1, at: NSPoint(x: x, y: 74), size: 11, weight: .medium, color: CanopyArtwork.ink.withAlphaComponent(0.65))
        }
        image.unlockFocus()
        return image
    }

    private static func draw(_ text: String, at point: NSPoint, size: CGFloat, weight: NSFont.Weight, color: NSColor) {
        (text as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
}
