import AppKit
import SwiftUI

enum CanopyTheme {
    static let paper = Color(nsColor: CanopyArtwork.paper)
    static let ink = Color(nsColor: CanopyArtwork.ink)
    static let muted = Color(nsColor: CanopyArtwork.muted)
    static let accent = Color(nsColor: CanopyArtwork.accent)
    static let border = Color(nsColor: CanopyArtwork.border)
    static let surface = Color(nsColor: CanopyArtwork.surface)
    static let primary = Color(nsColor: CanopyArtwork.primary)
}

struct BrandMark: View {
    var size: CGFloat = 18
    var body: some View {
        Image(nsImage: CanopyArtwork.menuBarImage).renderingMode(.template)
            .resizable().frame(width: size, height: size)
            .accessibilityLabel(CanopyArtwork.name)
    }
}

struct CanopyButtonStyle: ButtonStyle {
    var primary = false
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .padding(.horizontal, compact ? 10 : 14).padding(.vertical, compact ? 7 : 10)
            .foregroundStyle(primary ? CanopyTheme.paper : CanopyTheme.ink)
            .background(primary ? CanopyTheme.primary : CanopyTheme.surface.opacity(0.85), in: Capsule())
            .overlay(Capsule().strokeBorder(primary ? Color.clear : CanopyTheme.border, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .contentShape(Capsule())
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).frame(width: 28, height: 28) }
            .buttonStyle(.plain).foregroundStyle(CanopyTheme.ink)
            .background(CanopyTheme.surface.opacity(0.85), in: Circle()).help(help).accessibilityLabel(help)
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.7).foregroundStyle(CanopyTheme.muted)
    }
}

struct EmptyCard: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 30, weight: .light)).foregroundStyle(CanopyTheme.ink)
                .frame(width: 70, height: 70).background(CanopyTheme.accent.opacity(0.4), in: RoundedRectangle(cornerRadius: 22))
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(CanopyTheme.ink)
            Text(detail).font(.system(size: 12)).foregroundStyle(CanopyTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 370)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    func canopyCard() -> some View {
        self.background(CanopyTheme.surface.opacity(0.9), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(CanopyTheme.border.opacity(0.65), lineWidth: 1))
    }
}

/// Original, code-drawn artwork for the isolated preview library.
enum DemoArtwork {
    static func image(index: Int) -> NSImage {
        let image = NSImage(size: NSSize(width: 600, height: 380))
        image.lockFocus()
        let backgrounds: [NSColor] = [CanopyArtwork.accent,
                                      CanopyArtwork.paper,
                                      CanopyArtwork.border]
        backgrounds[index].setFill(); NSRect(x: 0, y: 0, width: 600, height: 380).fill()
        let dark = CanopyArtwork.ink
        if index == 0 {
            dark.withAlphaComponent(0.14).setFill()
            for i in 0..<5 { NSBezierPath(ovalIn: NSRect(x: 300 + i * 30, y: 70 + i * 18, width: 180, height: 180)).fill() }
            draw("Make room\nfor the good stuff.", x: 40, y: 125, size: 36, color: dark)
            draw("COLLECT / THINK / CREATE", x: 42, y: 40, size: 12, color: dark)
        } else if index == 1 {
            draw("MONDAY, IN FOCUS", x: 40, y: 300, size: 14, color: dark)
            for (row, title) in ["Prototype review", "Audio capture test", "A little time to think"].enumerated() {
                NSColor.white.withAlphaComponent(0.55).setFill()
                NSBezierPath(roundedRect: NSRect(x: 32, y: 210 - row * 70, width: 530, height: 52), xRadius: 12, yRadius: 12).fill()
                draw("0\(row + 1)   \(title)", x: 50, y: CGFloat(227 - row * 70), size: 18, color: dark)
            }
        } else {
            draw("The next idea\nis closer than\nyou think.", x: 40, y: 130, size: 38, color: dark)
            draw("\(CanopyArtwork.name.uppercased())  /  \(CanopyArtwork.tagline.uppercased())", x: 42, y: 40, size: 12, color: dark)
            dark.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: NSRect(x: 410, y: 120, width: 140, height: 140)).fill()
        }
        image.unlockFocus(); return image
    }
    private static func draw(_ text: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor) {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color])
    }
}
