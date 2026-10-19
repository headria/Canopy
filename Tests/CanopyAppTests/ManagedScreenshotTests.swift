import CanopyCore
import Foundation
import Testing
@testable import CanopyApp

private struct CopyScreenshot: ScreenshotServing {
    func capture(to url: URL) async throws -> Bool { false }
    func importImage(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func recognizeText(at url: URL) async throws -> String { "Recognized" }
}

@MainActor
private final class ManagedPreferenceFake: SystemScreenshotManaging {
    var beginFolders: [URL] = []
    var ends = 0
    var beforeBegin: (() -> Void)?
    func begin(in directory: URL) throws { beforeBegin?(); beginFolders.append(directory) }
    func end() throws { ends += 1 }
}

@MainActor
private final class WatcherFake: ScreenshotWatching {
    var started = false
    var includeExisting = false
    var fail = false
    func start(directory: URL, includeExisting: Bool, onCapture: @escaping (URL) async throws -> Void, onError: @escaping (ScreenshotWatchIssue) -> Void) async throws {
        if fail { throw CocoaError(.fileReadNoPermission) }
        started = true; self.includeExisting = includeExisting
    }
    func stop() { started = false }
}

@MainActor
struct ManagedScreenshotTests {
    private func repository() -> FileLibraryRepository { .init(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CanopyManagedTest-\(UUID())")) }
    private func source(in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("Screenshot 2026-10-08 at 8.00.00 AM.png")
        try Data([1, 2, 3]).write(to: url)
        return url
    }

    @Test func ownedScreenshotHasOnlyAnAppCopyAndDiscardRemovesItDurably() async throws {
        let repo = repository(); defer { try? FileManager.default.removeItem(at: repo.directory) }
        let state = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        let raw = try source(in: state.screenshotInbox)
        try await state.importScreenshot(raw, consumingSource: true)
        let capture = try #require(state.library.captures.first), appFile = try #require(state.captureURL(capture))
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        #expect(FileManager.default.fileExists(atPath: appFile.path))
        #expect(try repo.load().captures.count == 1)
        state.removeCapture(capture)
        #expect(state.library.captures.isEmpty && !FileManager.default.fileExists(atPath: appFile.path))
        #expect(try repo.load().captures.isEmpty)
        await state.shutdown()
        #expect(AppState(repository: repo, systemScreenshots: ManagedPreferenceFake()).library.captures.isEmpty)
    }

    @Test func externalImportAndSymlinkTargetAreNeverConsumed() async throws {
        let repo = repository(), external = repository(); defer { try? FileManager.default.removeItem(at: repo.directory); try? FileManager.default.removeItem(at: external.directory) }
        let state = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        let raw = try source(in: external.directory)
        do { try await state.importScreenshot(raw, consumingSource: true); Issue.record("External file must not be consumed") } catch { }
        try FileManager.default.createDirectory(at: state.screenshotInbox, withIntermediateDirectories: true)
        let link = state.screenshotInbox.appendingPathComponent("linked.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: raw)
        do { try await state.importScreenshot(link, consumingSource: true); Issue.record("Symlink target must not be consumed") } catch { }
        try await state.importScreenshot(raw)
        state.removeCapture(try #require(state.library.captures.first))
        #expect(FileManager.default.fileExists(atPath: raw.path))
        await state.shutdown()
    }

    @Test func failedLibrarySavePreservesTheInboxOriginalAndDoesNotAnnounce() async throws {
        let repo = repository(); defer { try? FileManager.default.removeItem(at: repo.directory) }
        let state = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        let raw = try source(in: state.screenshotInbox)
        try FileManager.default.createDirectory(at: repo.libraryURL, withIntermediateDirectories: true)
        var announced = false; state.onCaptureAdded = { _ in announced = true }
        do { try await state.importScreenshot(raw, consumingSource: true); Issue.record("Save should fail") } catch { }
        #expect(!announced && state.library.captures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: raw.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: repo.capturesDirectory.path).isEmpty)
        await state.shutdown()
    }

    @Test func retryAfterInboxRemovalFailureCannotDuplicateTheSavedCapture() async throws {
        let repo = repository(); defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: repo.directory.appendingPathComponent("Screenshot Inbox").path); try? FileManager.default.removeItem(at: repo.directory) }
        let state = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        let raw = try source(in: state.screenshotInbox)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: state.screenshotInbox.path)
        do { try await state.importScreenshot(raw, consumingSource: true); Issue.record("Readonly inbox must refuse removal") } catch { }
        #expect(state.library.captures.count == 1 && FileManager.default.fileExists(atPath: raw.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: state.screenshotInbox.path)
        let relaunched = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        try await relaunched.importScreenshot(raw, consumingSource: true)
        #expect(relaunched.library.captures.count == 1 && !FileManager.default.fileExists(atPath: raw.path))
        await state.shutdown(); await relaunched.shutdown()
    }

    @Test func watcherIsReadyBeforeSettingsChangeAndPausingRestoresSettings() async throws {
        let repo = repository(); defer { try? FileManager.default.removeItem(at: repo.directory) }
        let watcher = WatcherFake(), manager = ManagedPreferenceFake()
        manager.beforeBegin = { #expect(watcher.started) }
        let state = AppState(repository: repo, watcher: watcher, systemScreenshots: manager, distribution: .direct)
        state.startScreenshotWatching()
        for _ in 0..<100 { if !state.watcherStarting { break }; await Task.yield() }
        #expect(state.managedScreenshots && watcher.includeExisting)
        #expect(manager.beginFolders == [state.screenshotInbox])
        state.setScreenshotWatching(false)
        for _ in 0..<100 { if watcher.started { break }; await Task.yield() }
        #expect(!state.managedScreenshots && watcher.started && manager.ends == 2)
        await state.shutdown()
    }

    @Test func failedWatcherAndPreviewCannotChangeSystemSettings() async throws {
        for preview in [false, true] {
            let repo = repository(); defer { try? FileManager.default.removeItem(at: repo.directory) }
            let watcher = WatcherFake(); watcher.fail = true
            let manager = ManagedPreferenceFake()
            let state = AppState(repository: repo, watcher: watcher, systemScreenshots: manager, demo: preview)
            state.startScreenshotWatching()
            for _ in 0..<100 { if !state.watcherStarting { break }; await Task.yield() }
            #expect(manager.beginFolders.isEmpty && !state.managedScreenshots)
            await state.shutdown()
            if preview { #expect(manager.ends == 0) }
        }
    }

    @Test func pausingStillRecoversPendingOwnedScreenshots() async throws {
        let repo = repository(); defer { try? FileManager.default.removeItem(at: repo.directory) }
        let state = AppState(repository: repo, screenshot: CopyScreenshot(), systemScreenshots: ManagedPreferenceFake())
        state.library.preferences.screenshotWatchingEnabled = false
        let raw = try source(in: state.screenshotInbox)
        state.startScreenshotWatching()
        for _ in 0..<100 {
            if !state.library.captures.isEmpty { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(state.library.captures.count == 1 && !state.managedScreenshots)
        #expect(!FileManager.default.fileExists(atPath: raw.path))
        await state.shutdown()
    }

    @Test func pendingPDFReturnsToOrdinaryFolderWhileCustomWatchingIsSelected() async throws {
        let repo = repository(), ordinary = repository(), custom = repository()
        defer {
            try? FileManager.default.removeItem(at: repo.directory)
            try? FileManager.default.removeItem(at: ordinary.directory)
            try? FileManager.default.removeItem(at: custom.directory)
        }
        let state = AppState(repository: repo, systemScreenshots: ManagedPreferenceFake(), systemScreenshotDirectory: { ordinary.directory }, distribution: .direct)
        try FileManager.default.createDirectory(at: state.screenshotInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: custom.directory, withIntermediateDirectories: true)
        let pending = state.screenshotInbox.appendingPathComponent("Custom capture.pdf")
        try Data([1, 2, 3]).write(to: pending)
        state.library.preferences.managesSystemScreenshots = false
        state.library.preferences.screenshotFolder = custom.directory.path
        state.startScreenshotWatching()
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: pending.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(try Data(contentsOf: ordinary.directory.appendingPathComponent(pending.lastPathComponent)) == Data([1, 2, 3]))
        #expect(state.library.captures.isEmpty && !state.managedScreenshots)
        await state.shutdown()
    }

    @Test func screenRecordingReturnsToOrdinaryFolderWithoutOverwritingAnExistingFile() async throws {
        let repo = repository(), ordinary = repository()
        defer { try? FileManager.default.removeItem(at: repo.directory); try? FileManager.default.removeItem(at: ordinary.directory) }
        let state = AppState(repository: repo, systemScreenshots: ManagedPreferenceFake(), systemScreenshotDirectory: { ordinary.directory })
        try FileManager.default.createDirectory(at: state.screenshotInbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ordinary.directory, withIntermediateDirectories: true)
        let movie = state.screenshotInbox.appendingPathComponent("Screen Recording.mov")
        let existing = ordinary.directory.appendingPathComponent(movie.lastPathComponent)
        try Data([1, 2, 3]).write(to: movie); try Data([9]).write(to: existing)
        try await state.returnOtherCapture(movie)
        #expect(!FileManager.default.fileExists(atPath: movie.path))
        #expect(try Data(contentsOf: existing) == Data([9]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: ordinary.directory.path).count == 2)
        #expect(state.library.captures.isEmpty)
        await state.shutdown()
    }
}
