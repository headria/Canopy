import Foundation
import Testing
@testable import CanopyCore

private final class PreferenceMemory: SystemScreenshotPreferenceStoring {
    var value: SystemScreenshotPreferences
    var failNextWriteAfterApplying = false
    init(_ value: SystemScreenshotPreferences = .init()) { self.value = value }
    func read() throws -> SystemScreenshotPreferences { value }
    func write(_ preferences: SystemScreenshotPreferences) throws {
        value = preferences
        if failNextWriteAfterApplying { failNextWriteAfterApplying = false; throw CocoaError(.fileWriteUnknown) }
    }
}

struct ScreenshotSettingsTests {
    @Test func screenshotOnlyLeasePreservesRecordingsAndRecoversAfterRestart() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SystemScreenshotPreferences(location: "/recordings", showsThumbnail: true, screenshotTarget: "clipboard")
        let store = PreferenceMemory(original)
        let journal = folder.appendingPathComponent("lease.json")
        let lease = ScreenshotSettingsLease(store: store, journalURL: journal, destinationPolicy: .screenshotsOnly)
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        #expect(store.value.location == "/recordings" && store.value.showsThumbnail == false)
        #expect(store.value.screenshotLocation == folder.appendingPathComponent("Inbox").path)
        store.value.location = "/new-recordings"
        try ScreenshotSettingsLease(store: store, journalURL: journal, destinationPolicy: .screenshotsOnly).restore()
        var expected = original; expected.location = "/new-recordings"
        #expect(store.value == expected)
        #expect(!FileManager.default.fileExists(atPath: journal.path))
    }
    @Test func screenshotOnlyLeaseRestoresAnAbsentRecordingPreferenceAfterPartialWriteFailure() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory()
        store.failNextWriteAfterApplying = true
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"), destinationPolicy: .screenshotsOnly)
        #expect(throws: (any Error).self) { try lease.acquire(directory: folder.appendingPathComponent("Inbox")) }
        #expect(store.value == .init())
    }
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("CanopySettingsTest-\(UUID())") }

    @Test func managesAndRestoresModernAndLegacyDestinationsIndependently() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SystemScreenshotPreferences(location: "/legacy", screenshotLocation: "/screenshots", showsThumbnail: true)
        let store = PreferenceMemory(original)
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        let inbox = folder.appendingPathComponent("Inbox")
        try lease.acquire(directory: inbox)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("lease.json"))) as? [String: Any]
        #expect(saved?["version"] as? Int == 2)
        #expect(store.value.location == inbox.path && store.value.screenshotLocation == inbox.path)
        #expect(store.value.effectiveScreenshotLocation == inbox.path)
        try lease.restore()
        #expect(store.value == original && store.value.effectiveScreenshotLocation == "/screenshots")
    }

    @Test func preservesAnExplicitModernDestinationChange() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory(.init(location: "/legacy", screenshotLocation: "/screenshots", showsThumbnail: true))
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        store.value.screenshotLocation = "/new-choice"
        try lease.restore()
        #expect(store.value.location == "/legacy" && store.value.screenshotLocation == "/new-choice")
        #expect(store.value.showsThumbnail == true)
    }

    @Test func oldJournalRestoresWithoutTouchingTheModernDestination() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = folder.appendingPathComponent("lease.json")
        let oldJournal = #"{"version":1,"previous":{"location":"/original","showsThumbnail":true},"applied":{"location":"/inbox","showsThumbnail":false,"screenshotTarget":"file"}}"#
        try Data(oldJournal.utf8).write(to: journal)
        let store = PreferenceMemory(.init(location: "/inbox", screenshotLocation: "/modern-user-choice", showsThumbnail: false, screenshotTarget: "file"))
        try ScreenshotSettingsLease(store: store, journalURL: journal).restore()
        #expect(store.value == .init(location: "/original", screenshotLocation: "/modern-user-choice", showsThumbnail: true))
    }

    @Test func restoresMissingKeysAndOriginalClipboardTarget() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SystemScreenshotPreferences(screenshotTarget: "clipboard")
        let store = PreferenceMemory(original)
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        #expect(store.value.showsThumbnail == false && store.value.screenshotTarget == "file")
        #expect(store.value.location != nil)
        try lease.restore()
        #expect(store.value == original)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("lease.json").path))
    }

    @Test func interruptedSessionKeepsTheOriginalBackupOnRelaunch() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SystemScreenshotPreferences(location: "/Users/example/Pictures", showsThumbnail: true)
        let store = PreferenceMemory(original), journal = folder.appendingPathComponent("lease.json"), inbox = folder.appendingPathComponent("Inbox")
        try ScreenshotSettingsLease(store: store, journalURL: journal).acquire(directory: inbox)
        let relaunched = ScreenshotSettingsLease(store: store, journalURL: journal)
        try relaunched.acquire(directory: inbox)
        try relaunched.restore()
        #expect(store.value == original)
    }

    @Test func restoresOurOtherOverridesWhileLeavingAChangedDestinationAlone() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory(.init(location: "/original", showsThumbnail: true))
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        let replacement = SystemScreenshotPreferences(location: "/other-app", showsThumbnail: false, screenshotTarget: "file")
        store.value = replacement
        try lease.restore()
        #expect(store.value.location == replacement.location)
        #expect(store.value.showsThumbnail == true && store.value.screenshotTarget == nil)
    }

    @Test func aRelaunchCanRestoreTheJournalWithoutAcquiringAgain() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory(.init(location: "/original", showsThumbnail: true)), original = store.value
        let journal = folder.appendingPathComponent("lease.json")
        try ScreenshotSettingsLease(store: store, journalURL: journal).acquire(directory: folder.appendingPathComponent("Inbox"))
        try ScreenshotSettingsLease(store: store, journalURL: journal).restore()
        #expect(store.value == original && !FileManager.default.fileExists(atPath: journal.path))
    }

    @Test func preservesAnExplicitThumbnailChangeWhileRestoringTheFolder() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory()
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        store.value.showsThumbnail = true
        try lease.restore()
        #expect(store.value.location == nil && store.value.showsThumbnail == true)
    }

    @Test func partiallyAppliedSettingsAreRolledBack() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let original = SystemScreenshotPreferences(location: "/original", showsThumbnail: true)
        let store = PreferenceMemory(original); store.failNextWriteAfterApplying = true
        let lease = ScreenshotSettingsLease(store: store, journalURL: folder.appendingPathComponent("lease.json"))
        #expect(throws: (any Error).self) { try lease.acquire(directory: folder.appendingPathComponent("Inbox")) }
        #expect(store.value == original)
    }

    @Test func missingJournalDuringActiveLeaseStillRestoresAndCanAcquireAgain() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        let store = PreferenceMemory(.init(location: "/original", showsThumbnail: true)), original = store.value
        let journal = folder.appendingPathComponent("lease.json")
        let lease = ScreenshotSettingsLease(store: store, journalURL: journal)
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        try FileManager.default.removeItem(at: journal)
        try lease.restore()
        #expect(store.value == original)
        try lease.acquire(directory: folder.appendingPathComponent("Inbox"))
        try lease.restore()
        #expect(store.value == original)
    }

    @Test func newerJournalVersionCannotPartiallyRestoreSettings() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = folder.appendingPathComponent("lease.json")
        let data = Data(#"{"version":3,"previous":{},"applied":{}}"#.utf8)
        try data.write(to: journal)
        let store = PreferenceMemory(.init(location: "/original", screenshotLocation: "/modern")), original = store.value
        #expect(throws: (any Error).self) { try ScreenshotSettingsLease(store: store, journalURL: journal).restore() }
        #expect(store.value == original)
        #expect(try Data(contentsOf: journal) == data)
    }

    @Test func corruptBackupCannotOverwriteCurrentSettings() throws {
        let folder = directory(); defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let journal = folder.appendingPathComponent("lease.json")
        try Data("broken".utf8).write(to: journal)
        let store = PreferenceMemory(.init(location: "/original", showsThumbnail: true)), original = store.value
        let lease = ScreenshotSettingsLease(store: store, journalURL: journal)
        #expect(throws: (any Error).self) { try lease.acquire(directory: folder.appendingPathComponent("Inbox")) }
        #expect(store.value == original)
        #expect(try Data(contentsOf: journal) == Data("broken".utf8))
    }
}
