import Foundation
import Testing
@testable import CanopyCore

struct ShelfPresentationTests {
    private let start = Date(timeIntervalSince1970: 1000)

    @Test func arrivalTucksAwayWithoutPointerInteraction() {
        var presentation = ShelfPresentation()
        let capture = UUID()
        presentation.captureArrived(capture, at: start)
        presentation.tick(at: start.addingTimeInterval(3), pointerInside: false, pinned: false)
        #expect(presentation.mode == .arrival(capture))
        presentation.tick(at: start.addingTimeInterval(4), pointerInside: false, pinned: false)
        presentation.tick(at: start.addingTimeInterval(5), pointerInside: false, pinned: false)
        #expect(presentation.mode == .hidden)
    }

    @Test func hoveringPausesDismissalAndLeavingResumesIt() {
        var presentation = ShelfPresentation()
        let capture = UUID()
        presentation.captureArrived(capture, at: start)
        presentation.tick(at: start.addingTimeInterval(20), pointerInside: true, pinned: false)
        #expect(presentation.mode == .arrival(capture))
        presentation.tick(at: start.addingTimeInterval(21), pointerInside: false, pinned: false)
        presentation.tick(at: start.addingTimeInterval(22), pointerInside: false, pinned: false)
        #expect(presentation.mode == .hidden)
    }

    @Test func successiveScreenshotsReplacePreviewAndExtendItsLifetime() {
        var presentation = ShelfPresentation()
        presentation.captureArrived(UUID(), at: start)
        let latest = UUID()
        presentation.captureArrived(latest, at: start.addingTimeInterval(3))
        presentation.tick(at: start.addingTimeInterval(5), pointerInside: false, pinned: false)
        #expect(presentation.mode == .arrival(latest))
        presentation.tick(at: start.addingTimeInterval(7), pointerInside: false, pinned: false)
        presentation.tick(at: start.addingTimeInterval(8), pointerInside: false, pinned: false)
        #expect(presentation.mode == .hidden)
    }

    @Test func captureCannotReplaceWorkspaceOrExpandedShelf() {
        var presentation = ShelfPresentation()
        presentation.openWorkspace()
        presentation.captureArrived(UUID(), at: start)
        presentation.tick(at: start.addingTimeInterval(30), pointerInside: false, pinned: false)
        #expect(presentation.mode == .workspace)
        presentation.openShelf(at: start, explicitly: true)
        presentation.captureArrived(UUID(), at: start)
        #expect(presentation.mode == .shelf)
    }

    @Test func explicitOpenGivesTimeToReachShelfAndPinKeepsItVisible() {
        var presentation = ShelfPresentation()
        presentation.openShelf(at: start, explicitly: true)
        presentation.tick(at: start.addingTimeInterval(2), pointerInside: false, pinned: false)
        #expect(presentation.mode == .shelf)
        presentation.tick(at: start.addingTimeInterval(20), pointerInside: false, pinned: true)
        #expect(presentation.mode == .shelf)
        presentation.tick(at: start.addingTimeInterval(21), pointerInside: false, pinned: false)
        presentation.tick(at: start.addingTimeInterval(22), pointerInside: false, pinned: false)
        #expect(presentation.mode == .hidden)
    }

    @Test func pinCannotMakeBackgroundArrivalPermanent() {
        var presentation = ShelfPresentation()
        presentation.captureArrived(UUID(), at: start)
        presentation.tick(at: start.addingTimeInterval(4), pointerInside: false, pinned: true)
        presentation.tick(at: start.addingTimeInterval(5), pointerInside: false, pinned: true)
        #expect(presentation.mode == .hidden)
    }

    @Test func arrivalCannotShortenExplicitOpenGracePeriod() {
        var presentation = ShelfPresentation()
        presentation.openShelf(at: start, explicitly: true)
        presentation.captureArrived(UUID(), at: start.addingTimeInterval(1))
        presentation.tick(at: start.addingTimeInterval(5), pointerInside: false, pinned: false)
        presentation.tick(at: start.addingTimeInterval(6), pointerInside: false, pinned: false)
        #expect(presentation.mode == .shelf)
    }
    @Test func releasingADragRestartsThePointerAwayGracePeriod() {
        var shelf = ShelfPresentation()
        let now = Date(), id = UUID()
        shelf.captureArrived(id, at: now)
        shelf.tick(at: now.addingTimeInterval(8), pointerInside: false, pinned: false)
        shelf.resumeAfterInteraction(at: now.addingTimeInterval(30))
        shelf.tick(at: now.addingTimeInterval(30.5), pointerInside: false, pinned: false)
        #expect(shelf.mode == .arrival(id))
        shelf.tick(at: now.addingTimeInterval(31), pointerInside: false, pinned: false)
        shelf.tick(at: now.addingTimeInterval(32), pointerInside: false, pinned: false)
        #expect(shelf.mode == .hidden)
    }
}
