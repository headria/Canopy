import CanopyCore
import Foundation
import ScreenCaptureKit
import Testing
@testable import CanopyApp

@MainActor
private final class FakeCapture: MeetingCapturing {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?
    var failStart = false
    var startupError: Error?
    var failWithCallback = false
    var starts = 0
    var stops = 0
    var historicalCallbacks: [(TranscriptSegment) -> Void] = []
    func start(mode: CaptureMode, locale: String) async throws {
        starts += 1
        if let onSegment { historicalCallbacks.append(onSegment) }
        if failWithCallback { onFailure?(CaptureFailure("Audio source lost")) }
        if let startupError { throw startupError }
        if failStart { throw CaptureError.microphoneDenied }
    }
    func stop() async { stops += 1 }
}

private struct FakeSecrets: SecretStoring {
    func read(_ account: String) throws -> String { "fake-key" }
    func write(_ value: String, account: String) throws { }
}

private final class UntouchedSecrets: SecretStoring {
    func read(_ account: String) throws -> String { Issue.record("Local settings must not read credentials"); return "" }
    func write(_ value: String, account: String) throws { Issue.record("Local settings must not overwrite credentials") }
}

private actor SuspendedAssistant: AssistantServing {
    var continuation: CheckedContinuation<String, Error>?
    var started: Bool { continuation != nil }
    func answer(settings: AssistantSettings, apiKey: String, messages: [AssistantMessage], context: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(returning: "The original meeting summary"); continuation = nil }
}

private actor SuspendedOCR {
    var continuation: CheckedContinuation<String, Never>?
    var started: Bool { continuation != nil }
    func text() async -> String { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(returning: "Recognized later"); continuation = nil }
}

private struct ControlledScreenshot: ScreenshotServing {
    let ocr: SuspendedOCR
    var succeeds = true
    func capture(to url: URL) async throws -> Bool {
        if succeeds { try Data([1]).write(to: url) }
        return succeeds
    }
    func importImage(from source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func recognizeText(at url: URL) async throws -> String { await ocr.text() }
}

@MainActor
struct AppStateTests {
    private func makeRepository() -> FileLibraryRepository {
        FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CanopyTest-\(UUID().uuidString)"))
    }

    @Test func localSettingsPreserveRetiredAISetupWithoutTouchingKeychainOrValidatingOldEndpoints() throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        var saved = Library()
        saved.preferences.assistant.endpoint = "retired endpoint"
        saved.preferences.assistant.model = ""
        saved.preferences.jevEndpoint = "retired Jev endpoint"
        try repository.save(saved)
        let state = AppState(repository: repository, secrets: UntouchedSecrets(), meetingCapture: FakeCapture())
        var draft = Preferences()
        draft.revealOnHover = false
        draft.speechLocale = "fr-FR"
        state.saveLocalPreferences(draft)
        let reloaded = try repository.load().preferences
        #expect(reloaded.assistant == saved.preferences.assistant && reloaded.jevEndpoint == saved.preferences.jevEndpoint)
        #expect(!reloaded.revealOnHover && reloaded.speechLocale == "fr-FR")
        #expect(state.banner == "Settings saved.")
    }

    @Test func importedScreenshotAnnouncesBeforeOCRAndPreservesCurrentTab() async throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyImport-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: source) }
        try Data([1]).write(to: source)
        let ocr = SuspendedOCR()
        let state = AppState(repository: repository, screenshot: ControlledScreenshot(ocr: ocr), meetingCapture: FakeCapture())
        state.tab = .meetings
        var arrivals: [UUID] = []
        state.onCaptureAdded = { arrivals.append($0) }
        state.importImages([source])
        for _ in 0..<100 {
            if await ocr.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(await ocr.started)
        #expect(arrivals == state.library.captures.map(\.id))
        #expect(arrivals.count == 1 && state.tab == .meetings)
        #expect(try repository.load().captures.count == 1)
        #expect(state.library.captures.first?.extractedText == "")
        await ocr.finish()
        for _ in 0..<100 {
            if state.library.captures.first?.extractedText == "Recognized later" { break }
            await Task.yield()
        }
        #expect(state.library.captures.first?.extractedText == "Recognized later")
        #expect(arrivals.count == 1)
        await state.shutdown()
    }

    @Test func ownCaptureCanRevealImmediatelyAndCancellationHasNoArrival() async throws {
        for succeeds in [true, false] {
            let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
            let ocr = SuspendedOCR()
            let state = AppState(repository: repository, screenshot: ControlledScreenshot(ocr: ocr, succeeds: succeeds), meetingCapture: FakeCapture(), distribution: .appStore)
            var arrivals = 0, completed = false
            state.onCaptureAdded = { _ in arrivals += 1 }
            state.afterCapture = { completed = true }
            state.takeScreenshot()
            for _ in 0..<100 {
                if completed { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(completed && !state.captureBusy)
            #expect(arrivals == (succeeds ? 1 : 0))
            #expect(try repository.load().captures.count == (succeeds ? 1 : 0))
            #expect(!state.library.preferences.managesSystemScreenshots)
            if succeeds {
                for _ in 0..<100 { if await ocr.started { break }; await Task.yield() }
                #expect(await ocr.started)
                await ocr.finish()
            }
            await state.shutdown()
        }
    }

    @Test func previewCannotOverwriteRealDataOrStartLiveCapture() async throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        var original = Library(); original.meetings = [Meeting(title: "Real meeting", notes: "Keep this")]
        try repository.save(original)
        let capture = FakeCapture()
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: capture, demo: true)
        let previewDirectory = state.repository.directory
        #expect(previewDirectory != repository.directory)
        state.createNote(); state.saveNow(); state.ask("Don't send this")
        await state.startMeeting(title: "Don't record", mode: .both)
        #expect(capture.starts == 0 && !state.assistantBusy)
        #expect(try repository.load() == original)
        await state.shutdown()
        #expect(!FileManager.default.fileExists(atPath: previewDirectory.path))
    }

    @Test func deniedStartDoesNotLeaveAnActiveMeeting() async {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = FakeCapture(); capture.failStart = true
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: capture)
        await state.startMeeting(title: "Denied", mode: .microphone)
        #expect(!state.recording && !state.recordingTransition)
        #expect(state.activeMeetingID == nil && state.library.meetings.isEmpty)
        #expect(state.banner?.contains("microphone") == true)
    }

    @Test func screenCaptureDenialShowsRecoveryWithoutLeavingAMeeting() async {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = FakeCapture()
        capture.startupError = NSError(domain: SCStreamError.errorDomain,
                                      code: SCStreamError.Code.userDeclined.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "The user declined TCCs for application, window, display capture"])
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: capture, permissionService: FakeMeetingPermissions())
        await state.startMeeting(title: "Denied screen access", mode: .system)
        #expect(!state.recording && !state.recordingTransition)
        #expect(state.activeMeetingID == nil && state.library.meetings.isEmpty)
        #expect(state.banner?.contains("Screen & System Audio Recording") == true)
        #expect(state.banner?.contains("quit and reopen") == true)
        #expect(state.banner?.contains("TCCs") == false)
        await state.shutdown()
    }

    @Test func otherCaptureFailuresKeepTheirActualDiagnosis() {
        let errors = [
            NSError(domain: "AnotherSubsystem", code: SCStreamError.Code.userDeclined.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "Unrelated failure"]),
            NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStart.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: "The stream failed to start"])
        ]
        for error in errors { #expect(CaptureError.message(for: error) == error.localizedDescription) }
    }

    @Test func failureCallbackWhileStartingStopsTheCapture() async {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = FakeCapture(); capture.failWithCallback = true
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: capture)
        await state.startMeeting(title: "Interrupted", mode: .system)
        #expect(!state.recording && state.activeMeetingID == nil)
        #expect(capture.stops == 1)
        #expect(state.banner == "Audio source lost")
    }

    @Test func repeatedStartAndDelayedCallbackCannotCorruptNextMeeting() async throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = FakeCapture()
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: capture)
        await state.startMeeting(title: "First", mode: .microphone)
        let firstID = try #require(state.activeMeetingID)
        await state.startMeeting(title: "Duplicate", mode: .microphone)
        #expect(capture.starts == 1)
        await state.stopMeeting()
        await state.startMeeting(title: "Second", mode: .microphone)
        let secondID = try #require(state.activeMeetingID)
        capture.historicalCallbacks[0](TranscriptSegment(source: .microphone, text: "Late final for first", isFinal: true))
        #expect(state.library.meetings.first { $0.id == firstID }?.transcript.contains("Late final") == true)
        #expect(state.library.meetings.first { $0.id == secondID }?.segments.isEmpty == true)
        await state.stopMeeting()
        let restored = try repository.load()
        #expect(restored.meetings.allSatisfy { $0.endedAt != nil })
        await state.shutdown()
    }

    @Test func unreadableLibraryCannotBeOverwrittenByAppActions() throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        var library = Library(); library.schemaVersion = 99
        try repository.save(library)
        let original = try Data(contentsOf: repository.libraryURL)
        let state = AppState(repository: repository, secrets: FakeSecrets(), meetingCapture: FakeCapture())
        state.createNote(); state.saveNow()
        #expect(try Data(contentsOf: repository.libraryURL) == original)
        #expect(state.repository.directory != repository.directory)
        #expect(try state.repository.load().meetings.count == 1)
    }

    @Test func summaryResultStaysWithItsMeetingWhenSelectionChanges() async throws {
        let repository = makeRepository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let assistant = SuspendedAssistant()
        let state = AppState(repository: repository, secrets: FakeSecrets(), assistant: assistant, meetingCapture: FakeCapture(), distribution: .direct)
        state.createNote(); state.updateNotes("Original notes")
        let originalID = try #require(state.selectedMeetingID)
        let task = Task { await state.summarizeMeeting() }
        for _ in 0..<200 {
            if await assistant.started { break }
            await Task.yield()
        }
        #expect(await assistant.started)
        state.createNote()
        await assistant.finish(); await task.value
        #expect(state.library.meetings.first { $0.id == originalID }?.summary == "The original meeting summary")
        #expect(state.selectedMeeting?.summary.isEmpty == true)
        await state.shutdown()
    }
}
