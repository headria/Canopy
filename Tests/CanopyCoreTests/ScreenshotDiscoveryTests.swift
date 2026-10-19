import CanopyCore
import Foundation
import Testing

struct ScreenshotDiscoveryTests {
    private func file(_ name: String = "Screenshot 2026-10-08 at 6.00.00 AM.png", size: Int = 100, time: Double = 1, screenshot: Bool = true) -> ScreenshotFileSnapshot {
        ScreenshotFileSnapshot(url: URL(fileURLWithPath: "/tmp/\(name)"), size: size, modifiedAt: Date(timeIntervalSince1970: time), isScreenshot: screenshot)
    }

    @Test func ignoresExistingFilesAndImportsEachNewFileOnce() {
        var discovery = ScreenshotDiscovery()
        let old = file("old.png"), new = file()
        discovery.begin(with: [old])
        #expect(discovery.ready(in: [old, new]).isEmpty)
        #expect(discovery.ready(in: [old, new]) == [new])
        discovery.markImported(new)
        #expect(discovery.ready(in: [old, new]).isEmpty)
    }
    @Test func waitsForBothSizeAndModificationTimeToStabilize() {
        var discovery = ScreenshotDiscovery(); discovery.begin(with: [])
        #expect(discovery.ready(in: [file(size: 0)]).isEmpty)
        #expect(discovery.ready(in: [file(size: 10)]).isEmpty)
        #expect(discovery.ready(in: [file(size: 20, time: 2)]).isEmpty)
        #expect(discovery.ready(in: [file(size: 20, time: 3)]).isEmpty)
        #expect(discovery.ready(in: [file(size: 20, time: 3)]) == [file(size: 20, time: 3)])
    }
    @Test func delayedMetadataAndFailedImportsRemainEligible() {
        var discovery = ScreenshotDiscovery(); discovery.begin(with: [])
        #expect(discovery.ready(in: [file(screenshot: false)]).isEmpty)
        #expect(discovery.ready(in: [file()]).isEmpty)
        #expect(discovery.ready(in: [file()]) == [file()])
        // Not acknowledged: a transient import failure retries instead of losing the file.
        #expect(discovery.ready(in: [file()]) == [file()])
        discovery.markImported(file())
        #expect(discovery.ready(in: [file()]).isEmpty)
    }
    @Test func recognizesDatedNamesWithoutSpotlightAndSupportsOtherImageFormats() {
        #expect(ScreenshotClassification.isScreenshot(url: file().url, metadataFlag: false))
        #expect(ScreenshotClassification.isScreenshot(url: file("Screen Shot 2026-10-08 at 06.00.00.jpeg").url, metadataFlag: false))
        #expect(ScreenshotClassification.isScreenshot(url: file("custom-name.heic").url, metadataFlag: true))
        #expect(!ScreenshotClassification.isScreenshot(url: file("holiday.png").url, metadataFlag: false))
        #expect(!ScreenshotClassification.isScreenshot(url: file("Screenshot 2026-10-08 at 6.00.txt").url, metadataFlag: true))
    }
    @Test func oldPreferencesMigrateAndDetectionChoicePersists() throws {
        let old = Data(#"{"revealOnHover":false,"speechLocale":"fr-FR","jevEndpoint":"https://api.typesafe.ai/v1/systemone"}"#.utf8)
        var preferences = try JSONDecoder().decode(Preferences.self, from: old)
        #expect(preferences.screenshotWatchingEnabled && preferences.managesSystemScreenshots && preferences.screenshotFolder == nil)
        #expect(!preferences.revealOnHover && preferences.speechLocale == "fr-FR")
        preferences.screenshotWatchingEnabled = false
        preferences.managesSystemScreenshots = false
        preferences.screenshotFolder = "/tmp/screenshots"
        #expect(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences)) == preferences)
    }
}
