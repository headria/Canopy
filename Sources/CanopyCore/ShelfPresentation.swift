import Foundation

/// Window-independent interaction policy. Background captures can reveal a preview,
/// but can never open or replace the workspace the user is editing.
public struct ShelfPresentation: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case hidden, arrival(UUID), shelf, workspace
    }
    public private(set) var mode: Mode = .hidden
    private var minimumVisibleUntil: Date?
    private var awaySince: Date?

    public init() {}

    public mutating func captureArrived(_ id: UUID, at now: Date) {
        guard mode != .workspace else { return }
        if mode != .shelf { mode = .arrival(id) }
        minimumVisibleUntil = max(minimumVisibleUntil ?? now, now.addingTimeInterval(4))
        awaySince = nil
    }

    public mutating func openShelf(at now: Date, explicitly: Bool) {
        mode = .shelf
        minimumVisibleUntil = now.addingTimeInterval(explicitly ? 8 : 0)
        awaySince = nil
    }

    public mutating func openWorkspace() {
        mode = .workspace; minimumVisibleUntil = nil; awaySince = nil
    }

    public mutating func hide() {
        mode = .hidden; minimumVisibleUntil = nil; awaySince = nil
    }

    public mutating func resumeAfterInteraction(at now: Date) {
        guard mode != .hidden, mode != .workspace else { return }
        minimumVisibleUntil = max(minimumVisibleUntil ?? now, now.addingTimeInterval(1))
        awaySince = nil
    }

    public mutating func tick(at now: Date, pointerInside: Bool, pinned: Bool) {
        guard mode != .hidden, mode != .workspace else { return }
        if pointerInside || (pinned && mode == .shelf) {
            awaySince = nil
            return
        }
        if let minimumVisibleUntil, now < minimumVisibleUntil { return }
        if let awaySince {
            if now.timeIntervalSince(awaySince) >= 0.8 { hide() }
        } else { awaySince = now }
    }
}
