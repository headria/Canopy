import AppKit
import CanopyCore
import Combine

enum ShelfTab: String, CaseIterable, Identifiable {
    case captures = "Shelf", meetings = "Meetings", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .captures: return "square.stack.3d.up"
        case .meetings: return "waveform"
        case .settings: return "slider.horizontal.3"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var library = Library()
    @Published var tab: ShelfTab = .captures
    @Published var selectedMeetingID: UUID?
    var noteEditorFlushers: [UUID: @MainActor () async -> Void] = [:]
    var noteEditorTransientTokens: Set<UUID> = []
    @Published var activeMeetingID: UUID?
    @Published var recording = false
    @Published var recordingTransition = false
    @Published var captureBusy = false
    @Published private(set) var captureError: String?
    @Published private(set) var captureNeedsSettings = false
    @Published var assistantBusy = false
    @Published var summaryBusy = false
    @Published var signalsBusy = false
    @Published var messages: [AssistantMessage] = []
    @Published var signals: MeetingSignals?
    @Published var signalsMeetingID: UUID?
    @Published var signalsDate: Date?
    @Published var banner: String?
    @Published private(set) var systemAudioNotice: String?
    @Published private(set) var speechPreparation: SpeechPreparation?
    @Published private(set) var meetingAudioLevel: Double?
    @Published private(set) var meetingCaptureMode: CaptureMode?
    @Published private(set) var meetingPermissions: [MeetingPermission: MeetingPermissionStatus] = [:]
    @Published private(set) var permissionBusy = false
    @Published private(set) var permissionIssue: MeetingPermission?
    @Published private(set) var meetingSetupIssue: MeetingSetupIssue?
    @Published private(set) var permissionRequiresRestart = false
    @Published var showingPermissionPrompt = false
    @Published var isPinnedOpen = false
    @Published var watchedFolder: String?
    @Published var watcherStarting = false
    @Published private(set) var managedScreenshots = false
    @Published var search = ""
    @Published var includeMeeting = false
    @Published var includeCaptures = false
    @Published private(set) var captureRevisions: [UUID: Int] = [:]
    private(set) var captureInteractionCount = 0
    var captureInteractionActive: Bool { captureInteractionCount > 0 }

    private(set) var repository: FileLibraryRepository
    private let secrets: SecretStoring
    private let assistant: AssistantServing
    private let jev: SignalServing
    private let screenshot: ScreenshotServing
    private let meetingCapture: MeetingCapturing
    private let permissionService: MeetingPermissionServing
    private let watcher: ScreenshotWatching
    private let externalWatcher: ScreenshotWatching
    private let editWatcher: ScreenshotWatching
    private let previewWatcher: ScreenshotWatching
    let editCopies: CaptureEditStore
    private let captureOpener: CaptureOpening
    private let systemScreenshots: SystemScreenshotManaging
    private let systemScreenshotDirectory: () -> URL
    private var watcherStartTask: Task<Void, Never>?
    private var watcherGeneration = UUID()
    private var saveTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var recognitionTasks: [UUID: Task<Void, Never>] = [:]
    private var recognitionTokens: [UUID: UUID] = [:]
    private var editWatcherTask: Task<Void, Never>?
    private var editWatcherGeneration = UUID()
    private var startupFailure: CaptureFailure?
    private var captureStartTask: Task<Void, Error>?
    private var screenshotTask: Task<Void, Never>?
    private var isShuttingDown = false
    let isDemo: Bool
    let distribution: AppDistribution
    @Published var pendingAIRequest: AIRequestConsent?
    private let folderAccess: ScreenshotFolderAccessing
    private let screenshotFolderPicker: @MainActor (URL?) -> URL?
    var beforeCapture: (() -> Void)?
    var afterCapture: (() -> Void)?
    var onCaptureAdded: ((UUID) -> Void)?
    var onCaptureRemoved: ((UUID) -> Void)?
    var onCaptureOpen: (() -> Void)?
    var onCaptureInteractionEnded: (() -> Void)?

    init(repository: FileLibraryRepository, secrets: SecretStoring = KeychainStore(), assistant: AssistantServing = HTTPAssistantClient(),
         jev: SignalServing = JevClient(), screenshot: ScreenshotServing = NativeScreenshotService(),
         meetingCapture: MeetingCapturing? = nil, permissionService: MeetingPermissionServing? = nil, watcher: ScreenshotWatching? = nil,
         editWatcher: ScreenshotWatching? = nil, captureOpener: CaptureOpening? = nil,
         systemScreenshots: SystemScreenshotManaging? = nil,
         systemScreenshotDirectory: @escaping () -> URL = { ScreenshotLocation.systemDirectory }, demo: Bool = false,
         distribution: AppDistribution = .current, folderAccess: ScreenshotFolderAccessing? = nil,
         screenshotFolderPicker: @escaping @MainActor (URL?) -> URL? = NativeScreenshotFolderPicker.select) {
        self.distribution = distribution
        self.folderAccess = folderAccess ?? ScreenshotFolderAccess()
        self.screenshotFolderPicker = screenshotFolderPicker
        self.repository = demo ? FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("CanopyPreview-\(UUID().uuidString)")) : repository
        self.secrets = secrets; self.assistant = assistant
        self.jev = jev; self.screenshot = screenshot; self.meetingCapture = meetingCapture ?? NativeMeetingCapture(); self.isDemo = demo
        self.permissionService = permissionService ?? NativeMeetingPermissions()
        self.watcher = watcher ?? ScreenshotWatcher(interval: 200_000_000)
        self.externalWatcher = ScreenshotWatcher()
        self.editWatcher = editWatcher ?? ScreenshotWatcher(acceptsAllImages: true)
        self.captureOpener = captureOpener ?? NativePreviewOpener()
        self.previewWatcher = ScreenshotWatcher(acceptsAllImages: true)
        self.systemScreenshots = systemScreenshots ?? SystemScreenshotManagerFactory.make(journalURL: repository.directory.appendingPathComponent("screenshot-settings.json"))
        self.systemScreenshotDirectory = systemScreenshotDirectory
        do { library = try self.repository.load() }
        catch {
            self.repository = FileLibraryRepository(directory: repository.directory.appendingPathComponent("Recovery-\(UUID().uuidString)"))
            banner = "Your existing library is preserved. New work will be saved in a separate recovery folder; open it with Reveal library in Settings. \(error.localizedDescription)"
        }
        self.editCopies = CaptureEditStore(libraryDirectory: self.repository.directory)
        selectedMeetingID = library.meetings.first?.id
        if !distribution.managesScreenshotSettings { library.preferences.managesSystemScreenshots = false }
        if distribution == .appStore {
            if library.preferences.screenshotSetupVersion < 1 {
                library.preferences.managesSystemScreenshots = false
                library.preferences.screenshotSetupVersion = 1
            }
            if !library.preferences.managesSystemScreenshots && library.preferences.screenshotFolderBookmark == nil {
                library.preferences.screenshotWatchingEnabled = false
            }
        }
        if demo { populateDemo() }
        self.meetingCapture.onPreparation = { [weak self] preparation in
            guard let self, !self.isShuttingDown, self.activeMeetingID != nil else { return }
            self.speechPreparation = preparation
        }
        self.meetingCapture.onNotice = { [weak self] message in
            guard let self, !self.isShuttingDown, self.activeMeetingID != nil else { return }
            self.systemAudioNotice = message
        }
        self.meetingCapture.onAudioLevel = { [weak self] level in
            guard let self, !self.isShuttingDown, self.activeMeetingID != nil else { return }
            self.meetingAudioLevel = level.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        }
        self.meetingCapture.onFailure = { [weak self] error in
            guard let self, !self.isShuttingDown else { return }
            self.banner = error.localizedDescription
            self.presentPermissionRecovery(for: error)
            if self.recordingTransition && !self.recording { self.startupFailure = error; return }
            Task { await self.stopMeeting() }
        }
    }

    var selectedMeeting: Meeting? { library.meetings.first { $0.id == selectedMeetingID } }
    var sortedCaptures: [Capture] {
        library.captures.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.extractedText.localizedCaseInsensitiveContains(search) }
            .sorted { $0.isPinned == $1.isPinned ? $0.createdAt > $1.createdAt : $0.isPinned }
    }
    var assistantContext: String {
        PromptBuilder.context(meeting: includeMeeting ? selectedMeeting : nil,
                              captures: includeCaptures ? library.captures.filter(\.isPinned) : [])
    }
    var contextDescription: String {
        var parts: [String] = []
        if includeMeeting, let selectedMeeting { parts.append(selectedMeeting.title) }
        if includeCaptures { parts.append("\(library.captures.filter { $0.isPinned && !$0.extractedText.isEmpty }.count) pinned text captures") }
        return parts.isEmpty ? (messages.isEmpty ? "Only your question is sent" : "Your question and this conversation are sent") : "Sending conversation + " + parts.joined(separator: " · ")
    }

    func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 750_000_000) } catch { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        guard !isDemo else { return }
        do { try repository.save(library) } catch { banner = "Could not save: \(error.localizedDescription)" }
    }
    func secretAccount(for settings: AssistantSettings) -> String { "assistant|\(settings.provider.rawValue)|\(settings.endpoint)" }
    func readKey(_ account: String) -> String {
        guard !isDemo else { return "" }
        do { return try secrets.read(account) } catch { banner = error.localizedDescription; return "" }
    }
    func savePreferences(_ preferences: Preferences, assistantKey: String, jevKey: String) throws {
        _ = try EndpointPolicy.validate(preferences.assistant.endpoint)
        _ = try EndpointPolicy.validate(preferences.jevEndpoint)
        guard !preferences.assistant.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ServiceError.missingModel }
        if !isDemo {
            try secrets.write(assistantKey.trimmingCharacters(in: .whitespacesAndNewlines), account: secretAccount(for: preferences.assistant))
            try secrets.write(jevKey.trimmingCharacters(in: .whitespacesAndNewlines), account: "jev|\(preferences.jevEndpoint)")
        }
        applyPreferences(preferences)
        banner = "Settings saved. Keys are stored in macOS Keychain."
    }

    /// Daily-flow settings do not read, validate or overwrite retired AI setup.
    func saveLocalPreferences(_ preferences: Preferences) {
        var preferences = preferences
        preferences.assistant = library.preferences.assistant
        preferences.jevEndpoint = library.preferences.jevEndpoint
        applyPreferences(preferences)
        banner = "Settings saved."
    }

    private func applyPreferences(_ preferences: Preferences) {
        var preferences = preferences
        preferences.workspaceFrame = library.preferences.workspaceFrame
        if distribution == .appStore {
            preferences.screenshotFolder = library.preferences.screenshotFolder
            preferences.screenshotFolderBookmark = library.preferences.screenshotFolderBookmark
            preferences.managesSystemScreenshots = library.preferences.managesSystemScreenshots
            preferences.screenshotSetupVersion = library.preferences.screenshotSetupVersion
            preferences.screenshotWatchingEnabled = library.preferences.screenshotWatchingEnabled
        }
        let watchingChanged = preferences.screenshotWatchingEnabled != library.preferences.screenshotWatchingEnabled || preferences.screenshotFolder != library.preferences.screenshotFolder || preferences.managesSystemScreenshots != library.preferences.managesSystemScreenshots
        library.preferences = preferences; saveNow()
        if watchingChanged { startScreenshotWatching() }
    }

    func rememberWorkspaceFrame(_ frame: CGRect) {
        var placement = WorkspacePlacement()
        placement.remember(frame)
        guard let valid = placement.rememberedFrame else { return }
        let saved = WorkspaceFrame(valid)
        guard library.preferences.workspaceFrame != saved else { return }
        library.preferences.workspaceFrame = saved
        saveNow()
    }

    func captureURL(_ capture: Capture) -> URL? { try? repository.captureURL(filename: capture.filename) }
    func beginCaptureInteraction() { captureInteractionCount += 1 }
    func endCaptureInteraction() {
        guard captureInteractionCount > 0 else { return }
        captureInteractionCount -= 1
        if !captureInteractionActive { onCaptureInteractionEnded?() }
    }
    func openCaptureInPreview(_ capture: Capture) {
        onCaptureOpen?()
        Task {
            do {
                let preview = try editCopies.url(filename: capture.filename)
                try await refreshPreviewEdits(at: preview)
                guard let index = library.captures.firstIndex(where: { $0.id == capture.id }), let source = captureURL(library.captures[index]) else { return }
                let needsCopy = library.captures[index].previewVersion == nil || !FileManager.default.fileExists(atPath: preview.path)
                var differs = false
                if !needsCopy { differs = try Data(contentsOf: source) != Data(contentsOf: preview) }
                if needsCopy || differs {
                    _ = try editCopies.stage(from: source, filename: capture.filename)
                    library.captures[index].previewVersion = try CaptureImageVersion.read(at: preview)
                    if !isDemo { try repository.save(library) }
                }
                try await captureOpener.openForEditing(preview)
            } catch { banner = "Could not open screenshot in Preview: \(error.localizedDescription)" }
        }
    }
    func takeScreenshot() {
        guard !captureBusy else { return }
        captureError = nil; captureNeedsSettings = false
        captureBusy = true; beforeCapture?()
        screenshotTask = Task {
            defer { captureBusy = false; screenshotTask = nil; afterCapture?() }
            do {
                try FileManager.default.createDirectory(at: repository.capturesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try await Task.sleep(nanoseconds: 250_000_000)
                let id = UUID(), filename = UUID().uuidString + ".png"
                let url = try repository.captureURL(filename: filename)
                var published = false
                defer { if !published { try? FileManager.default.removeItem(at: url) } }
                if try await screenshot.capture(to: url) {
                    try Task.checkCancellation()
                    try addCapture(id: id, filename: filename, title: "Capture · " + Date().formatted(date: .omitted, time: .shortened))
                    published = true
                }
            } catch is CancellationError { }
            catch {
                captureNeedsSettings = (error as? StoreScreenshotError) == .permissionDenied || CaptureError.permission(for: error) == .screenRecording
                captureError = error.localizedDescription
                banner = "Capture failed: \(error.localizedDescription)"
            }
        }
    }
    func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importImages(panel.urls) }
    }
    func importImages(_ urls: [URL]) {
        Task {
            for source in urls.prefix(20) {
                do {
                    try await importScreenshot(source)
                } catch { banner = "Could not import \(source.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }
    func importScreenshot(_ source: URL, consumingSource: Bool = false) async throws {
        // Avoid re-importing Canopy's own capture if its storage folder is selected.
        guard !library.captures.contains(where: { captureURL($0)?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() }) else { return }
        let incoming: IncomingScreenshot?
        if consumingSource {
            // Only consume files inside our own inbox, never external imports or symlink targets.
            guard source.deletingLastPathComponent().resolvingSymlinksInPath() == screenshotInbox.resolvingSymlinksInPath(),
                  try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            incoming = IncomingScreenshot(filename: source.lastPathComponent, size: values.fileSize ?? 0, modifiedAt: values.contentModificationDate ?? .distantPast)
            if let previous = library.captures.first(where: { $0.incomingSource == incoming }),
               let copy = captureURL(previous), FileManager.default.fileExists(atPath: copy.path) {
                try FileManager.default.removeItem(at: source)
                return
            }
        } else { incoming = nil }
        try FileManager.default.createDirectory(at: repository.capturesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let filename = UUID().uuidString + ".png"
        let destination = try repository.captureURL(filename: filename)
        try screenshot.importImage(from: source, to: destination)
        do { try addCapture(id: UUID(), filename: filename, title: source.deletingPathExtension().lastPathComponent, incomingSource: incoming) }
        catch { try? FileManager.default.removeItem(at: destination); throw error }
        if consumingSource {
            // Metadata and the app copy are durable before the inbox original is removed.
            // If removal fails, the persisted source identity makes a later retry safe.
            try FileManager.default.removeItem(at: source)
        }
    }
    private func addCapture(id: UUID, filename: String, title: String, incomingSource: IncomingScreenshot? = nil) throws {
        let version = try? CaptureImageVersion.read(at: repository.captureURL(filename: filename))
        library.captures.insert(Capture(id: id, title: title, filename: filename, incomingSource: incomingSource, imageVersion: version), at: 0)
        do { if !isDemo { try repository.save(library) } }
        catch { library.captures.removeAll { $0.id == id }; throw error }
        onCaptureAdded?(id)
        // Preview the saved image immediately; OCR must not delay the shelf or
        // block discovery of the next screenshot.
        recognizeCapture(id: id, filename: filename)
    }
    private func recognizeCapture(id: UUID, filename: String) {
        recognitionTasks[id]?.cancel()
        let token = UUID(); recognitionTokens[id] = token
        recognitionTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.recognitionTokens[id] == token { self.recognitionTasks[id] = nil; self.recognitionTokens[id] = nil }
            }
            do {
                let text = try await self.screenshot.recognizeText(at: self.repository.captureURL(filename: filename))
                try Task.checkCancellation()
                if let index = self.library.captures.firstIndex(where: { $0.id == id }) { self.library.captures[index].extractedText = text; self.saveSoon() }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, self.recognitionTokens[id] == token else { return }
                self.banner = "Image saved. Text recognition was unavailable: \(error.localizedDescription)"
            }
        }
    }
    func refreshEditedCapture(at url: URL) async throws {
        guard let index = library.captures.firstIndex(where: { captureURL($0)?.standardizedFileURL == url.standardizedFileURL }) else { return }
        let version = try CaptureImageVersion.read(at: url)
        guard library.captures[index].imageVersion != version else { return }
        let capture = library.captures[index]
        recognitionTasks[capture.id]?.cancel(); recognitionTokens[capture.id] = nil
        library.captures[index].imageVersion = version
        library.captures[index].extractedText = ""
        await CaptureThumbnailStore.shared.remove(at: url)
        guard library.captures.contains(where: { $0.id == capture.id }) else { return }
        captureRevisions[capture.id, default: 0] += 1
        saveNow()
        recognizeCapture(id: capture.id, filename: capture.filename)
    }
    func refreshPreviewEdits(at url: URL) async throws {
        guard url.deletingLastPathComponent().resolvingSymlinksInPath() == editCopies.directory.resolvingSymlinksInPath() else { return }
        guard let index = library.captures.firstIndex(where: { $0.filename == url.lastPathComponent }) else {
            // Preview may autosave again after the user discards its shelf image.
            try editCopies.remove(filename: url.lastPathComponent)
            return
        }
        guard url.standardizedFileURL == (try editCopies.url(filename: library.captures[index].filename)).standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let version = try CaptureImageVersion.read(at: url)
        guard library.captures[index].previewVersion != version, let destination = captureURL(library.captures[index]) else { return }
        try screenshot.importImage(from: url, to: destination)
        library.captures[index].previewVersion = version
        try await refreshEditedCapture(at: destination)
    }

    func startCaptureEditWatching() {
        editWatcherTask?.cancel(); editWatcher.stop(); previewWatcher.stop(); editWatcherGeneration = UUID()
        let token = editWatcherGeneration
        guard !isDemo else { return }
        editWatcherTask = Task { [weak self] in
            guard let self else { return }
            do {
                try FileManager.default.createDirectory(at: self.repository.capturesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Recover Preview saves before inspecting originals, including a crash
                // between publishing the edited PNG and saving its metadata.
                for capture in self.library.captures {
                    try Task.checkCancellation()
                    if let url = try? self.editCopies.url(filename: capture.filename) {
                        do { try await self.refreshPreviewEdits(at: url) }
                        catch { self.banner = "Could not recover one Preview edit: \(error.localizedDescription)" }
                    }
                }
                for capture in self.library.captures {
                    try Task.checkCancellation()
                    guard let url = self.captureURL(capture), let current = try? CaptureImageVersion.read(at: url) else { continue }
                    if capture.imageVersion == nil, current.modifiedAt <= capture.createdAt {
                        if let index = self.library.captures.firstIndex(where: { $0.id == capture.id }) { self.library.captures[index].imageVersion = current }
                    } else {
                        do { try await self.refreshEditedCapture(at: url) }
                        catch { self.banner = "Could not refresh one screenshot: \(error.localizedDescription)" }
                    }
                }
                self.saveNow()
                try Task.checkCancellation()
                guard self.editWatcherGeneration == token else { return }
                try await self.editWatcher.start(directory: self.repository.capturesDirectory, includeExisting: false, onCapture: { [weak self] url in
                    guard let self, self.editWatcherGeneration == token else { throw CancellationError() }
                    try await self.refreshEditedCapture(at: url)
                }, onError: { [weak self] issue in
                    guard let self, self.editWatcherGeneration == token else { return }
                    self.banner = "Could not refresh edited screenshots: \(issue.message)"
                })
                do {
                    try self.editCopies.prepareDirectory()
                    do { try self.editCopies.removeUntrackedFiles(keeping: Set(self.library.captures.map(\.filename))) }
                    catch { self.banner = "Could not remove an old edit copy: \(error.localizedDescription)" }
                    try await self.previewWatcher.start(directory: self.editCopies.directory, includeExisting: true, onCapture: { [weak self] url in
                        guard let self, self.editWatcherGeneration == token else { throw CancellationError() }
                        try await self.refreshPreviewEdits(at: url)
                    }, onError: { [weak self] issue in
                        guard let self, self.editWatcherGeneration == token else { return }
                        self.banner = "Could not save Preview edits: \(issue.message)"
                    })
                } catch is CancellationError { throw CancellationError() }
                catch { self.banner = "Could not watch Preview saves: \(error.localizedDescription)" }
                // Close the gap between the initial version check and the watcher's baseline scan.
                for capture in self.library.captures {
                    try Task.checkCancellation()
                    guard self.editWatcherGeneration == token else { return }
                    if let url = self.captureURL(capture) { try? await self.refreshEditedCapture(at: url) }
                    if let url = try? self.editCopies.url(filename: capture.filename) { try? await self.refreshPreviewEdits(at: url) }
                }
            } catch is CancellationError { }
            catch { self.banner = "Could not watch saved edits: \(error.localizedDescription)" }
        }
    }
    func togglePin(_ capture: Capture) {
        if let index = library.captures.firstIndex(where: { $0.id == capture.id }) { library.captures[index].isPinned.toggle(); saveSoon() }
    }
    func removeCapture(_ capture: Capture) {
        do {
            if let source = capture.incomingSource {
                guard source.filename == (source.filename as NSString).lastPathComponent, !source.filename.contains("..") else { throw LibraryError.invalidFilename }
                let original = screenshotInbox.appendingPathComponent(source.filename)
                if FileManager.default.fileExists(atPath: original.path) {
                    let values = try original.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
                    if values.isSymbolicLink != true, values.fileSize == source.size, values.contentModificationDate == source.modifiedAt {
                        try FileManager.default.removeItem(at: original)
                    }
                }
            }
            var updated = library
            updated.captures.removeAll { $0.id == capture.id }
            // Persist the dismissal first so an image cannot reappear after relaunch.
            if !isDemo { try repository.save(updated) }
            if let url = captureURL(capture) {
                do { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
                catch { if !isDemo { try? repository.save(library) }; throw error }
                Task { await CaptureThumbnailStore.shared.remove(at: url) }
            }
            recognitionTasks[capture.id]?.cancel(); recognitionTasks[capture.id] = nil; recognitionTokens[capture.id] = nil
            captureRevisions[capture.id] = nil; library = updated
            onCaptureRemoved?(capture.id)
            do { try editCopies.remove(filename: capture.filename) }
            catch { banner = "Screenshot discarded. Could not remove its edit copy: \(error.localizedDescription)" }
        } catch { banner = error.localizedDescription }
    }
    func copyCapture(_ capture: Capture) {
        guard let url = captureURL(capture), let image = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
        banner = "Image copied."
    }
    func saveCaptureCopy(_ capture: Capture) {
        guard let source = captureURL(capture) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = capture.title + ".png"
        if panel.runModal() == .OK, let destination = panel.url {
            do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
            catch { banner = "Could not save a copy: \(error.localizedDescription)" }
        }
    }
    func copyText(_ text: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        banner = "Text copied."
    }
    func watchFolder() {
        let initialDirectory = distribution == .direct || library.preferences.screenshotFolderBookmark != nil ? screenshotDirectory : nil
        if let directory = screenshotFolderPicker(initialDirectory) {
            do {
                if distribution == .appStore { library.preferences.screenshotFolderBookmark = try folderAccess.bookmark(for: directory) }
            } catch { banner = "Could not keep access to this folder. Choose it again. \(error.localizedDescription)"; return }
            library.preferences.screenshotFolder = directory.path
            library.preferences.managesSystemScreenshots = false
            library.preferences.screenshotWatchingEnabled = true
            saveNow(); startScreenshotWatching()
        }
    }
    var screenshotDirectory: URL {
        if library.preferences.managesSystemScreenshots { return screenshotInbox }
        if let folder = library.preferences.screenshotFolder { return URL(fileURLWithPath: folder, isDirectory: true) }
        return systemScreenshotDirectory()
    }
    var screenshotInbox: URL { repository.directory.appendingPathComponent("Screenshot Inbox", isDirectory: true) }
    var screenshotWatchLabel: String {
        if watcherStarting { return "Starting screenshot detection…" }
        if managedScreenshots { return "Screenshots go to \(ProductBrand.name)" }
        if let watchedFolder { return "Watching \(watchedFolder)" }
        return library.preferences.screenshotWatchingEnabled ? "Screenshot detection needs access" : "Screenshot detection paused"
    }
    func setScreenshotWatching(_ enabled: Bool) {
        if distribution == .appStore && enabled && !library.preferences.managesSystemScreenshots && library.preferences.screenshotFolderBookmark == nil {
            watchFolder()
            return
        }
        library.preferences.screenshotWatchingEnabled = enabled
        saveNow(); startScreenshotWatching()
    }
    func useSystemScreenshotFolder() {
        if distribution == .appStore { watchFolder(); return }
        library.preferences.managesSystemScreenshots = false
        library.preferences.screenshotFolder = nil
        library.preferences.screenshotWatchingEnabled = true
        saveNow(); startScreenshotWatching()
    }
    func setSystemScreenshotManagement(_ enabled: Bool) {
        guard distribution.managesScreenshotSettings else {
            banner = "Use \(ProductBrand.name)'s capture shortcut to keep screenshots only on your shelf."
            return
        }
        library.preferences.managesSystemScreenshots = enabled
        if enabled { library.preferences.screenshotWatchingEnabled = true }
        else if distribution == .appStore && library.preferences.screenshotFolderBookmark == nil { library.preferences.screenshotWatchingEnabled = false }
        saveNow(); startScreenshotWatching()
    }
    func startScreenshotWatching() {
        watcherStartTask?.cancel(); watcher.stop(); externalWatcher.stop()
        folderAccess.stop()
        watcherGeneration = UUID()
        watchedFolder = nil; watcherStarting = false
        guard !isDemo else { return }
        var restorationFailure: String?
        do { try systemScreenshots.end(); managedScreenshots = false }
        catch { restorationFailure = error.localizedDescription; banner = "Could not restore screenshot settings: \(error.localizedDescription)" }
        let token = watcherGeneration
        let enabled = library.preferences.screenshotWatchingEnabled
        let manage = enabled && distribution.managesScreenshotSettings && library.preferences.managesSystemScreenshots
        watcherStarting = enabled
        watcherStartTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.watcherGeneration == token { self.watcherStarting = false } }
            do {
                let inbox = self.screenshotInbox
                if FileManager.default.fileExists(atPath: inbox.path), try inbox.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
                // The owned inbox keeps recovering pending files even after handling
                // is paused or redirected. It never consumes external-folder files.
                try await self.watcher.start(directory: inbox, includeExisting: true, onCapture: { [weak self] url in
                    guard let self, self.watcherGeneration == token else { throw CancellationError() }
                    if ScreenshotClassification.imageExtensions.contains(url.pathExtension.lowercased()) {
                        try await self.importScreenshot(url, consumingSource: true)
                    } else if self.distribution == .direct { try await self.returnOtherCapture(url) }
                    // The Store lease leaves the movie destination unchanged. Never
                    // move an unrelated file to a folder without user-granted access.
                }, onError: { [weak self] issue in
                    guard let self, self.watcherGeneration == token else { return }
                    self.banner = issue.message
                    if issue.stopped {
                        self.watchedFolder = nil
                        do { try self.systemScreenshots.end(); self.managedScreenshots = false }
                        catch { self.banner = "\(issue.message) Could not restore screenshot settings: \(error.localizedDescription)" }
                    }
                })
                try Task.checkCancellation()
                guard self.watcherGeneration == token, restorationFailure == nil, enabled else { return }
                if manage {
                    try self.systemScreenshots.begin(in: inbox); self.managedScreenshots = true
                    self.watchedFolder = inbox.lastPathComponent
                } else if self.distribution == .appStore {
                    try await self.startStoreFolderWatching(token: token)
                } else {
                    let directory = self.screenshotDirectory
                    try await self.externalWatcher.start(directory: directory, includeExisting: false, onCapture: { [weak self] url in
                        guard let self, self.watcherGeneration == token else { throw CancellationError() }
                        try await self.importScreenshot(url)
                    }, onError: { [weak self] issue in
                        guard let self, self.watcherGeneration == token else { return }
                        self.banner = issue.message
                        if issue.stopped { self.watchedFolder = nil }
                    })
                    try Task.checkCancellation()
                    guard self.watcherGeneration == token else { return }
                    self.watchedFolder = directory.lastPathComponent
                }
            } catch is CancellationError { }
            catch {
                guard self.watcherGeneration == token else { return }
                self.externalWatcher.stop()
                self.folderAccess.stop(owner: token)
                do { try self.systemScreenshots.end(); self.managedScreenshots = false }
                catch { self.banner = "Could not restore screenshot settings: \(error.localizedDescription)"; return }
                if manage && self.distribution == .appStore {
                    self.library.preferences.managesSystemScreenshots = false
                    self.library.preferences.screenshotWatchingEnabled = self.library.preferences.screenshotFolderBookmark != nil
                    self.saveNow()
                }
                self.banner = "Could not start screenshot handling: \(error.localizedDescription)"
            }
        }
    }

    private func startStoreFolderWatching(token: UUID) async throws {
        guard let bookmark = library.preferences.screenshotFolderBookmark else {
            banner = "Use Capture region for private screenshots, or choose a screenshot folder to detect new macOS captures."
            return
        }
        do {
            try Task.checkCancellation()
            guard self.watcherGeneration == token, !self.isShuttingDown else { return }
            let lease = try self.folderAccess.start(bookmark: bookmark, owner: token)
            let directory = lease.directory
            self.library.preferences.screenshotFolder = directory.path
            if let refreshed = lease.refreshedBookmark { self.library.preferences.screenshotFolderBookmark = refreshed }
            self.saveNow()
            try await self.externalWatcher.start(directory: directory, includeExisting: false, onCapture: { [weak self] url in
                guard let self, self.watcherGeneration == token else { throw CancellationError() }
                try await self.importScreenshot(url)
            }, onError: { [weak self] issue in
                guard let self, self.watcherGeneration == token else { return }
                self.banner = issue.message
                if issue.stopped { self.watchedFolder = nil; self.folderAccess.stop(owner: token) }
            })
            try Task.checkCancellation()
            guard self.watcherGeneration == token else { return }
            self.watchedFolder = directory.lastPathComponent
        } catch is CancellationError { self.folderAccess.stop(owner: token) }
        catch { self.folderAccess.stop(owner: token); throw error }
    }

    /// macOS shares its save-folder setting with screen recordings. Put non-bitmap
    /// captures back in the user's ordinary folder instead of hiding them in our tray.
    func returnOtherCapture(_ source: URL) async throws {
        guard source.deletingLastPathComponent().resolvingSymlinksInPath() == screenshotInbox.resolvingSymlinksInPath(),
              try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        let current = systemScreenshotDirectory()
        var directory = current.resolvingSymlinksInPath() == screenshotInbox.resolvingSymlinksInPath() ? systemScreenshots.previousDirectory : current
        if directory == nil || directory?.resolvingSymlinksInPath() == screenshotInbox.resolvingSymlinksInPath() {
            directory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        }
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        // A screen recording may be several GB or saved on another volume. Copy
        // off the main thread, then publish a complete file with a same-folder move.
        try await Task.detached(priority: .utility) {
            let files = FileManager.default
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            var destination = directory.appendingPathComponent(source.lastPathComponent)
            if files.fileExists(atPath: destination.path) {
                destination = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (" + UUID().uuidString.prefix(8) + ")." + source.pathExtension)
            }
            let staging = directory.appendingPathComponent(".Canopy-transfer-" + UUID().uuidString)
            defer { try? files.removeItem(at: staging) }
            let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
            let before = try source.resourceValues(forKeys: keys)
            try files.copyItem(at: source, to: staging)
            let after = try source.resourceValues(forKeys: keys)
            guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else {
                throw CocoaError(.fileReadUnknown)
            }
            try files.moveItem(at: staging, to: destination)
            try files.removeItem(at: source)
        }.value
        banner = "\(source.pathExtension.lowercased() == "pdf" ? "PDF capture" : "Screen recording") saved to \(directory.lastPathComponent)."
    }

    func refreshMeetingPermissions() {
        guard !isDemo else { return }
        var permissions = MeetingPermission.availableCases
        if let issue = permissionIssue, !permissions.contains(issue) { permissions.append(issue) }
        for permission in permissions { meetingPermissions[permission] = permissionService.status(for: permission) }
        if let issue = permissionIssue, meetingPermissions[issue] != .allowed { permissionRequiresRestart = false }
        if let issue = permissionIssue, meetingPermissions[issue] == .allowed, !permissionRequiresRestart {
            permissionIssue = nil; showingPermissionPrompt = false
            banner = "\(issue.title) access is enabled. Choose Start listening when you're ready."
        }
    }

    func requestMeetingPermission(_ permission: MeetingPermission) async {
        guard !isDemo else { banner = "Preview mode. Permission requests are disabled."; return }
        guard !permissionBusy, !recording, !recordingTransition, !isShuttingDown else { return }
        permissionBusy = true
        showingPermissionPrompt = false
        defer { permissionBusy = false }
        if permission == .systemAudio {
            openMeetingPermissionSettings(permission)
            banner = "Enable \(ProductBrand.name) under System Audio Recording Only, then choose Start listening. Audio access is checked when capture starts."
            return
        }
        let existing = permissionService.status(for: permission)
        let canRequest = existing == .notGranted || (permission == .screenRecording && existing == .denied)
        let status = canRequest ? await permissionService.request(permission) : existing
        guard !isShuttingDown else { return }
        meetingPermissions[permission] = status
        if status == .allowed {
            if permissionRequiresRestart && permissionIssue == permission {
                banner = "Access is enabled, but macOS rejected this session. Quit and reopen \(ProductBrand.name), then choose Start listening."
                return
            }
            if permissionIssue == permission { permissionIssue = nil; permissionRequiresRestart = false }
            banner = "\(permission.title) access is enabled. Choose Start listening when you're ready."
        } else {
            permissionIssue = permission
            permissionRequiresRestart = false
            if status == .restricted {
                banner = "\(permission.title) access is restricted by macOS. Check Screen Time or your Mac's administrator settings."
            } else if existing == .notGranted {
                banner = "Access wasn't granted. You can use the other features, or review this permission in System Settings."
            } else if permissionService.openSettings(for: permission) {
                banner = "You can review this permission in System Settings. Recording stays off until you choose Start listening."
            } else {
                banner = "Open System Settings → Privacy & Security → \(permission.title) and enable access for this app."
            }
        }
    }

    func openMeetingPermissionSettings(_ permission: MeetingPermission) {
        guard !isDemo else { banner = "Preview mode. Permission settings are disabled."; return }
        if !permissionService.openSettings(for: permission) {
            banner = "Open System Settings → Privacy & Security → \(permission.title)."
        }
    }

    func openMeetingSetupSettings(_ issue: MeetingSetupIssue) {
        guard !isDemo else { banner = "Preview mode. System settings are disabled."; return }
        if NSWorkspace.shared.open(issue.settingsURL) { banner = issue.detail }
        else { banner = "Open System Settings → Keyboard → Dictation, turn it on, then choose Start listening again." }
    }

    func previewMeetingPermissionRecovery(showPrompt: Bool = false) {
        guard isDemo else { return }
        permissionIssue = .systemAudio
        permissionRequiresRestart = false
        meetingPermissions[.systemAudio] = .onStart
        showingPermissionPrompt = showPrompt
    }

    func startMeeting(title: String, mode: CaptureMode) async {
        guard !isDemo else { banner = "Preview mode. Open \(ProductBrand.name) normally to listen to a meeting."; return }
        guard !recording, !recordingTransition, !permissionBusy, !isShuttingDown else { return }
        recordingTransition = true
        startupFailure = nil; systemAudioNotice = nil; speechPreparation = nil; meetingAudioLevel = nil; meetingCaptureMode = mode
        defer { recordingTransition = false; captureStartTask = nil }
        let meeting = Meeting(title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled meeting" : title)
        // Identity is captured so a delayed audio callback cannot update the next meeting.
        meetingCapture.onSegment = { [weak self] segment in
            guard let self, let index = self.library.meetings.firstIndex(where: { $0.id == meeting.id }) else { return }
            self.library.meetings[index].upsert(segment); self.saveSoon()
            if self.meetingSetupIssue != nil, !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.meetingSetupIssue = nil; self.showingPermissionPrompt = false
            }
        }
        library.meetings.insert(meeting, at: 0); selectedMeetingID = meeting.id; activeMeetingID = meeting.id
        do {
            let capture = meetingCapture, locale = library.preferences.speechLocale
            let task = Task { try await capture.start(mode: mode, locale: locale) }
            captureStartTask = task
            try await task.value
            if isShuttingDown || task.isCancelled { await meetingCapture.stop(); throw CancellationError() }
            if let startupFailure {
                await meetingCapture.stop()
                throw startupFailure
            }
            recording = true; speechPreparation = nil; saveNow()
            permissionIssue = nil; showingPermissionPrompt = false
            permissionRequiresRestart = false
        } catch {
            library.meetings.removeAll { $0.id == meeting.id }; activeMeetingID = nil; systemAudioNotice = nil; speechPreparation = nil
            meetingAudioLevel = nil; meetingCaptureMode = nil
            selectedMeetingID = library.meetings.first?.id
            if !isShuttingDown {
                if error is CancellationError { banner = "Meeting preparation cancelled." }
                else {
                    banner = CaptureError.message(for: error)
                    presentPermissionRecovery(for: error)
                }
            }
        }
    }

    func cancelMeetingPreparation() async {
        guard recordingTransition, !recording, let task = captureStartTask else { return }
        task.cancel()
        await meetingCapture.stop()
        speechPreparation = nil
    }

    private func presentPermissionRecovery(for error: Error) {
        if let setup = CaptureError.setupIssue(for: error) {
            meetingSetupIssue = setup
            permissionIssue = nil; permissionRequiresRestart = false
            showingPermissionPrompt = true
            return
        }
        meetingSetupIssue = nil
        guard let permission = CaptureError.permission(for: error) else { return }
        permissionService.recordDenial(permission)
        permissionIssue = permission
        let status = permissionService.status(for: permission)
        meetingPermissions[permission] = status
        permissionRequiresRestart = (permission == .screenRecording || permission == .speechRecognition) && status == .allowed
        if permissionRequiresRestart {
            banner = "\(permission.title) access is enabled, but macOS rejected this session. Quit and reopen \(ProductBrand.name), then choose Start listening."
        }
        showingPermissionPrompt = true
    }
    func stopMeeting() async {
        guard activeMeetingID != nil, !recordingTransition else { return }
        recordingTransition = true
        let id = activeMeetingID
        await meetingCapture.stop()
        if let index = library.meetings.firstIndex(where: { $0.id == id }) { library.meetings[index].endedAt = Date() }
        activeMeetingID = nil; recording = false; recordingTransition = false; systemAudioNotice = nil; speechPreparation = nil
        meetingAudioLevel = nil; meetingCaptureMode = nil; saveNow()
    }
    func createNote() {
        let meeting = Meeting(title: "Quick note", endedAt: Date())
        library.meetings.insert(meeting, at: 0); selectedMeetingID = meeting.id; tab = .meetings; saveNow()
    }
    func updateNotes(_ value: String) {
        guard let id = selectedMeetingID else { return }
        updateNotes(value, meetingID: id)
    }
    func renameMeeting(_ value: String) {
        guard let id = selectedMeetingID else { return }
        renameMeeting(value, meetingID: id)
    }
    func deleteMeeting(_ meeting: Meeting) {
        guard meeting.id != activeMeetingID else { return }
        library.meetings.removeAll { $0.id == meeting.id }
        if selectedMeetingID == meeting.id { selectedMeetingID = library.meetings.first?.id }
        saveNow()
    }
    func exportMeeting() {
        guard let selectedMeeting else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "Meeting notes.md"
        if panel.runModal() == .OK, let url = panel.url {
            do { try selectedMeeting.markdown.write(to: url, atomically: true, encoding: .utf8) }
            catch { banner = error.localizedDescription }
        }
    }

    func ask(_ question: String) {
        guard !isDemo else { banner = "Preview mode. Open \(ProductBrand.name) normally to configure your API and ask a question."; return }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !assistantBusy else { return }
        let settings = library.preferences.assistant, context = assistantContext
        let history = messages + [AssistantMessage(role: "user", text: question)]
        if distribution.requiresAIConsent {
            presentAIConsent(.answer(settings: settings, history: history, context: context))
            return
        }
        startAnswer(settings: settings, history: history, context: context)
    }
    private func startAnswer(settings: AssistantSettings, history: [AssistantMessage], context: String) {
        guard !isShuttingDown else { return }
        guard !assistantBusy else { banner = "Wait for the current answer, then try again."; return }
        messages = history
        assistantBusy = true
        answerTask = Task {
            defer { assistantBusy = false; answerTask = nil }
            do {
                let key = try secrets.read(secretAccount(for: settings))
                let result = try await assistant.answer(settings: settings, apiKey: key, messages: history, context: context)
                try Task.checkCancellation()
                messages.append(AssistantMessage(role: "assistant", text: result))
            } catch is CancellationError { }
            catch { if !Task.isCancelled { banner = error.localizedDescription } }
        }
    }
    func cancelAnswer() { answerTask?.cancel() }
    func summarizeMeeting() async {
        guard !isDemo else { banner = "Preview mode. Open \(ProductBrand.name) normally to summarize with your API."; return }
        guard let meeting = selectedMeeting, !summaryBusy, !meeting.transcript.isEmpty || !meeting.notes.isEmpty else { return }
        let settings = library.preferences.assistant
        let context = PromptBuilder.context(meeting: meeting, captures: [])
        if distribution.requiresAIConsent {
            presentAIConsent(.summary(settings: settings, meetingID: meeting.id, context: context))
            return
        }
        await generateSummary(settings: settings, meetingID: meeting.id, context: context)
    }
    private func generateSummary(settings: AssistantSettings, meetingID: UUID, context: String) async {
        guard !isShuttingDown else { return }
        guard !summaryBusy else { banner = "Wait for the current summary, then try again."; return }
        summaryBusy = true; defer { summaryBusy = false }
        do {
            let key = try secrets.read(secretAccount(for: settings))
            let result = try await assistant.answer(settings: settings, apiKey: key,
                messages: [AssistantMessage(role: "user", text: PromptBuilder.summary)], context: context)
            if let index = library.meetings.firstIndex(where: { $0.id == meetingID }) { library.meetings[index].summary = result; saveNow() }
        } catch { banner = error.localizedDescription }
    }
    func evaluateSignals() async {
        guard !isDemo else { banner = "Preview mode. Open \(ProductBrand.name) normally to connect your TypeSafe key."; return }
        guard let meeting = selectedMeeting, !signalsBusy, !meeting.transcript.isEmpty || !meeting.notes.isEmpty else { return }
        let endpoint = library.preferences.jevEndpoint
        let text = String((meeting.transcript.isEmpty ? meeting.notes : meeting.transcript).suffix(12_000))
        if distribution.requiresAIConsent {
            presentAIConsent(.signals(endpoint: endpoint, meetingID: meeting.id, text: text))
            return
        }
        await generateSignals(endpoint: endpoint, meetingID: meeting.id, text: text)
    }
    private func generateSignals(endpoint: String, meetingID: UUID, text: String) async {
        guard !isShuttingDown else { return }
        guard !signalsBusy else { banner = "Wait for the current analysis, then try again."; return }
        signalsBusy = true; defer { signalsBusy = false }
        do {
            let key = try secrets.read("jev|\(endpoint)")
            signals = try await jev.evaluate(endpoint: endpoint, apiKey: key, state: text)
            signalsMeetingID = meetingID; signalsDate = Date()
        } catch { banner = error.localizedDescription }
    }

    private func presentAIConsent(_ action: AIRequestConsent.Action) {
        guard !isShuttingDown else { return }
        guard pendingAIRequest == nil else { banner = "Finish or cancel the current request review first."; return }
        let request = AIRequestConsent(action: action)
        do { _ = try EndpointPolicy.validate(request.endpoint); pendingAIRequest = request }
        catch { banner = error.localizedDescription }
    }
    func sendApprovedAIRequest(requestID: UUID) async {
        guard let request = pendingAIRequest, request.id == requestID, !isDemo, !isShuttingDown else { return }
        pendingAIRequest = nil
        switch request.action {
        case .answer(let settings, let history, let context): startAnswer(settings: settings, history: history, context: context)
        case .summary(let settings, let meetingID, let context): await generateSummary(settings: settings, meetingID: meetingID, context: context)
        case .signals(let endpoint, let meetingID, let text): await generateSignals(endpoint: endpoint, meetingID: meetingID, text: text)
        }
    }

    func shutdown() async {
        await flushNoteEditors()
        isShuttingDown = true
        screenshotTask?.cancel()
        if distribution == .appStore { await screenshotTask?.value }
        pendingAIRequest = nil
        watcherGeneration = UUID(); watcherStartTask?.cancel(); watcher.stop(); externalWatcher.stop(); answerTask?.cancel(); saveTask?.cancel()
        editWatcherGeneration = UUID(); editWatcherTask?.cancel(); editWatcher.stop(); previewWatcher.stop()
        folderAccess.stop()
        recognitionTasks.values.forEach { $0.cancel() }; recognitionTasks.removeAll(); recognitionTokens.removeAll()
        if !isDemo {
            do { try systemScreenshots.end(); managedScreenshots = false }
            catch { banner = "Could not restore screenshot settings: \(error.localizedDescription)" }
        }
        if activeMeetingID != nil { await meetingCapture.stop() }
        if let index = library.meetings.firstIndex(where: { $0.id == activeMeetingID }) {
            if recording { library.meetings[index].endedAt = Date() }
            else { library.meetings.remove(at: index) }
        }
        activeMeetingID = nil; recording = false; systemAudioNotice = nil; speechPreparation = nil
        saveNow()
        if isDemo { try? FileManager.default.removeItem(at: repository.directory) }
    }

    private func populateDemo() {
        var meeting = Meeting(title: "Product sync · Friday", startedAt: Date().addingTimeInterval(-1200), endedAt: Date().addingTimeInterval(-600))
        meeting.segments = [
            TranscriptSegment(source: .system, text: "Let's keep the first release focused: capture, meeting notes, and clear next steps.", isFinal: true),
            TranscriptSegment(source: .microphone, text: "I'll have the prototype ready for review on Monday. Local transcription is the priority.", isFinal: true),
            TranscriptSegment(source: .system, text: "Agreed. Can we make the top-edge interaction feel quiet and effortless?", isFinal: true)
        ]
        meeting.notes = "A quieter workspace. Everything useful, just within reach.\n\nKeep the first release focused. Leave room for thoughtful details."
        meeting.richNotes = try? RichMeetingNotes(json: """
        {"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"A quieter workspace. Everything useful, just within reach."}]},{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Next steps"}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"checked":false},"content":[{"type":"paragraph","content":[{"type":"text","text":"Share the prototype for review"}]}]},{"type":"taskItem","attrs":{"checked":false},"content":[{"type":"paragraph","content":[{"type":"text","text":"Record a quick walkthrough"}]}]},{"type":"taskItem","attrs":{"checked":true},"content":[{"type":"paragraph","content":[{"type":"text","text":"Review the blue and slate palette"}]}]}]},{"type":"paragraph","content":[{"type":"text","text":"Keep the first release focused. ","marks":[{"type":"bold"}]},{"type":"text","text":"Leave room for thoughtful details."}]}]}
        """, markdown: "A quieter workspace. Everything useful, just within reach.\n\n## Next steps\n\n- [ ] Share the prototype for review\n- [ ] Record a quick walkthrough\n- [x] Review the blue and slate palette\n\n**Keep the first release focused.** Leave room for thoughtful details.")
        meeting.summary = "A focused first release with a screenshot shelf and local meeting notes. Prototype review is planned for Monday."
        library.meetings = [meeting]; selectedMeetingID = meeting.id
        try? FileManager.default.createDirectory(at: repository.capturesDirectory, withIntermediateDirectories: true)
        for index in 0..<3 {
            let filename = "demo-\(index).png"
            let image = DemoArtwork.image(index: index)
            if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let data = rep.representation(using: .png, properties: [:]),
               let url = try? repository.captureURL(filename: filename) { try? data.write(to: url) }
            library.captures.append(Capture(title: ["A little inspiration", "Monday's plan", "The next idea"][index], filename: filename, isPinned: index == 0,
                extractedText: ["A quieter workspace.", "Prototype review on Monday", "Capture. Remember. Do."][index]))
        }
    }
}
