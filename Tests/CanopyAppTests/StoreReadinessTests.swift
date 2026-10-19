import CanopyCore
import Foundation
import Testing
@testable import CanopyApp

@MainActor
private final class StoreTestCapture: MeetingCapturing {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?
    func start(mode: CaptureMode, locale: String) async throws { }
    func stop() async { }
}
@MainActor
private final class StoreTestSettings: SystemScreenshotManaging {
    var begins = 0, ends = 0
    var beforeBegin: (() -> Void)?
    var denied = false
    func begin(in directory: URL) throws {
        beforeBegin?(); begins += 1
        if denied { throw CocoaError(.fileWriteNoPermission) }
    }
    func end() throws { ends += 1 }
}
@MainActor
private final class StoreTestEditWatcher: ScreenshotWatching {
    var started = false
    var includeExisting = false
    var capture: ((URL) async throws -> Void)?
    func start(directory: URL, includeExisting: Bool, onCapture: @escaping (URL) async throws -> Void,
               onError: @escaping (ScreenshotWatchIssue) -> Void) async throws {
        started = true; self.includeExisting = includeExisting; capture = onCapture
    }
    func stop() { started = false; capture = nil }
}
private struct StoreTestSecrets: SecretStoring {
    func read(_ account: String) throws -> String { "test-only-key" }
    func write(_ value: String, account: String) throws { }
}
@MainActor
private final class StoreTestFolderAccess: ScreenshotFolderAccessing {
    let directory: URL
    var starts = 0
    var owner: UUID?
    init(directory: URL) { self.directory = directory }
    func bookmark(for directory: URL) throws -> Data { Data("renewed".utf8) }
    func start(bookmark: Data, owner: UUID) throws -> ScreenshotFolderLease {
        starts += 1; self.owner = owner
        return ScreenshotFolderLease(directory: directory, refreshedBookmark: Data("renewed".utf8))
    }
    func stop(owner: UUID?) { if owner == nil || owner == self.owner { self.owner = nil } }
}
private actor StoreTestAssistant: AssistantServing {
    private(set) var calls = 0
    private(set) var receivedSettings: AssistantSettings?
    private(set) var receivedContext: String?
    func answer(settings: AssistantSettings, apiKey: String, messages: [AssistantMessage], context: String) async throws -> String {
        calls += 1; receivedSettings = settings; receivedContext = context
        return "Approved answer"
    }
}

@MainActor
struct StoreReadinessTests {
    private func repository() -> FileLibraryRepository {
        FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CanopyStoreTest-\(UUID())"))
    }
    @Test func storeDoesNotChangeGlobalScreenshotPreferencesOrReadAnUnselectedFolder() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let settings = StoreTestSettings()
        let state = AppState(repository: repository, meetingCapture: StoreTestCapture(), systemScreenshots: settings,
            systemScreenshotDirectory: { Issue.record("Store accessed the system screenshot setting"); return URL(fileURLWithPath: "/never") },
            distribution: .appStore)
        #expect(!state.library.preferences.managesSystemScreenshots)
        #expect(!state.library.preferences.screenshotWatchingEnabled)
        state.startScreenshotWatching()
        #expect(state.watchedFolder == nil && !state.watcherStarting)
        #expect(state.banner == nil)
        await state.shutdown()
        #expect(settings.begins == 0 && settings.ends == 2)
    }
    @Test func storeUpgradeRetiresRoutingWithoutLosingCapturesOrNotes() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        var previous = Library()
        previous.preferences.managesSystemScreenshots = true
        previous.preferences.screenshotWatchingEnabled = true
        previous.preferences.screenshotSetupVersion = 1
        previous.captures = [Capture(title: "Existing screenshot", filename: "existing.png")]
        previous.meetings = [Meeting(title: "Existing note", notes: "Keep my notes")]
        try repository.save(previous)
        let settings = StoreTestSettings(), watcher = StoreTestEditWatcher()
        let state = AppState(repository: repository, meetingCapture: StoreTestCapture(), watcher: watcher, systemScreenshots: settings,
            systemScreenshotDirectory: { Issue.record("Read an unselected folder"); return URL(fileURLWithPath: "/never") }, distribution: .appStore)
        #expect(!AppDistribution.appStore.managesScreenshotSettings)
        #expect(!state.library.preferences.managesSystemScreenshots && !state.library.preferences.screenshotWatchingEnabled)
        state.startScreenshotWatching()
        for _ in 0..<100 { if watcher.started { break }; await Task.yield() }
        #expect(watcher.started && watcher.includeExisting)
        state.setSystemScreenshotManagement(true)
        #expect(settings.begins == 0 && state.watchedFolder == nil)
        #expect(!state.managedScreenshots && !state.library.preferences.screenshotWatchingEnabled)
        state.saveLocalPreferences(state.library.preferences)
        let saved = try repository.load()
        #expect(!saved.preferences.managesSystemScreenshots)
        #expect(saved.captures == previous.captures && saved.meetings == previous.meetings)
        await state.shutdown()
    }
    @Test func storeCannotAcquireRoutingEvenIfAnOldFlagIsSetAfterLaunch() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let settings = StoreTestSettings()
        let state = AppState(repository: repository, watcher: StoreTestEditWatcher(), systemScreenshots: settings, distribution: .appStore)
        state.library.preferences.managesSystemScreenshots = true
        state.library.preferences.screenshotWatchingEnabled = true
        state.startScreenshotWatching()
        for _ in 0..<100 { if !state.watcherStarting { break }; await Task.yield() }
        #expect(settings.begins == 0 && !state.managedScreenshots && state.watchedFolder == nil)
        await state.shutdown()
    }
    @Test func storeWatchingRequestsAFolderAndCancelLeavesDetectionOff() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let chosen = repository.directory.appendingPathComponent("Chosen Folder")
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        var response: URL?
        var pickerCalls = 0
        let access = StoreTestFolderAccess(directory: chosen)
        let state = AppState(repository: repository, meetingCapture: StoreTestCapture(), systemScreenshots: StoreTestSettings(),
            systemScreenshotDirectory: { Issue.record("Read unselected system folder"); return chosen },
            distribution: .appStore, folderAccess: access, screenshotFolderPicker: { initial in
                #expect(initial == nil)
                pickerCalls += 1
                return response
            })
        state.setScreenshotWatching(true)
        #expect(pickerCalls == 1 && !state.library.preferences.screenshotWatchingEnabled)
        #expect(access.starts == 0 && state.library.preferences.screenshotFolderBookmark == nil)
        response = chosen
        state.setScreenshotWatching(true)
        #expect(pickerCalls == 2 && state.library.preferences.screenshotWatchingEnabled)
        #expect(state.library.preferences.screenshotFolder == chosen.path)
        #expect(state.library.preferences.screenshotFolderBookmark == Data("renewed".utf8))
        await state.shutdown()
    }
    @Test func libraryRecoveryPreservesPreviewCopiesFromTheUnreadableLibrary() async throws {
        let original = repository()
        let oldEdits = CaptureEditStore(libraryDirectory: original.directory)
        defer {
            try? FileManager.default.removeItem(at: original.directory)
            try? FileManager.default.removeItem(at: oldEdits.directory)
        }
        try original.save(Library())
        let unreadable = Data("unreadable library".utf8)
        try unreadable.write(to: original.libraryURL)
        try oldEdits.prepareDirectory()
        let editedFile = try oldEdits.url(filename: "preserved.png")
        let editedBytes = Data("preserved Preview working copy".utf8)
        try editedBytes.write(to: editedFile)
        let state = AppState(repository: original, meetingCapture: StoreTestCapture(), editWatcher: StoreTestEditWatcher(),
            systemScreenshots: StoreTestSettings(), distribution: .appStore)
        defer { try? FileManager.default.removeItem(at: state.editCopies.directory) }
        #expect(state.repository.directory != original.directory)
        #expect(state.editCopies.directory != oldEdits.directory)
        state.startCaptureEditWatching()
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: state.editCopies.directory.path) { break }
            await Task.yield()
        }
        #expect(FileManager.default.fileExists(atPath: state.editCopies.directory.path))
        #expect(try Data(contentsOf: editedFile) == editedBytes)
        #expect(try Data(contentsOf: original.libraryURL) == unreadable)
        await state.shutdown()
    }
    @Test func aiCancellationSendsNothingAndApprovalUsesTheReviewedSnapshot() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let assistant = StoreTestAssistant()
        let state = AppState(repository: repository, secrets: StoreTestSecrets(), assistant: assistant,
            meetingCapture: StoreTestCapture(), systemScreenshots: StoreTestSettings(), distribution: .appStore)
        state.createNote(); state.updateNotes("Reviewed private notes")
        state.includeMeeting = true
        let settings = state.library.preferences.assistant
        state.ask("A reviewed question")
        let request = try #require(state.pendingAIRequest)
        #expect(request.recipient == "api.anthropic.com" && request.content.contains("Reviewed private notes"))
        #expect(await assistant.calls == 0 && state.messages.isEmpty)
        state.pendingAIRequest = nil
        await state.sendApprovedAIRequest(requestID: request.id)
        #expect(await assistant.calls == 0)
        state.ask("Another reviewed question")
        let approved = try #require(state.pendingAIRequest)
        state.updateNotes("Changed after consent opened")
        state.library.preferences.assistant.endpoint = "https://different.example/v1/messages"
        await state.sendApprovedAIRequest(requestID: approved.id)
        for _ in 0..<100 { if await assistant.calls > 0 { break }; await Task.yield() }
        #expect(await assistant.calls == 1)
        #expect(await assistant.receivedSettings == settings)
        #expect(await assistant.receivedContext?.contains("Reviewed private notes") == true)
        #expect(await assistant.receivedContext?.contains("Changed after consent opened") == false)
        await state.shutdown()
    }
    @Test func summaryWaitsForApprovalAndKeepsItsOriginalMeeting() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let assistant = StoreTestAssistant()
        let state = AppState(repository: repository, secrets: StoreTestSecrets(), assistant: assistant,
            meetingCapture: StoreTestCapture(), systemScreenshots: StoreTestSettings(), distribution: .appStore)
        state.createNote(); state.updateNotes("Original meeting")
        let original = try #require(state.selectedMeetingID)
        await state.summarizeMeeting()
        let approved = try #require(state.pendingAIRequest)
        #expect(await assistant.calls == 0 && state.pendingAIRequest != nil)
        state.createNote()
        await state.sendApprovedAIRequest(requestID: approved.id)
        #expect(state.library.meetings.first(where: { $0.id == original })?.summary == "Approved answer")
        #expect(state.selectedMeeting?.summary == "")
        await state.shutdown()
    }
    @Test func cancelledFolderStartupCannotAcquireAccessAndStaleSettingsCannotEraseTheRenewedBookmark() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let folder = repository.directory.appendingPathComponent("Chosen Screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let access = StoreTestFolderAccess(directory: folder)
        let state = AppState(repository: repository, secrets: StoreTestSecrets(), meetingCapture: StoreTestCapture(),
            systemScreenshots: StoreTestSettings(), distribution: .appStore, folderAccess: access)
        state.library.preferences.screenshotFolderBookmark = Data("old bookmark".utf8)
        let oldDraft = state.library.preferences
        state.startScreenshotWatching()
        state.setScreenshotWatching(false)
        for _ in 0..<20 { await Task.yield() }
        #expect(access.starts == 0 && access.owner == nil)
        state.setScreenshotWatching(true)
        for _ in 0..<100 { if access.starts > 0 { break }; await Task.yield() }
        #expect(access.starts == 1 && access.owner != nil)
        #expect(state.library.preferences.screenshotFolderBookmark == Data("renewed".utf8))
        try state.savePreferences(oldDraft, assistantKey: "", jevKey: "")
        #expect(state.library.preferences.screenshotFolder == folder.path)
        #expect(state.library.preferences.screenshotFolderBookmark == Data("renewed".utf8))
        await state.shutdown()
        #expect(access.owner == nil)
    }
    @Test func approvalForAnOlderSheetCannotSendANewerPendingRequest() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let assistant = StoreTestAssistant()
        let state = AppState(repository: repository, secrets: StoreTestSecrets(), assistant: assistant,
            meetingCapture: StoreTestCapture(), systemScreenshots: StoreTestSettings(), distribution: .appStore)
        state.ask("First request")
        let original = try #require(state.pendingAIRequest)
        state.pendingAIRequest = nil
        state.ask("New request")
        let replacement = try #require(state.pendingAIRequest)
        await state.sendApprovedAIRequest(requestID: original.id)
        #expect(await assistant.calls == 0)
        #expect(state.pendingAIRequest?.id == replacement.id)
        await state.shutdown()
    }
    @Test func selectionGeometryWorksForDisplaysAboveAndLeftOfThePrimaryDisplay() {
        let rectangle = RegionCaptureGeometry.screenRect(from: CGRect(x: -400, y: 1200, width: 300, height: 200), primaryScreenTop: 1080)
        #expect(rectangle == CGRect(x: -400, y: -320, width: 300, height: 200))
    }
}
