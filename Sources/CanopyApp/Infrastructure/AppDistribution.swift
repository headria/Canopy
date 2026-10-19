import AppKit
import CanopyCore

@MainActor
enum NativeScreenshotFolderPicker {
    static func select(initialDirectory: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose where macOS saves your screenshots. \(ProductBrand.name) copies new screenshots into your shelf."
        panel.directoryURL = initialDirectory
        return panel.runModal() == .OK ? panel.url : nil
    }
}

enum AppDistribution {
    case direct, appStore
    static var current: Self {
        #if CANOPY_APP_STORE
        return .appStore
        #else
        return .direct
        #endif
    }
    var managesScreenshotSettings: Bool {
        self == .direct
    }
    var requiresAIConsent: Bool { self == .appStore }
}

@MainActor
protocol ScreenshotFolderAccessing: AnyObject {
    func bookmark(for directory: URL) throws -> Data
    func start(bookmark: Data, owner: UUID) throws -> ScreenshotFolderLease
    func stop(owner: UUID?)
}
extension ScreenshotFolderAccessing { func stop() { stop(owner: nil) } }

struct ScreenshotFolderLease {
    let directory: URL
    let refreshedBookmark: Data?
}

/// A folder chosen through Powerbox is the only external folder the Store
/// watcher may read. Keep its security scope alive for the watcher's lifetime.
@MainActor
final class ScreenshotFolderAccess: ScreenshotFolderAccessing {
    private var directory: URL?
    private var owner: UUID?
    func bookmark(for directory: URL) throws -> Data {
        try directory.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    func start(bookmark: Data, owner: UUID) throws -> ScreenshotFolderLease {
        stop()
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        guard url.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        directory = url
        self.owner = owner
        do {
            return ScreenshotFolderLease(directory: url, refreshedBookmark: stale ? try self.bookmark(for: url) : nil)
        } catch { stop(owner: owner); throw error }
    }
    func stop(owner: UUID?) {
        guard owner == nil || owner == self.owner else { return }
        directory?.stopAccessingSecurityScopedResource(); directory = nil; self.owner = nil
    }
}
