import AppKit
import CanopyCore
import Testing
@testable import CanopyApp

@MainActor
private final class RecordingPreviewOpener: CaptureOpening {
    var urls: [URL] = []
    func openForEditing(_ url: URL) async throws { urls.append(url) }
}

@MainActor
private final class NoScreenshotSettings: SystemScreenshotManaging {
    func begin(in directory: URL) throws { Issue.record("Edit tests must not change system settings") }
    func end() throws { }
}

private struct EditedImageOCR: ScreenshotServing {
    func capture(to url: URL) async throws -> Bool { false }
    func importImage(from source: URL, to destination: URL) throws {
        let bytes = try Data(contentsOf: source)
        guard NSBitmapImageRep(data: bytes) != nil else { throw CocoaError(.fileReadCorruptFile) }
        try bytes.write(to: destination, options: .atomic)
    }
    func recognizeText(at url: URL) async throws -> String { "Image bytes: \(try Data(contentsOf: url).count)" }
}

@MainActor
struct CaptureInteractionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyInteractionTest-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func image(at url: URL, width: Int = 12) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<width { for y in 0..<8 { bitmap.setColor(NSColor(deviceRed: 0.2, green: 0.6, blue: 0.3, alpha: 1), atX: x, y: y) } }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url, options: .atomic)
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<150 { if predicate() { return true }; try? await Task.sleep(nanoseconds: 20_000_000) }
        return predicate()
    }
    private func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func firstClickOpensPreviewButDraggingAndMouseUpOutsideDoNot() throws {
        _ = NSApplication.shared
        let view = CaptureMouseView(frame: NSRect(x: 0, y: 0, width: 200, height: 110))
        view.source = URL(fileURLWithPath: "/unused-test-image.png")
        var opens = 0, holds: [Bool] = []
        view.onOpen = { opens += 1 }; view.onHold = { holds.append($0) }
        #expect(view.acceptsFirstMouse(for: nil))
        try view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 20, y: 20)))
        try view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 20, y: 20)))
        #expect(opens == 1 && holds == [true, false])
        try view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 20, y: 20)))
        try view.mouseDragged(with: event(.leftMouseDragged, NSPoint(x: 80, y: 30)))
        try view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 80, y: 30)))
        #expect(opens == 1 && holds == [true, false, true, false])
        try view.mouseDown(with: event(.leftMouseDown, NSPoint(x: 20, y: 20)))
        try view.mouseUp(with: event(.leftMouseUp, NSPoint(x: 300, y: 20)))
        #expect(opens == 1)
    }

    @Test func dragHasImageAndFileFormatsAndSurvivesSourceDiscard() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png"); try image(at: source)
        let snapshot = try CaptureDragSnapshot.read(from: source, title: "../../Notes:Today.png")
        let provider = try CaptureDragProvider(snapshot: snapshot)
        let pasteboard = NSPasteboard.withUniqueName(); defer { pasteboard.releaseGlobally() }
        #expect(pasteboard.writeObjects([provider]))
        #expect(pasteboard.types?.contains(.png) == true && pasteboard.types?.contains(.tiff) == true)
        #expect(pasteboard.types?.contains(NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")) == true)
        #expect(pasteboard.data(forType: .png) == snapshot.png)
        #expect(pasteboard.string(forType: .fileURL) == provider.transferURL.absoluteString)
        #expect(provider.transferURL != source)
        #expect(try Data(contentsOf: provider.transferURL) == snapshot.png)
        #expect(NSBitmapImageRep(data: try #require(snapshot.tiff))?.pixelsWide == 12)
        try FileManager.default.removeItem(at: source)
        let copy = directory.appendingPathComponent(snapshot.filename)
        var failure: Error?
        provider.filePromiseProvider(provider, writePromiseTo: copy) { failure = $0 }
        #expect(failure == nil)
        #expect(try Data(contentsOf: copy) == snapshot.png)
        #expect(copy.deletingLastPathComponent().path == directory.path)
        provider.removeTransfer()
        #expect(!FileManager.default.fileExists(atPath: provider.transferURL.path))
        #expect(throws: (any Error).self) { try snapshot.write(to: copy) }
        #expect(try Data(contentsOf: copy) == snapshot.png)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [snapshot.filename])
    }

    @Test func exportFilenameIsReadableAndBounded() {
        #expect(CaptureDragSnapshot.exportFilename(". / \\ : \n.") .hasSuffix(".png"))
        #expect(CaptureDragSnapshot.exportFilename("") == "Screenshot.png")
        #expect(CaptureDragSnapshot.exportFilename("Plan.png") == "Plan.png")
        #expect(CaptureDragSnapshot.exportFilename(String(repeating: "🖼️", count: 100)).utf8.count <= 184)
        #expect(!CaptureDragSnapshot.exportFilename("../a/b:c").contains("/"))
    }

    @Test func editRefreshKeepsIdentityAndReloadsThumbnailOCRWithoutNewArrival() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let opener = RecordingPreviewOpener()
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: EditedImageOCR(), captureOpener: opener, systemScreenshots: NoScreenshotSettings())
        let controller = ShelfPanelController(state: state); defer { controller.shutdown(); try? FileManager.default.removeItem(at: state.editCopies.directory) }
        let source = directory.appendingPathComponent("Editing check.png"); try image(at: source)
        var arrivals = 0
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first), url = try #require(state.captureURL(capture))
        state.onCaptureAdded = { _ in arrivals += 1 }
        #expect(await eventually { !state.library.captures[0].extractedText.isEmpty })
        let before = await CaptureThumbnailStore.shared.image(at: url)
        #expect(before?.width == 12)
        state.openCaptureInPreview(capture)
        #expect(controller.presentation.mode == .hidden)
        #expect(await eventually { opener.urls == [(try? state.editCopies.url(filename: capture.filename))].compactMap { $0 } })
        try image(at: url, width: 24)
        try await state.refreshEditedCapture(at: url)
        #expect(await eventually { state.library.captures[0].extractedText == "Image bytes: \((try? Data(contentsOf: url).count) ?? 0)" })
        #expect(state.library.captures[0].id == capture.id && state.library.captures.count == 1)
        #expect(state.captureRevisions[capture.id] == 1 && arrivals == 0)
        #expect(controller.presentation.mode == .hidden)
        let after = await CaptureThumbnailStore.shared.image(at: url)
        #expect(after?.width == 24)
        try await state.refreshEditedCapture(at: url)
        #expect(state.captureRevisions[capture.id] == 1)
        #expect(try state.repository.load().captures[0].imageVersion == CaptureImageVersion.read(at: url))
        await state.shutdown()
    }

    @Test func heldScreenshotDefersIncomingPreviewUntilRelease() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: EditedImageOCR(), systemScreenshots: NoScreenshotSettings())
        let controller = ShelfPanelController(state: state); defer { controller.shutdown(); try? FileManager.default.removeItem(at: state.editCopies.directory) }
        let first = UUID(), second = UUID()
        controller.captureArrived(first)
        state.beginCaptureInteraction(); state.beginCaptureInteraction()
        controller.captureArrived(second)
        #expect(controller.presentation.mode == .arrival(first) && controller.panel.isVisible)
        state.endCaptureInteraction()
        #expect(controller.presentation.mode == .arrival(first))
        state.endCaptureInteraction()
        #expect(controller.presentation.mode == .arrival(second) && controller.panel.isVisible)
        state.endCaptureInteraction()
        #expect(!state.captureInteractionActive && state.captureInteractionCount == 0)
        await state.shutdown()
    }

    @Test func nativeEditWatcherDetectsUUIDNamedFilesAndOfflineEdits() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory)
        let state = AppState(repository: repository, screenshot: EditedImageOCR(), editWatcher: ScreenshotWatcher(interval: 20_000_000, acceptsAllImages: true), systemScreenshots: NoScreenshotSettings())
        let source = directory.appendingPathComponent("Example.png"); try image(at: source)
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first), url = try #require(state.captureURL(capture))
        state.startCaptureEditWatching()
        try await Task.sleep(nanoseconds: 150_000_000)
        try image(at: url, width: 30)
        #expect(await eventually { state.captureRevisions[capture.id] == 1 })
        await state.shutdown()
        try image(at: url, width: 42)
        let relaunched = AppState(repository: repository, screenshot: EditedImageOCR(), systemScreenshots: NoScreenshotSettings())
        relaunched.startCaptureEditWatching()
        #expect(await eventually { relaunched.captureRevisions[capture.id] == 1 })
        #expect(relaunched.library.captures.count == 1)
        await relaunched.shutdown()
    }
    @Test func previewSaveUpdatesTheSameImageAndDiscardRemovesBothWorkingFiles() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let opener = RecordingPreviewOpener()
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: EditedImageOCR(), captureOpener: opener, systemScreenshots: NoScreenshotSettings())
        defer { try? FileManager.default.removeItem(at: state.editCopies.directory) }
        let source = directory.appendingPathComponent("Preview edit.png"); try image(at: source)
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first), original = try #require(state.captureURL(capture))
        state.startCaptureEditWatching(); state.openCaptureInPreview(capture)
        #expect(await eventually { opener.urls.count == 1 })
        let editing = try #require(opener.urls.first)
        #expect(editing != original && (try? Data(contentsOf: editing)) == (try? Data(contentsOf: original)))
        #expect(try state.repository.load().captures[0].previewVersion != nil)
        try image(at: editing, width: 36)
        #expect(await eventually { state.captureRevisions[capture.id] == 1 })
        #expect(state.library.captures.count == 1 && state.library.captures[0].id == capture.id)
        #expect(await CaptureThumbnailStore.shared.image(at: original)?.width == 36)
        state.removeCapture(capture)
        #expect(!FileManager.default.fileExists(atPath: editing.path) && !FileManager.default.fileExists(atPath: original.path))
        #expect(try state.repository.load().captures.isEmpty)
        // Late saves from an already-open Preview document cannot recreate a discarded item.
        try image(at: editing, width: 48)
        try await state.refreshPreviewEdits(at: editing)
        #expect(!FileManager.default.fileExists(atPath: editing.path) && state.library.captures.isEmpty)
        #expect(FileManager.default.fileExists(atPath: source.path))
        await state.shutdown()
    }

    @Test func previewEditsSavedWhileClosedAreRecoveredOnRelaunch() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory), opener = RecordingPreviewOpener()
        let state = AppState(repository: repository, screenshot: EditedImageOCR(), captureOpener: opener, systemScreenshots: NoScreenshotSettings())
        defer { try? FileManager.default.removeItem(at: state.editCopies.directory) }
        let source = directory.appendingPathComponent("Offline preview.png"); try image(at: source)
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first)
        state.openCaptureInPreview(capture)
        #expect(await eventually { opener.urls.count == 1 })
        await state.shutdown()
        // A newer original or a crash after publishing a file must not erase a pending Preview save.
        try image(at: try #require(state.captureURL(capture)), width: 20)
        let editing = try #require(opener.urls.first); try image(at: editing, width: 44)
        let relaunched = AppState(repository: repository, screenshot: EditedImageOCR(), systemScreenshots: NoScreenshotSettings())
        relaunched.startCaptureEditWatching()
        #expect(await eventually { relaunched.captureRevisions[capture.id] == 1 })
        let original = try #require(relaunched.captureURL(capture))
        #expect(await CaptureThumbnailStore.shared.image(at: original)?.width == 44)
        #expect(relaunched.library.captures.count == 1)
        await relaunched.shutdown()
    }
    @Test func directFileChangesKeepALivePreviewCopyUsable() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let opener = RecordingPreviewOpener()
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: EditedImageOCR(), captureOpener: opener, systemScreenshots: NoScreenshotSettings())
        defer { try? FileManager.default.removeItem(at: state.editCopies.directory) }
        let source = directory.appendingPathComponent("Two editors.png"); try image(at: source)
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first), original = try #require(state.captureURL(capture))
        state.openCaptureInPreview(capture)
        #expect(await eventually { opener.urls.count == 1 })
        let editing = try #require(opener.urls.first)
        try image(at: original, width: 30); try await state.refreshEditedCapture(at: original)
        #expect(FileManager.default.fileExists(atPath: editing.path) && state.library.captures[0].previewVersion != nil)
        try image(at: editing, width: 38); try await state.refreshPreviewEdits(at: editing)
        #expect(await CaptureThumbnailStore.shared.image(at: original)?.width == 38)
        #expect(state.library.captures.count == 1)
        await state.shutdown()
    }

    @Test func oneBadPreviewCopyCannotStopOtherSavedEdits() async throws {
        let directory = try folder(); defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory), opener = RecordingPreviewOpener()
        let state = AppState(repository: repository, screenshot: EditedImageOCR(), captureOpener: opener, systemScreenshots: NoScreenshotSettings())
        defer { try? FileManager.default.removeItem(at: state.editCopies.directory) }
        for name in ["Good", "Bad"] {
            let source = directory.appendingPathComponent(name + ".png"); try image(at: source)
            try await state.importScreenshot(source)
            state.openCaptureInPreview(try #require(state.library.captures.first))
            #expect(await eventually { opener.urls.count == (name == "Good" ? 1 : 2) })
        }
        let good = try #require(state.library.captures.first { $0.title == "Good" })
        let goodEdit = try state.editCopies.url(filename: good.filename)
        let bad = try #require(state.library.captures.first { $0.title == "Bad" })
        await state.shutdown()
        try Data([1, 2, 3]).write(to: state.editCopies.url(filename: bad.filename), options: .atomic)
        let relaunched = AppState(repository: repository, screenshot: EditedImageOCR(), systemScreenshots: NoScreenshotSettings())
        relaunched.startCaptureEditWatching()
        #expect(await eventually { relaunched.banner != nil })
        try image(at: goodEdit, width: 40)
        #expect(await eventually { relaunched.captureRevisions[good.id] == 1 })
        #expect(relaunched.library.captures.count == 2)
        await relaunched.shutdown()
    }
}
