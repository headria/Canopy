import Foundation

public struct SystemScreenshotPreferences: Codable, Equatable, Sendable {
    public var location: String?
    /// macOS 27 separates screenshot and screen-recording destinations.
    public var screenshotLocation: String?
    public var showsThumbnail: Bool?
    public var screenshotTarget: String?
    public var effectiveScreenshotLocation: String? { screenshotLocation ?? location }
    public init(location: String? = nil, screenshotLocation: String? = nil, showsThumbnail: Bool? = nil, screenshotTarget: String? = nil) {
        self.location = location; self.screenshotLocation = screenshotLocation
        self.showsThumbnail = showsThumbnail; self.screenshotTarget = screenshotTarget
    }
}

public protocol SystemScreenshotPreferenceStoring {
    func read() throws -> SystemScreenshotPreferences
    func write(_ preferences: SystemScreenshotPreferences) throws
}

/// A recoverable lease over the screenshot settings. The journal is written before
/// changing macOS, and survives a crash without replacing the user's original values.
public final class ScreenshotSettingsLease {
    public enum DestinationPolicy {
        case sharedDestination
        /// macOS 27 has a separate image destination. Leave screen recordings alone.
        case screenshotsOnly
    }
    private struct Journal: Codable {
        var version = 2
        let previous: SystemScreenshotPreferences
        let applied: SystemScreenshotPreferences
    }
    private let store: SystemScreenshotPreferenceStoring
    private let journalURL: URL
    private let destinationPolicy: DestinationPolicy
    private var active: Journal?
    public private(set) var previousPreferences: SystemScreenshotPreferences?

    public init(store: SystemScreenshotPreferenceStoring, journalURL: URL, destinationPolicy: DestinationPolicy = .sharedDestination) {
        self.store = store; self.journalURL = journalURL; self.destinationPolicy = destinationPolicy
    }

    public func acquire(directory: URL) throws {
        // Recover a previous interrupted lease before taking a fresh snapshot.
        try restore()
        let current = try store.read()
        let applied = SystemScreenshotPreferences(location: destinationPolicy == .screenshotsOnly ? current.location : directory.path, screenshotLocation: directory.path,
                                                  showsThumbnail: false, screenshotTarget: "file")
        let journal = Journal(previous: current, applied: applied)
        previousPreferences = current
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        active = journal
        do { try store.write(applied) }
        catch { try? restore(); throw error }
    }

    public func restore() throws {
        if active == nil, FileManager.default.fileExists(atPath: journalURL.path) {
            let saved = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
            guard (1...2).contains(saved.version) else { throw CocoaError(.fileReadCorruptFile) }
            active = saved
        }
        guard let journal = active else { return }
        previousPreferences = journal.previous
        let current = try store.read()
        // Restore only fields that still match our overrides; explicit edits win.
        var restored = current
        if current.location == journal.applied.location { restored.location = journal.previous.location }
        if current.screenshotLocation == journal.applied.screenshotLocation { restored.screenshotLocation = journal.previous.screenshotLocation }
        if current.showsThumbnail == journal.applied.showsThumbnail { restored.showsThumbnail = journal.previous.showsThumbnail }
        if current.screenshotTarget == journal.applied.screenshotTarget { restored.screenshotTarget = journal.previous.screenshotTarget }
        if restored != current {
            try store.write(restored)
        }
        // Settings can still be restored from memory if the journal was removed
        // while the app was running.
        if FileManager.default.fileExists(atPath: journalURL.path) {
            try FileManager.default.removeItem(at: journalURL)
        }
        active = nil
    }
}
