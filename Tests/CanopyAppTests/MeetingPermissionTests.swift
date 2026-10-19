import Foundation
import ScreenCaptureKit
import Testing
import CanopyCore
@testable import CanopyApp

@MainActor
final class FakeMeetingPermissions: MeetingPermissionServing {
    var statuses: [MeetingPermission: MeetingPermissionStatus] = [:]
    var result: MeetingPermissionStatus = .denied
    var reads = 0
    var requests: [MeetingPermission] = []
    var settings: [MeetingPermission] = []
    var opensSettings = true
    var suspend = false
    var preservesAllowedOnDenial = false
    var continuation: CheckedContinuation<Void, Never>?
    func status(for permission: MeetingPermission) -> MeetingPermissionStatus {
        reads += 1; return statuses[permission] ?? .notGranted
    }
    func request(_ permission: MeetingPermission) async -> MeetingPermissionStatus {
        requests.append(permission)
        if suspend { await withCheckedContinuation { continuation = $0 } }
        statuses[permission] = result
        return result
    }
    func openSettings(for permission: MeetingPermission) -> Bool {
        settings.append(permission); return opensSettings
    }
    func recordDenial(_ permission: MeetingPermission) {
        if !preservesAllowedOnDenial { statuses[permission] = .denied }
    }
}

@MainActor
private final class PermissionTestCapture: MeetingCapturing {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?
    var onNotice: ((String?) -> Void)?
    var starts = 0
    var stops = 0
    var failStartup = true
    var startupError: Error?
    var callbackFailure: CaptureFailure?
    var suspend = false
    var continuation: CheckedContinuation<Void, Never>?
    func start(mode: CaptureMode, locale: String) async throws {
        starts += 1
        if let callbackFailure { onFailure?(callbackFailure) }
        if suspend { await withCheckedContinuation { continuation = $0 } }
        if let startupError { throw startupError }
        if failStartup { throw NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue) }
    }
    func stop() async { stops += 1 }
}

@MainActor
struct MeetingPermissionTests {
    @Test func permissionActionsAreNeutralBeforeConsentAndOfferSettingsAfterDenial() {
        for permission in [MeetingPermission.microphone, .screenRecording, .speechRecognition] {
            #expect(permission.actionTitle(for: .notGranted) == "Continue")
            #expect(permission.actionTitle(for: .denied) == "Open Settings")
            #expect(permission.actionTitle(for: .allowed) == "Settings")
        }
        #expect(MeetingPermission.systemAudio.actionTitle(for: .onStart) == "Open Settings")
    }
    private func repository() -> FileLibraryRepository {
        FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("PermissionTest-\(UUID().uuidString)"))
    }

    @Test func nativePreflightTakesPrecedenceOverAnEarlierRefusal() throws {
        let suite = "CanopyPermissionPreflight-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var allowed = false
        let permissions = NativeMeetingPermissions(defaults: defaults, screenAccess: { allowed }, requestIdentity: "test-signer")
        #expect(permissions.status(for: .screenRecording) == .notGranted)
        permissions.recordDenial(.screenRecording)
        #expect(permissions.status(for: .screenRecording) == .denied)
        allowed = true
        #expect(permissions.status(for: .screenRecording) == .allowed)
        permissions.recordDenial(.screenRecording)
        #expect(permissions.status(for: .screenRecording) == .allowed)
    }

    @Test func rememberedRefusalFollowsTheSigningIdentityRatherThanTheBundleName() throws {
        let suite = "CanopyPermissionScope-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "meetingPermissions.screenRequested") // Legacy build's refusal.
        let current = NativeMeetingPermissions(defaults: defaults, screenAccess: { false }, requestIdentity: "certificate-A")
        #expect(current.status(for: .screenRecording) == .notGranted)
        current.recordDenial(.screenRecording)
        let sameSigner = NativeMeetingPermissions(defaults: defaults, screenAccess: { false }, requestIdentity: "certificate-A")
        #expect(sameSigner.status(for: .screenRecording) == .denied)
        let changedSigner = NativeMeetingPermissions(defaults: defaults, screenAccess: { false }, requestIdentity: "certificate-B")
        #expect(changedSigner.status(for: .screenRecording) == .notGranted)
    }

    @Test func unavailableSigningIdentityRemembersRequestsOnlyWithinTheSession() throws {
        let suite = "CanopyPermissionScope-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let current = NativeMeetingPermissions(defaults: defaults, screenAccess: { false }, requestIdentity: nil)
        current.recordDenial(.screenRecording)
        #expect(current.status(for: .screenRecording) == .denied)
        let reopened = NativeMeetingPermissions(defaults: defaults, screenAccess: { false }, requestIdentity: nil)
        #expect(reopened.status(for: .screenRecording) == .notGranted)
    }

    @Test func runtimeRefusalWithGrantedAccessKeepsARestartIssueWithoutPromptingAgain() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        permissions.statuses[.screenRecording] = .allowed
        permissions.preservesAllowedOnDenial = true
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Stale session", mode: .system)
        #expect(state.permissionRequiresRestart && state.permissionIssue == .screenRecording)
        #expect(state.meetingPermissions[.screenRecording] == .allowed && state.showingPermissionPrompt)
        #expect(state.library.meetings.isEmpty && !state.recording)
        state.refreshMeetingPermissions()
        #expect(state.permissionIssue == .screenRecording && state.permissionRequiresRestart)
        await state.requestMeetingPermission(.screenRecording)
        #expect(permissions.requests.isEmpty && permissions.settings.isEmpty)
        #expect(state.banner?.contains("Quit and reopen") == true && state.permissionRequiresRestart)
        capture.failStartup = false
        await state.startMeeting(title: "Explicit retry", mode: .system)
        #expect(state.recording && !state.permissionRequiresRestart && state.permissionIssue == nil)
        await state.shutdown()
    }

    @Test func aDifferentPermissionIssueDoesNotInheritAScreenRestartDiagnosis() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        permissions.statuses[.screenRecording] = .allowed
        permissions.preservesAllowedOnDenial = true
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Stale session", mode: .system)
        await state.requestMeetingPermission(.microphone)
        #expect(state.permissionIssue == .microphone && !state.permissionRequiresRestart)
        await state.shutdown()
    }

    @Test func refusalPresentsAnInAppPromptAndRetryOpensTheCorrectSetting() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Denied", mode: .system)
        #expect(state.showingPermissionPrompt && state.permissionIssue == .screenRecording)
        state.showingPermissionPrompt = false // “Not now” retains the recovery card.
        #expect(state.permissionIssue == .screenRecording)
        await state.requestMeetingPermission(.screenRecording)
        #expect(permissions.requests == [.screenRecording] && permissions.settings == [.screenRecording])
        #expect(!state.showingPermissionPrompt && state.permissionIssue == .screenRecording)
        #expect(capture.starts == 1 && !state.recording && state.library.meetings.isEmpty)
        #expect(!state.permissionBusy)
        await state.shutdown()
    }

    @Test func grantingAccessAndReturningFromSettingsNeverStartsRecording() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Denied", mode: .system)
        permissions.result = .allowed
        permissions.statuses[.screenRecording] = .allowed
        await state.requestMeetingPermission(.screenRecording)
        #expect(state.permissionIssue == nil && !state.showingPermissionPrompt)
        #expect(state.meetingPermissions[.screenRecording] == .allowed && permissions.settings.isEmpty)
        state.refreshMeetingPermissions()
        #expect(permissions.requests.isEmpty && capture.starts == 1 && !state.recording)
        await state.shutdown()
    }

    @Test func statusRefreshIsReadOnlyAndClearsAResolvedRefusal() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Denied", mode: .system)
        state.refreshMeetingPermissions()
        #expect(state.permissionIssue == .screenRecording)
        permissions.statuses[.screenRecording] = .allowed
        state.refreshMeetingPermissions()
        #expect(state.permissionIssue == nil && !state.showingPermissionPrompt)
        #expect(permissions.requests.isEmpty && permissions.settings.isEmpty && !state.recording)
        await state.shutdown()
    }

    @Test func restrictedAccessAndUnavailableSettingsGiveActionableMessages() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions()
        let state = AppState(repository: repository, meetingCapture: PermissionTestCapture(), permissionService: permissions)
        permissions.result = .restricted
        await state.requestMeetingPermission(.microphone)
        #expect(permissions.settings.isEmpty && state.banner?.contains("restricted") == true)
        permissions.result = .denied; permissions.opensSettings = false
        permissions.statuses[.speechRecognition] = .denied
        await state.requestMeetingPermission(.speechRecognition)
        #expect(permissions.settings == [.speechRecognition])
        #expect(state.banner?.contains("System Settings") == true && state.banner?.contains("Speech recognition") == true)
        await state.shutdown()
    }

    @Test func rapidClicksRequestOnlyOnceAndPreviewDoesNotTouchPermissions() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(); permissions.suspend = true
        let state = AppState(repository: repository, meetingCapture: PermissionTestCapture(), permissionService: permissions)
        let first = Task { await state.requestMeetingPermission(.screenRecording) }
        for _ in 0..<100 { if permissions.continuation != nil { break }; await Task.yield() }
        #expect(state.permissionBusy)
        await state.requestMeetingPermission(.screenRecording)
        #expect(permissions.requests == [.screenRecording])
        permissions.continuation?.resume(); await first.value
        await state.shutdown()

        let previewPermissions = FakeMeetingPermissions()
        let preview = AppState(repository: repository, permissionService: previewPermissions, demo: true)
        preview.refreshMeetingPermissions()
        await preview.requestMeetingPermission(.screenRecording)
        preview.openMeetingPermissionSettings(.microphone)
        #expect(previewPermissions.reads == 0 && previewPermissions.requests.isEmpty && previewPermissions.settings.isEmpty)
        await preview.shutdown()
    }

    @Test func freshRefusalKeepsTheCardAndOnlyTheNextClickOpensSettings() async {
        for permission in [MeetingPermission.screenRecording, .microphone, .speechRecognition] {
            let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
            let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
            let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
            await state.requestMeetingPermission(permission)
            #expect(permissions.requests == [permission] && permissions.settings.isEmpty)
            #expect(state.permissionIssue == permission && !state.showingPermissionPrompt)
            await state.requestMeetingPermission(permission)
            let expectedRequests: [MeetingPermission] = permission == .screenRecording ? [permission, permission] : [permission]
            #expect(permissions.requests == expectedRequests && permissions.settings == [permission])
            #expect(capture.starts == 0 && !state.recording)
            await state.shutdown()
        }
    }

    @Test func permissionCallbackDuringStartupRetainsItsRecoveryDetails() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture()
        capture.failStartup = false
        capture.callbackFailure = CaptureFailure(error: NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue))
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Callback refusal", mode: .system)
        #expect(state.permissionIssue == .screenRecording && state.showingPermissionPrompt)
        #expect(state.library.meetings.isEmpty && !state.recording && capture.stops == 1)
        await state.shutdown()
    }

    @Test func disabledDictationShowsSetupRecoveryWithoutChangingGrantedSpeechPermission() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture()
        capture.startupError = CaptureFailure(error: NSError(domain: "kLSRErrorDomain", code: 201, userInfo: [NSLocalizedDescriptionKey: "A localized description"]))
        let permissions = FakeMeetingPermissions(); permissions.statuses[.speechRecognition] = .allowed
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Dictation off", mode: .system)
        #expect(state.meetingSetupIssue == .dictationDisabled && state.showingPermissionPrompt)
        #expect(state.permissionIssue == nil && !state.permissionRequiresRestart && !state.recording && state.library.meetings.isEmpty)
        #expect(permissions.statuses[.speechRecognition] == .allowed && permissions.requests.isEmpty)
        state.showingPermissionPrompt = false
        state.refreshMeetingPermissions()
        #expect(state.meetingSetupIssue == .dictationDisabled && !state.recording)
        capture.startupError = nil; capture.failStartup = false
        await state.startMeeting(title: "Explicit retry", mode: .system)
        #expect(state.recording && state.meetingSetupIssue == .dictationDisabled)
        capture.onSegment?(TranscriptSegment(source: .system, text: "The service is receiving speech."))
        #expect(state.meetingSetupIssue == nil)
        await state.shutdown()
    }

    @Test func dictationFailureAfterStartupStopsCaptureAndRestoresSetupRecovery() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture(); capture.failStartup = false
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: FakeMeetingPermissions())
        await state.startMeeting(title: "Late service failure", mode: .both)
        #expect(state.recording)
        capture.onFailure?(CaptureFailure(error: NSError(domain: "kLSRErrorDomain", code: 201)))
        for _ in 0..<100 { if !state.recording { break }; await Task.yield() }
        #expect(!state.recording && capture.stops == 1 && state.activeMeetingID == nil)
        #expect(state.meetingSetupIssue == .dictationDisabled && state.showingPermissionPrompt && state.permissionIssue == nil)
        await state.shutdown()
    }

    @Test func aRuntimeSpeechRefusalDoesNotDisappearWhenTCCStillReportsAllowed() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture(); capture.startupError = NSError(domain: "kAFAssistantErrorDomain", code: 1700)
        let permissions = FakeMeetingPermissions(); permissions.statuses[.speechRecognition] = .allowed; permissions.preservesAllowedOnDenial = true
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Speech refusal", mode: .system)
        state.refreshMeetingPermissions()
        await state.requestMeetingPermission(.speechRecognition)
        #expect(state.permissionIssue == .speechRecognition && state.permissionRequiresRestart)
        #expect(permissions.requests.isEmpty && !state.recording)
        await state.shutdown()
    }

    @Test func documentedDictationErrorMappingMatchesItsDomainAndSurvivesWrapping() {
        let error = NSError(domain: "kLSRErrorDomain", code: 201)
        let wrapped = CaptureFailure(error: error, prefix: "Microphone stopped: ")
        #expect(CaptureError.setupIssue(for: error) == .dictationDisabled)
        #expect(CaptureError.setupIssue(for: wrapped) == .dictationDisabled)
        #expect(CaptureError.permission(for: wrapped) == nil)
        #expect(wrapped.message.contains("Keyboard → Dictation"))
        #expect(CaptureError.setupIssue(for: NSError(domain: "OtherDomain", code: 201)) == nil)
        #expect(CaptureError.permission(for: NSError(domain: "kAFAssistantErrorDomain", code: 1700)) == .speechRecognition)
    }

    @Test func noSoundHintLeavesTheMeetingRunningAndDoesNotDeclarePermissionDenied() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture(); capture.failStartup = false
        let permissions = FakeMeetingPermissions()
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Quiet meeting", mode: .system)
        capture.onNotice?("No meeting audio received yet.")
        #expect(state.recording && state.systemAudioNotice != nil && capture.stops == 0)
        #expect(state.permissionIssue == nil && !state.showingPermissionPrompt && permissions.settings.isEmpty)
        capture.onNotice?(nil)
        #expect(state.systemAudioNotice == nil && state.recording)
        await state.shutdown()
    }

    @Test func losingPermissionDuringAMeetingStopsAndShowsRecovery() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(), capture = PermissionTestCapture(); capture.failStartup = false
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        await state.startMeeting(title: "Revoked", mode: .system)
        #expect(state.recording)
        capture.onFailure?(CaptureFailure("Access was revoked", permission: .screenRecording))
        for _ in 0..<100 { if !state.recording { break }; await Task.yield() }
        #expect(!state.recording && state.activeMeetingID == nil && capture.stops == 1)
        #expect(state.permissionIssue == .screenRecording && state.showingPermissionPrompt)
        #expect(state.library.meetings.first?.endedAt != nil)
        await state.shutdown()
    }

    @Test func cancellingPreparationIgnoresALateStartAndLeavesNoPendingMeeting() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture(); capture.failStartup = false; capture.suspend = true
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: FakeMeetingPermissions())
        let start = Task { await state.startMeeting(title: "Cancelled setup", mode: .defaultMode) }
        for _ in 0..<100 { if capture.continuation != nil { break }; await Task.yield() }
        await state.cancelMeetingPreparation()
        capture.continuation?.resume(); await start.value
        #expect(!state.recording && !state.recordingTransition && state.library.meetings.isEmpty)
        #expect(state.banner == "Meeting preparation cancelled." && state.speechPreparation == nil)
        await state.shutdown()
    }

    @Test func quittingWhileCaptureStartsStopsLateSuccessAndRemovesThePendingMeeting() async throws {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let capture = PermissionTestCapture(); capture.failStartup = false; capture.suspend = true
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: FakeMeetingPermissions())
        let start = Task { await state.startMeeting(title: "Pending", mode: .system) }
        for _ in 0..<100 { if capture.continuation != nil { break }; await Task.yield() }
        #expect(state.recordingTransition)
        await state.shutdown()
        capture.continuation?.resume(); await start.value
        #expect(capture.stops == 2 && !state.recording && !state.recordingTransition)
        #expect(state.activeMeetingID == nil && state.library.meetings.isEmpty)
        #expect(try repository.load().meetings.isEmpty)
        await state.startMeeting(title: "After quit", mode: .system)
        #expect(capture.starts == 1)
    }

    @Test func quittingDuringPermissionRequestBlocksRecordingAndIgnoresTheLateResult() async {
        let repository = repository(); defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(); permissions.suspend = true; permissions.result = .allowed
        let capture = PermissionTestCapture()
        let state = AppState(repository: repository, meetingCapture: capture, permissionService: permissions)
        let request = Task { await state.requestMeetingPermission(.screenRecording) }
        for _ in 0..<100 { if permissions.continuation != nil { break }; await Task.yield() }
        await state.startMeeting(title: "During consent", mode: .system)
        #expect(capture.starts == 0)
        await state.shutdown()
        permissions.continuation?.resume(); await request.value
        #expect(!state.permissionBusy && permissions.settings.isEmpty && state.meetingPermissions.isEmpty)
    }
}
