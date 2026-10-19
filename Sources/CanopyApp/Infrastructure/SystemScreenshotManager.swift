import CanopyCore
import Foundation

@MainActor
protocol SystemScreenshotManaging: AnyObject {
    var previousDirectory: URL? { get }
    func begin(in directory: URL) throws
    func end() throws
}
extension SystemScreenshotManaging { var previousDirectory: URL? { nil } }

@MainActor
enum SystemScreenshotManagerFactory {
    static func make(journalURL: URL) -> SystemScreenshotManaging {
        #if CANOPY_APP_STORE
        // Store builds never access another application's preference domain,
        // including when upgrading a library that previously enabled routing.
        return UnmanagedSystemScreenshots()
        #else
        return NativeSystemScreenshotManager(journalURL: journalURL)
        #endif
    }
}

@MainActor
final class UnmanagedSystemScreenshots: SystemScreenshotManaging {
    func begin(in directory: URL) throws { throw CocoaError(.featureUnsupported) }
    func end() throws { }
}

#if !CANOPY_APP_STORE
@MainActor
final class NativeSystemScreenshotManager: SystemScreenshotManaging {
    private let lease: ScreenshotSettingsLease
    init(journalURL: URL) {
        lease = ScreenshotSettingsLease(store: MacScreenshotPreferences(), journalURL: journalURL, destinationPolicy: .sharedDestination)
    }
    var previousDirectory: URL? {
        lease.previousPreferences?.effectiveScreenshotLocation.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    }
    func begin(in directory: URL) throws { try lease.acquire(directory: directory) }
    func end() throws { try lease.restore() }
}

/// Only the screenshot routing keys are written; other Screenshot preferences remain
/// owned by macOS. Missing keys are restored by removing our overrides.
struct MacScreenshotPreferences: SystemScreenshotPreferenceStoring {
    private let domain: CFString
    init(domain: String = "com.apple.screencapture") { self.domain = domain as CFString }

    func read() throws -> SystemScreenshotPreferences {
        CFPreferencesAppSynchronize(domain)
        return SystemScreenshotPreferences(
            location: try stringValue("location"),
            screenshotLocation: try stringValue("location-screenshot"),
            showsThumbnail: try thumbnailValue(),
            screenshotTarget: try stringValue("target-screenshot"))
    }
    private func stringValue(_ key: String) throws -> String? {
        guard let raw = CFPreferencesCopyAppValue(key as CFString, domain) else { return nil }
        // Refuse an unsupported value instead of treating it as a missing key and
        // destroying the user's original value when restoring the lease.
        guard let value = raw as? String else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    private func thumbnailValue() throws -> Bool? {
        guard let raw = CFPreferencesCopyAppValue("show-thumbnail" as CFString, domain) else { return nil }
        guard let value = raw as? NSNumber, value == 0 || value == 1 else { throw CocoaError(.fileReadCorruptFile) }
        return value.boolValue
    }
    func write(_ preferences: SystemScreenshotPreferences) throws {
        CFPreferencesSetAppValue("location" as CFString, preferences.location as CFPropertyList?, domain)
        // Apple's macOS 27 capture binaries use location-screenshot. Keep location
        // for earlier macOS versions, and journal both keys independently.
        CFPreferencesSetAppValue("location-screenshot" as CFString, preferences.screenshotLocation as CFPropertyList?, domain)
        CFPreferencesSetAppValue("show-thumbnail" as CFString, preferences.showsThumbnail.map { NSNumber(value: $0) }, domain)
        CFPreferencesSetAppValue("target-screenshot" as CFString, preferences.screenshotTarget as CFPropertyList?, domain)
        guard CFPreferencesAppSynchronize(domain) else { throw CocoaError(.fileWriteUnknown) }
        guard try read() == preferences else { throw CocoaError(.fileWriteUnknown) }
    }
}
#endif
