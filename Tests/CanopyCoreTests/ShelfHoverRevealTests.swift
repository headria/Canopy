import Foundation
import Testing
@testable import CanopyCore

struct ShelfHoverRevealTests {
    private let start = Date(timeIntervalSince1970: 1000)

    // Evaluate mutation before the assertion; Swift Testing captures method receivers as immutable.
    private func expectSample(_ hover: inout ShelfHoverReveal, display: UInt32? = 1, eligible: Bool = true, at time: Date, reveals: Bool = false) {
        let revealed = hover.sample(display: display, eligible: eligible, at: time)
        #expect(revealed == reveals)
    }

    private func dwell(_ hover: inout ShelfHoverReveal, display: UInt32 = 1, from time: Date) -> Bool {
        expectSample(&hover, display: display, at: time)
        expectSample(&hover, display: display, at: time.addingTimeInterval(0.05))
        expectSample(&hover, display: display, at: time.addingTimeInterval(0.1))
        return hover.sample(display: display, eligible: true, at: time.addingTimeInterval(0.16))
    }

    @Test func continuousShortHoverRevealsOnlyOnceUntilPointerLeaves() {
        var hover = ShelfHoverReveal()
        #expect(dwell(&hover, from: start))
        expectSample(&hover, at: start.addingTimeInterval(1))
        expectSample(&hover, at: start.addingTimeInterval(2))
        expectSample(&hover, display: nil, at: start.addingTimeInterval(3))
        #expect(dwell(&hover, from: start.addingTimeInterval(4)))
    }

    @Test func briefPassThroughAndSwitchingDisplaysRestartTheDelay() {
        var hover = ShelfHoverReveal()
        expectSample(&hover, at: start)
        expectSample(&hover, display: nil, at: start.addingTimeInterval(0.04))
        expectSample(&hover, at: start.addingTimeInterval(0.06))
        expectSample(&hover, display: 2, at: start.addingTimeInterval(0.1))
        expectSample(&hover, display: 2, at: start.addingTimeInterval(0.15))
        expectSample(&hover, display: 2, at: start.addingTimeInterval(0.2))
        expectSample(&hover, display: 2, at: start.addingTimeInterval(0.26), reveals: true)
    }

    @Test func dismissalUnderPointerCannotImmediatelyReopenTheShelf() {
        var hover = ShelfHoverReveal()
        hover.disarm()
        #expect(!dwell(&hover, from: start))
        expectSample(&hover, display: nil, at: start.addingTimeInterval(1))
        #expect(dwell(&hover, from: start.addingTimeInterval(2)))
    }

    @Test func ineligibleInteractionResetsAnUnfinishedDelay() {
        var hover = ShelfHoverReveal()
        expectSample(&hover, at: start)
        expectSample(&hover, at: start.addingTimeInterval(0.05))
        expectSample(&hover, eligible: false, at: start.addingTimeInterval(0.1))
        #expect(dwell(&hover, from: start.addingTimeInterval(0.12)))
    }

    @Test func pausedTimerAndClockChangesRequireAFreshContinuousHover() {
        var hover = ShelfHoverReveal()
        expectSample(&hover, at: start)
        expectSample(&hover, at: start.addingTimeInterval(0.05))
        #expect(dwell(&hover, from: start.addingTimeInterval(10)))
        var adjusted = ShelfHoverReveal()
        expectSample(&adjusted, at: start.addingTimeInterval(20))
        #expect(dwell(&adjusted, from: start))
    }

    @Test func suspendingForCaptureOrDragResetsTimeWithoutRearmingDismissal() {
        var hover = ShelfHoverReveal()
        expectSample(&hover, at: start)
        hover.suspend()
        #expect(dwell(&hover, from: start.addingTimeInterval(0.2)))
        hover.suspend()
        #expect(!dwell(&hover, from: start.addingTimeInterval(1)))
    }
}
