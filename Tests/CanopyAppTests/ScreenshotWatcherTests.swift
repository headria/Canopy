import AppKit
import CanopyCore
import Foundation
import Testing
@testable import CanopyApp

@MainActor
struct ScreenshotWatcherTests {
    private func directory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyWatcherTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    private func writeImage(_ url: URL) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let color = NSColor(deviceRed: 0.2, green: 0.6, blue: 0.3, alpha: 1)
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(color, atX: x, y: y) } }
        try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
    }
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    @Test func nativeWatcherCopiesNewFilesOnceAndKeepsOriginals() async throws {
        let folder = try directory(), storage = try directory()
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: storage) }
        let old = folder.appendingPathComponent("Screenshot 2026-10-08 at 5.00.00 AM.png")
        try writeImage(old)
        let watcher = ScreenshotWatcher(interval: 20_000_000)
        var imports: [URL] = [], errors: [String] = []
        try await watcher.start(directory: folder, onCapture: { url in
            try NativeScreenshotService().importImage(from: url, to: storage.appendingPathComponent(url.lastPathComponent))
            imports.append(url)
        }, onError: { errors.append($0.message) })
        defer { watcher.stop() }
        let new = folder.appendingPathComponent("Screenshot 2026-10-08 at 6.00.00 AM.png")
        try writeImage(new)
        #expect(await eventually { imports.count == 1 })
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(imports.count == 1)
        #expect(imports.map { $0.resolvingSymlinksInPath().path } == [new.resolvingSymlinksInPath().path])
        #expect(errors.isEmpty)
        #expect(FileManager.default.fileExists(atPath: new.path))
        #expect(FileManager.default.fileExists(atPath: storage.appendingPathComponent(new.lastPathComponent).path))
    }
    @Test func nativeWatcherRetriesATransientReadFailure() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let watcher = ScreenshotWatcher(interval: 20_000_000)
        var attempts = 0, successes = 0
        try await watcher.start(directory: folder, onCapture: { _ in
            attempts += 1
            if attempts == 1 { throw CocoaError(.fileReadNoSuchFile) }
            successes += 1
        }, onError: { _ in })
        defer { watcher.stop() }
        try writeImage(folder.appendingPathComponent("Screenshot 2026-10-08 at 6.00.00 AM.png"))
        #expect(await eventually { successes == 1 })
        #expect(attempts == 2)
    }
    @Test func inaccessibleDirectoryDoesNotPretendToBeWatching() async {
        let watcher = ScreenshotWatcher()
        do {
            try await watcher.start(directory: URL(fileURLWithPath: "/nonexistent-canopy-folder-\(UUID().uuidString)"), onCapture: { _ in }, onError: { _ in })
            Issue.record("Missing directory should fail startup")
        } catch { #expect(!error.localizedDescription.isEmpty) }
        watcher.stop()
    }

    @Test func managedInboxWaitsForAQuietMovieBeforeDelivery() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appendingPathComponent("Screen Recording.mov")
        try Data([1, 2, 3]).write(to: movie)
        let watcher = ScreenshotWatcher(interval: 20_000_000)
        var imports = 0
        try await watcher.start(directory: folder, includeExisting: true, onCapture: { _ in imports += 1 }, onError: { _ in })
        defer { watcher.stop() }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(imports == 0)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-6)], ofItemAtPath: movie.path)
        #expect(await eventually { imports == 1 })
    }

    @Test func managedInboxRecoversAFileAlreadyPresentAtStartup() async throws {
        let folder = try directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let pending = folder.appendingPathComponent("Bildschirmfoto 2026-10-08 um 6.00.00.png")
        try writeImage(pending)
        let watcher = ScreenshotWatcher(interval: 20_000_000)
        var imports = 0
        try await watcher.start(directory: folder, includeExisting: true, onCapture: { _ in imports += 1 }, onError: { _ in })
        #expect(await eventually { imports == 1 })
        watcher.stop()
    }
}
