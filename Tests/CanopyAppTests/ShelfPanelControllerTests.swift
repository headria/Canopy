import AppKit
import CanopyCore
import Testing
@testable import CanopyApp

private struct PreviewScreenshot: ScreenshotServing {
    func capture(to url: URL) async throws -> Bool { false }
    func importImage(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func recognizeText(at url: URL) async throws -> String { "" }
}

private struct ShelfCaptureScreenshot: ScreenshotServing {
    let result: Result<Bool, StoreScreenshotError>
    func capture(to url: URL) async throws -> Bool {
        let captured = try result.get()
        if captured { try Data([1]).write(to: url) }
        return captured
    }
    func importImage(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func recognizeText(at url: URL) async throws -> String { "" }
}

private struct WindowTestSecrets: SecretStoring {
    func read(_ account: String) throws -> String { "" }
    func write(_ value: String, account: String) throws { }
}

@MainActor
private final class UnusedScreenshotManager: SystemScreenshotManaging {
    func begin(in directory: URL) throws { Issue.record("Window tests must not alter screenshot settings") }
    func end() throws { }
}

@MainActor
struct ShelfPanelControllerTests {
    @Test func shelfCaptureRevealsArrivalAndCancellationOrDenialHaveDistinctRecovery() async throws {
        _ = NSApplication.shared
        for result in [Result<Bool, StoreScreenshotError>.success(true), .success(false), .failure(.permissionDenied)] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyShelfCaptureTest-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let repository = FileLibraryRepository(directory: directory)
            let state = AppState(repository: repository, screenshot: ShelfCaptureScreenshot(result: result),
                systemScreenshots: UnusedScreenshotManager(), distribution: .appStore)
            let controller = ShelfPanelController(state: state, monitorsPointer: false)
            controller.showShelf()
            state.takeScreenshot()
            #expect(!controller.isVisible)
            for _ in 0..<100 {
                if !state.captureBusy { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(!state.captureBusy)
            switch result {
            case .success(true):
                let capture = try #require(state.library.captures.first)
                #expect(controller.presentation.mode == .arrival(capture.id) && controller.isVisible)
                #expect(try repository.load().captures == state.library.captures)
                #expect(state.captureError == nil && !state.captureNeedsSettings)
            case .success(false):
                #expect(controller.presentation.mode == .hidden && !controller.isVisible)
                #expect(state.library.captures.isEmpty && state.captureError == nil)
            case .failure:
                #expect(controller.presentation.mode == .workspace && state.tab == .captures && controller.isVisible)
                #expect(state.captureNeedsSettings && state.captureError != nil && state.library.captures.isEmpty)
            }
            controller.shutdown()
            await state.shutdown()
        }
    }
    @Test func titleAreaTracksMovementUntilMouseUpWithoutMovingOtherWindowModes() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 200, width: 400, height: 40),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isMovable = true
        let title = WorkspaceTitleArea(frame: NSRect(x: 0, y: 0, width: 400, height: 40))
        window.contentView = title
        var changes: [Bool] = []
        title.dragChanged = { changes.append($0) }
        defer { title.finishDragging(); window.orderOut(nil) }
        func event(_ kind: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        title.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 100, y: 20)))
        title.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 150, y: 10)))
        #expect(window.frame.origin == NSPoint(x: 150, y: 190))
        #expect(changes == [true])
        // Further movement is measured in screen coordinates as the window moves.
        title.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 110, y: 15)))
        #expect(window.frame.origin == NSPoint(x: 160, y: 185))
        title.mouseUp(with: try event(.leftMouseUp, NSPoint(x: 100, y: 20)))
        #expect(changes == [true, false])
        window.isMovable = false
        title.mouseDown(with: try event(.leftMouseDown, NSPoint(x: 100, y: 20)))
        title.mouseDragged(with: try event(.leftMouseDragged, NSPoint(x: 200, y: 20)))
        #expect(window.frame.origin == NSPoint(x: 160, y: 185) && changes == [true, false])
    }

    @Test func draggingWorkspaceKeepsItsPositionThroughShelfCaptureReopenAndRelaunch() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyMoveTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory)
        let state = AppState(repository: repository, secrets: WindowTestSecrets(), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.showWorkspace(.meetings)
        #expect(controller.panel.isMovable)
        controller.workspaceDragChanged(true)
        let initial = controller.panel.frame
        controller.panel.setFrameOrigin(NSPoint(x: initial.minX + 15, y: initial.minY - 10))
        controller.workspaceMouseDown(at: NSPoint(x: initial.maxX + 30, y: initial.maxY + 30), fromOtherApp: true)
        #expect(controller.presentation.mode == .workspace)
        controller.workspaceDragChanged(false)
        let moved = controller.panel.frame
        #expect(moved != initial)
        #expect(try repository.load().preferences.workspaceFrame?.rectangle == moved)
        let staleDraft = Preferences()
        try state.savePreferences(staleDraft, assistantKey: "", jevKey: "")
        #expect(state.library.preferences.workspaceFrame?.rectangle == moved)
        controller.showWorkspace(.settings)
        controller.captureArrived(UUID())
        #expect(controller.panel.frame == moved)
        state.beforeCapture?(); state.afterCapture?()
        #expect(controller.panel.frame == moved)
        controller.showShelf()
        #expect(!controller.panel.isMovable)
        controller.showWorkspace(.meetings)
        #expect(controller.panel.frame == moved)
        controller.hide(); controller.showWorkspace(.meetings)
        #expect(controller.panel.frame == moved)
        controller.workspaceDragChanged(true)
        controller.panel.setFrameOrigin(NSPoint(x: moved.minX - 8, y: moved.minY + 8))
        let quickDrop = controller.panel.frame
        controller.showShelf() // Collapse while the title interaction is still active.
        controller.workspaceDragChanged(false)
        #expect(try repository.load().preferences.workspaceFrame?.rectangle == quickDrop)
        controller.showWorkspace(.meetings)
        #expect(controller.panel.frame == quickDrop)
        await state.shutdown()
        let reopened = AppState(repository: repository, screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let restored = ShelfPanelController(state: reopened, monitorsPointer: false)
        defer { restored.shutdown() }
        restored.showWorkspace(.settings)
        #expect(restored.panel.frame == quickDrop)
        await reopened.shutdown()
    }

    @Test func reopeningKeepsTheWorkspaceAndDoesNotInterruptRegionCapture() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyReopenTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.reopen()
        #expect(controller.presentation.mode == .shelf)
        controller.showWorkspace(.settings)
        let content = try #require(controller.panel.contentView)
        controller.reopen()
        #expect(controller.presentation.mode == .workspace && state.tab == .settings)
        #expect(controller.panel.contentView === content && controller.panel.isVisible)
        state.beforeCapture?()
        controller.reopen()
        #expect(!controller.panel.isVisible && controller.presentation.mode == .workspace)
        state.afterCapture?()
        controller.hide()
        controller.reopen()
        #expect(controller.presentation.mode == .shelf)
        await state.shutdown()
    }

    @Test func outsideClickDismissesWorkspaceWhileItsControlsAndPopupsRemainUsable() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyOutsideTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.showWorkspace(.meetings)
        let inside = NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY)
        let outside = NSPoint(x: controller.panel.frame.minX - 30, y: controller.panel.frame.minY - 30)
        controller.workspaceMouseDown(at: inside)
        #expect(controller.panel.isVisible && controller.presentation.mode == .workspace)

        let child = NSPanel(contentRect: NSRect(x: outside.x - 20, y: outside.y - 20, width: 40, height: 40),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        controller.panel.addChildWindow(child, ordered: .above)
        controller.workspaceMouseDown(at: outside, in: child)
        #expect(controller.panel.isVisible)
        controller.panel.removeChildWindow(child); child.orderOut(nil)
        let menu = NSPanel(contentRect: child.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        menu.level = .popUpMenu
        controller.workspaceMouseDown(at: outside, in: menu)
        #expect(controller.panel.isVisible)
        state.isPinnedOpen = true
        controller.workspaceMouseDown(at: outside, fromOtherApp: true)
        #expect(controller.presentation.mode == .hidden && !controller.panel.isVisible)
        #expect(state.tab == .meetings && !state.isPinnedOpen)
        await state.shutdown()
    }

    @Test func reopeningWorkspaceRetainsItsViewAndDismissalDisarmsHover() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyRetainedTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.showWorkspace(.meetings)
        let content = try #require(controller.panel.contentView)
        let outside = NSPoint(x: controller.panel.frame.minX - 30, y: controller.panel.frame.minY - 30)
        controller.workspaceMouseDown(at: outside)
        let barPoint = NSPoint(x: screen.frame.midX, y: screen.frame.maxY), now = Date()
        for interval in [0.0, 0.2, 0.5] { controller.checkPointer(at: barPoint, now: now.addingTimeInterval(interval), menuIsOpen: false) }
        #expect(!controller.panel.isVisible)
        controller.showShelf()
        #expect(controller.panel.contentView !== content)
        controller.showWorkspace(.meetings)
        #expect(controller.panel.contentView === content && controller.panel.isVisible)
        await state.shutdown()
    }

    @Test func outsideClickDoesNotInterruptScreenshotCaptureOrADrag() async {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyInteractionTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.showWorkspace(.meetings)
        let outside = NSPoint(x: controller.panel.frame.minX - 30, y: controller.panel.frame.minY - 30)
        state.beginCaptureInteraction()
        controller.workspaceMouseDown(at: outside)
        #expect(controller.panel.isVisible)
        state.endCaptureInteraction()
        state.beforeCapture?()
        controller.workspaceMouseDown(at: outside)
        #expect(controller.presentation.mode == .workspace && !controller.panel.isVisible)
        state.afterCapture?()
        #expect(controller.panel.isVisible && controller.presentation.mode == .workspace)
        controller.workspaceMouseDown(at: outside)
        #expect(!controller.panel.isVisible)
        await state.shutdown()
    }

    @Test func workspaceDismissalKeepsTheCompactShelfPolicyUnchanged() async {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyCompactTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        controller.showShelf(); state.isPinnedOpen = true
        let outside = NSPoint(x: controller.panel.frame.minX - 30, y: controller.panel.frame.minY - 30)
        controller.workspaceMouseDown(at: outside)
        #expect(controller.presentation.mode == .shelf && controller.panel.isVisible && state.isPinnedOpen)
        await state.shutdown()
    }

    @Test func importingWhileHiddenAutomaticallyShowsTheTopPreviewWithoutActivation() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyPanelTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("Arrival check.png")
        try Data([1, 2, 3]).write(to: source)
        #expect(controller.presentation.mode == .hidden && !controller.panel.isVisible)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        try await state.importScreenshot(source)
        let capture = try #require(state.library.captures.first)
        #expect(controller.presentation.mode == .arrival(capture.id))
        #expect(controller.panel.isVisible && !controller.panel.canBecomeKey)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        #expect(controller.panel.frame.size == NSSize(width: 244, height: 196))

        // Bring the panel back even if another native operation ordered it out
        // while the presentation model still considers it visible.
        controller.panel.orderOut(nil)
        controller.captureArrived(capture.id)
        #expect(controller.panel.isVisible)
        state.removeCapture(capture)
        #expect(controller.presentation.mode == .hidden && !controller.panel.isVisible)
        await state.shutdown()
    }

    @Test func menuBarRegionSpansTheWholeBarWithoutIncludingApplicationTitleBars() {
        let frame = NSRect(x: -1440, y: 200, width: 1440, height: 900)
        let visible = NSRect(x: -1440, y: 200, width: 1440, height: 872)
        let bar = ShelfPanelController.menuBarRect(frame: frame, visibleFrame: visible)
        #expect(bar.contains(NSPoint(x: -1420, y: 1080)))
        #expect(bar.contains(NSPoint(x: -20, y: 1080)))
        #expect(!bar.contains(NSPoint(x: -720, y: 1070)))
        #expect(!bar.contains(NSPoint(x: 20, y: 1080)))
        let hidden = ShelfPanelController.menuBarRect(frame: frame, visibleFrame: frame)
        #expect(hidden.height == 4)
        #expect(!hidden.contains(NSPoint(x: -20, y: 1080)))
        #expect(hidden.contains(NSPoint(x: -20, y: 1098)))
        #expect(ShelfPanelController.menuBarContains(NSPoint(x: -20, y: frame.maxY), frame: frame, visibleFrame: frame))
        #expect(!ShelfPanelController.menuBarContains(NSPoint(x: -20, y: frame.maxY + 1), frame: frame, visibleFrame: frame))
    }

    @Test func hoveringFarFromTopCenterShowsSmallShelfWithoutActivationThenTucksAway() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyHoverTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        let bar = ShelfPanelController.menuBarRect(frame: screen.frame, visibleFrame: screen.visibleFrame)
        let point = NSPoint(x: bar.minX + 24, y: bar.maxY)
        let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let now = Date()
        for interval in [0.0, 0.05, 0.1] {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
            #expect(!controller.panel.isVisible)
        }
        controller.checkPointer(at: point, now: now.addingTimeInterval(0.16), menuIsOpen: false)
        #expect(controller.presentation.mode == .shelf)
        #expect(controller.panel.isVisible && !controller.panel.canBecomeKey)
        #expect(controller.panel.frame.size == NSSize(width: 420, height: 100))
        #expect(abs(controller.panel.frame.midX - screen.visibleFrame.midX) < 1)
        #expect(NSWorkspace.shared.frontmostApplication?.processIdentifier == foreground)
        controller.checkPointer(at: point, now: now.addingTimeInterval(5), menuIsOpen: false)
        #expect(controller.panel.isVisible)
        controller.checkPointer(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY), now: now.addingTimeInterval(6), menuIsOpen: false)
        controller.checkPointer(at: NSPoint(x: controller.panel.frame.midX, y: controller.panel.frame.midY), now: now.addingTimeInterval(6.9), menuIsOpen: false)
        #expect(controller.panel.isVisible)
        let away = NSPoint(x: screen.frame.midX, y: screen.frame.midY)
        controller.checkPointer(at: away, now: now.addingTimeInterval(7), menuIsOpen: false)
        controller.checkPointer(at: away, now: now.addingTimeInterval(8), menuIsOpen: false)
        #expect(!controller.panel.isVisible && controller.presentation.mode == .hidden)
        await state.shutdown()
    }

    @Test func hoverRespectsPreferenceMouseButtonsAndDismissal() async throws {
        _ = NSApplication.shared
        let screen = try #require(NSScreen.screens.first)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyHoverTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: FileLibraryRepository(directory: directory), screenshot: PreviewScreenshot(), systemScreenshots: UnusedScreenshotManager())
        let controller = ShelfPanelController(state: state, monitorsPointer: false)
        defer { controller.shutdown() }
        let bar = ShelfPanelController.menuBarRect(frame: screen.frame, visibleFrame: screen.visibleFrame)
        let point = NSPoint(x: bar.maxX - 24, y: bar.midY), now = Date()
        state.library.preferences.revealOnHover = false
        for interval in stride(from: 0.0, through: 1.0, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(!controller.panel.isVisible)
        state.library.preferences.revealOnHover = true
        for interval in stride(from: 2.0, through: 3.0, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), mouseButtons: 1, menuIsOpen: false)
        }
        #expect(!controller.panel.isVisible)
        for interval in stride(from: 4.0, through: 4.6, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(controller.presentation.mode == .shelf)
        controller.menuBarMouseDown(at: point, dismissShelf: false)
        #expect(controller.panel.isVisible)
        state.isPinnedOpen = true
        controller.menuBarMouseDown(at: point)
        #expect(controller.panel.isVisible)
        state.isPinnedOpen = false
        controller.menuBarMouseDown(at: point)
        for interval in stride(from: 4.8, through: 5.6, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(!controller.panel.isVisible)
        controller.hide()
        for interval in stride(from: 5.8, through: 6.6, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(!controller.panel.isVisible)
        controller.checkPointer(at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), now: now.addingTimeInterval(7), menuIsOpen: false)
        for interval in stride(from: 8.0, through: 8.6, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(controller.presentation.mode == .shelf)
        controller.showWorkspace(.meetings)
        controller.menuBarMouseDown(at: point)
        for interval in stride(from: 9.0, through: 10.0, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: false)
        }
        #expect(controller.presentation.mode == .workspace && state.tab == .meetings)
        controller.hide()
        controller.checkPointer(at: NSPoint(x: screen.frame.midX, y: screen.frame.midY), now: now.addingTimeInterval(11), menuIsOpen: false)
        for interval in stride(from: 12.0, through: 12.8, by: 0.2) {
            controller.checkPointer(at: point, now: now.addingTimeInterval(interval), menuIsOpen: true)
        }
        #expect(!controller.panel.isVisible)
        await state.shutdown()
    }
}
