import Foundation
import CoreGraphics
import Testing
@testable import CanopyCore

struct WorkspacePlacementTests {
    private let main = CGRect(x: 0, y: 40, width: 1440, height: 860)

    @Test func newWorkspaceOpensInTheCenter() {
        let frame = WorkspacePlacement().frame(on: [main], preferredDisplay: main)
        #expect(frame.midX == main.midX && frame.midY == main.midY)
        #expect(frame.size == CGSize(width: 900, height: 620))
    }
    @Test func movedWorkspaceStaysOnItsDisplayWhenThePointerChangesDisplays() {
        let second = CGRect(x: -1440, y: 40, width: 1440, height: 860)
        let moved = CGRect(x: -1200, y: 140, width: 900, height: 620)
        var placement = WorkspacePlacement(); placement.remember(moved)
        #expect(placement.frame(on: [main, second], preferredDisplay: main) == moved)
    }
    @Test func removedOrSmallerDisplayKeepsTheWindowWithinReach() {
        var placement = WorkspacePlacement()
        placement.remember(CGRect(x: -1200, y: 1200, width: 900, height: 620))
        let small = CGRect(x: 200, y: -700, width: 800, height: 600)
        let restored = placement.frame(on: [small], preferredDisplay: small)
        #expect(small.contains(restored))
        #expect(restored.width == 760 && restored.height == 560)
    }
    @Test func invalidPositionsAreIgnoredAndSavedPreferencesRemainCompatible() throws {
        var placement = WorkspacePlacement()
        placement.remember(CGRect(x: CGFloat.infinity, y: 0, width: 900, height: 620))
        #expect(placement.rememberedFrame == nil)
        var preferences = try JSONDecoder().decode(Preferences.self, from: Data("{}".utf8))
        #expect(preferences.workspaceFrame == nil)
        preferences.workspaceFrame = WorkspaceFrame(CGRect(x: 80, y: 150, width: 900, height: 620))
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)).workspaceFrame == preferences.workspaceFrame)
    }
}
