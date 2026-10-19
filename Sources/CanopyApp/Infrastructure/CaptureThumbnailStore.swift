import CoreGraphics
import Foundation
import ImageIO
import CanopyCore

/// Decode small previews off the main actor and reuse them across shelf reveals.
/// Full-resolution images are loaded only for an explicit copy or open action.
actor CaptureThumbnailStore {
    static let shared = CaptureThumbnailStore()
    private final class Thumbnail {
        let version: CaptureImageVersion
        let image: CGImage
        init(version: CaptureImageVersion, image: CGImage) { self.version = version; self.image = image }
    }
    private let cache = NSCache<NSURL, Thumbnail>()

    init() { cache.countLimit = 64; cache.totalCostLimit = 20_000_000 }
    func remove(at url: URL) { cache.removeObject(forKey: url as NSURL) }

    func image(at url: URL) -> CGImage? {
        guard let version = try? CaptureImageVersion.read(at: url) else { return nil }
        if let cached = cache.object(forKey: url as NSURL), cached.version == version { return cached.image }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 480,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        cache.setObject(Thumbnail(version: version, image: image), forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }
}
