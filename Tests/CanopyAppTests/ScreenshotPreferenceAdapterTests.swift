import CanopyCore
import Foundation
import Testing
@testable import CanopyApp

#if !CANOPY_APP_STORE
struct ScreenshotPreferenceAdapterTests {
    @Test func unsupportedRawLocationCannotBeMistakenForAnAbsentPreference() throws {
        let domain = "com.canopy.test.screenshot." + UUID().uuidString
        let raw = Data([1, 2, 3])
        CFPreferencesSetAppValue("location-screenshot" as CFString, raw as CFData, domain as CFString)
        CFPreferencesAppSynchronize(domain as CFString)
        defer {
            CFPreferencesSetAppValue("location-screenshot" as CFString, nil, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyAdapterTest-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let lease = ScreenshotSettingsLease(store: MacScreenshotPreferences(domain: domain), journalURL: directory.appendingPathComponent("lease.json"))
        #expect(throws: (any Error).self) { try lease.acquire(directory: directory.appendingPathComponent("Inbox")) }
        #expect(CFPreferencesCopyAppValue("location-screenshot" as CFString, domain as CFString) as? Data == raw)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("lease.json").path))
    }

    @Test func platformAdapterWritesTheModernKeyAndRestoresAbsentKeys() throws {
        // Exercise CFPreferences in an isolated suite, never the system domain.
        let domain = "com.canopy.test.screenshot." + UUID().uuidString
        let store = MacScreenshotPreferences(domain: domain)
        defer { try? store.write(.init()) }
        let preferences = SystemScreenshotPreferences(location: "/legacy", screenshotLocation: "/modern", showsThumbnail: false, screenshotTarget: "file")
        try store.write(preferences)
        #expect(try store.read() == preferences)
        #expect(CFPreferencesCopyAppValue("location-screenshot" as CFString, domain as CFString) as? String == "/modern")
        try store.write(.init())
        #expect(try store.read() == .init())
        #expect(CFPreferencesCopyAppValue("location-screenshot" as CFString, domain as CFString) == nil)
    }
}
#endif
