import AppKit
#if !CANOPY_ICON_BUILDER
import CanopyCore
#endif

/// Original vector artwork shared by the app and icon builder.
/// A floating rail shelters three small cards: a place to catch passing work.
enum CanopyArtwork {
    static let name = ProductBrand.name
    static let tagline = ProductBrand.tagline
    static let ink = color(ProductBrand.Palette.ink)
    static let accent = color(ProductBrand.Palette.accent)
    static let paper = color(ProductBrand.Palette.paper)
    static let muted = color(ProductBrand.Palette.muted)
    static let border = color(ProductBrand.Palette.border)
    static let surface = color(ProductBrand.Palette.surface)
    static let primary = color(ProductBrand.Palette.primary)

    private static func color(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                green: CGFloat((hex >> 8) & 255) / 255,
                blue: CGFloat(hex & 255) / 255, alpha: 1)
    }

    static func mark(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.appendRoundedRect(NSRect(x: 0.16, y: 0.79, width: 0.68, height: 0.10), xRadius: 0.05, yRadius: 0.05)
        path.appendRoundedRect(NSRect(x: 0.18, y: 0.20, width: 0.18, height: 0.46), xRadius: 0.045, yRadius: 0.045)
        path.appendRoundedRect(NSRect(x: 0.41, y: 0.09, width: 0.18, height: 0.57), xRadius: 0.045, yRadius: 0.045)
        path.appendRoundedRect(NSRect(x: 0.64, y: 0.29, width: 0.18, height: 0.37), xRadius: 0.045, yRadius: 0.045)
        var transform = AffineTransform()
        transform.translate(x: rect.minX, y: rect.minY)
        transform.scale(x: rect.width, y: rect.height)
        path.transform(using: transform)
        return path
    }

    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()
        NSColor.black.setFill()
        mark(in: NSRect(x: 0, y: 0, width: 18, height: 18)).fill()
        image.unlockFocus()
        image.isTemplate = true
        image.accessibilityDescription = name
        return image
    }()

    static func icon(size: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        let tile = NSBezierPath(roundedRect: NSRect(x: size * 0.06, y: size * 0.06, width: size * 0.88, height: size * 0.88), xRadius: size * 0.20, yRadius: size * 0.20)
        NSGradient(starting: ink, ending: color(ProductBrand.Palette.iconTop))?.draw(in: tile, angle: 70)
        NSColor.white.withAlphaComponent(0.12).setStroke()
        tile.lineWidth = max(1, size * 0.002); tile.stroke()
        accent.setFill()
        mark(in: NSRect(x: size * 0.13, y: size * 0.13, width: size * 0.74, height: size * 0.74)).fill()
        image.unlockFocus()
        return image
    }
}
