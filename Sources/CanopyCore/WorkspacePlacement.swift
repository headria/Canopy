import Foundation
import CoreGraphics

public struct WorkspaceFrame: Codable, Equatable, Sendable {
    public let x: Double, y: Double, width: Double, height: Double
    public init(_ rectangle: CGRect) {
        x = Double(rectangle.minX); y = Double(rectangle.minY)
        width = Double(rectangle.width); height = Double(rectangle.height)
    }
    public var rectangle: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

/// Workspace placement is independent of the temporary, top-anchored shelf.
public struct WorkspacePlacement {
    public private(set) var rememberedFrame: CGRect?
    public init() { }

    public mutating func remember(_ frame: CGRect) {
        guard [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite),
              frame.width > 0, frame.height > 0 else { return }
        rememberedFrame = frame
    }

    public func frame(on displays: [CGRect], preferredDisplay: CGRect) -> CGRect {
        let target: CGRect
        if let rememberedFrame,
           let matching = displays.max(by: { overlap(rememberedFrame, $0) < overlap(rememberedFrame, $1) }),
           overlap(rememberedFrame, matching) > 0 {
            target = matching
        } else { target = preferredDisplay }
        let size = CGSize(width: min(900, max(1, target.width - 40)),
                          height: min(620, max(1, target.height - 40)))
        let origin = rememberedFrame?.origin ?? CGPoint(x: target.midX - size.width / 2,
                                                       y: target.midY - size.height / 2)
        let margin = min(20, max(0, (target.width - size.width) / 2), max(0, (target.height - size.height) / 2))
        return CGRect(x: min(max(origin.x, target.minX + margin), target.maxX - size.width - margin),
                      y: min(max(origin.y, target.minY + margin), target.maxY - size.height - margin),
                      width: size.width, height: size.height)
    }

    private func overlap(_ window: CGRect, _ display: CGRect) -> CGFloat {
        let intersection = window.intersection(display)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
