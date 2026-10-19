import Foundation

/// Requires a continuous menu-bar hover and a fresh entry after dismissal.
/// Display IDs keep time spent on one screen from revealing another screen's shelf.
public struct ShelfHoverReveal: Sendable {
    private let delay: TimeInterval = 0.15
    private let maximumSampleGap: TimeInterval = 0.35
    private var candidate: UInt32?
    private var enteredAt: Date?
    private var lastSampleAt: Date?
    private var armed = true

    public init() {}

    public mutating func sample(display: UInt32?, eligible: Bool, at now: Date) -> Bool {
        defer { lastSampleAt = now }
        guard let display else {
            armed = true; candidate = nil; enteredAt = nil
            return false
        }
        guard eligible, armed else {
            candidate = nil; enteredAt = nil
            return false
        }
        let continuous = lastSampleAt.map { now >= $0 && now.timeIntervalSince($0) <= maximumSampleGap } ?? false
        if candidate != display || !continuous {
            candidate = display; enteredAt = now
            return false
        }
        guard let enteredAt, now.timeIntervalSince(enteredAt) >= delay else { return false }
        disarm()
        return true
    }

    public mutating func disarm() {
        armed = false
        suspend()
    }

    public mutating func suspend() {
        candidate = nil; enteredAt = nil; lastSampleAt = nil
    }
}
