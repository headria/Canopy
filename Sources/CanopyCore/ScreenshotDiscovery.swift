import Foundation

public struct ScreenshotFileSnapshot: Equatable, Sendable {
    public let url: URL
    public let size: Int
    public let modifiedAt: Date
    public let isScreenshot: Bool
    public init(url: URL, size: Int, modifiedAt: Date, isScreenshot: Bool) {
        self.url = url; self.size = size; self.modifiedAt = modifiedAt; self.isScreenshot = isScreenshot
    }
    fileprivate var fingerprint: Fingerprint { Fingerprint(size: size, modifiedAt: modifiedAt) }
    fileprivate struct Fingerprint: Equatable {
        let size: Int
        let modifiedAt: Date
    }
}

/// A deterministic discovery state machine, independent of Spotlight and UI scheduling.
/// Two matching observations prevent importing a file that is still being written.
public struct ScreenshotDiscovery {
    private var imported: [URL: ScreenshotFileSnapshot.Fingerprint] = [:]
    private var pending: [URL: ScreenshotFileSnapshot.Fingerprint] = [:]
    public init() {}

    public mutating func begin(with existing: [ScreenshotFileSnapshot]) {
        imported = Dictionary(existing.map { ($0.url, $0.fingerprint) }, uniquingKeysWith: { _, last in last })
        pending = [:]
    }
    public mutating func ready(in files: [ScreenshotFileSnapshot]) -> [ScreenshotFileSnapshot] {
        let current = Set(files.map(\.url))
        imported = imported.filter { current.contains($0.key) }
        pending = pending.filter { current.contains($0.key) }
        var ready: [ScreenshotFileSnapshot] = []
        for file in files {
            guard file.isScreenshot, file.size > 0, imported[file.url] != file.fingerprint else {
                pending[file.url] = nil
                continue
            }
            if pending[file.url] == file.fingerprint { ready.append(file) }
            else { pending[file.url] = file.fingerprint }
        }
        return ready.sorted { $0.modifiedAt < $1.modifiedAt }
    }
    /// Mark only successful imports; transient read failures remain eligible for retry.
    public mutating func markImported(_ file: ScreenshotFileSnapshot) {
        imported[file.url] = file.fingerprint
        pending[file.url] = nil
    }
}

public enum ScreenshotClassification {
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "tif", "tiff", "heic", "gif", "bmp"]
    public static func isScreenshot(url: URL, metadataFlag: Bool) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        if metadataFlag { return true }
        // Spotlight can lag behind file creation. Recognize the standard dated macOS
        // filename while waiting for its metadata; arbitrary image names stay excluded.
        let name = url.deletingPathExtension().lastPathComponent
        return name.range(of: #"^(Screenshot|Screen Shot) \d{4}-\d{2}-\d{2} (at |\d)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
