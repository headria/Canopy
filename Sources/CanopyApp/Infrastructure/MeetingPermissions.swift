import AppKit
import CanopyCore
import AVFoundation
import CoreGraphics
import Speech

enum MeetingPermission: String, CaseIterable, Identifiable, Sendable {
    case systemAudio, screenRecording, microphone, speechRecognition
    static var availableCases: [MeetingPermission] {
        if #available(macOS 14.2, *) {
            return SpeechBackend.current == .analyzer ? [.systemAudio, .microphone] : [.systemAudio, .microphone, .speechRecognition]
        }
        return [.screenRecording, .microphone, .speechRecognition]
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .systemAudio: return "System audio"
        case .screenRecording: return "Screen & system audio"
        case .microphone: return "Microphone"
        case .speechRecognition: return "Speech recognition"
        }
    }
    var purpose: String {
        switch self {
        case .systemAudio: return "Listen to meeting audio from other apps, with audio-only access."
        case .screenRecording: return "Listen to meeting audio from Zoom, Meet, and other apps."
        case .microphone: return "Include your voice when you choose a microphone source."
        case .speechRecognition: return "Turn speech into text on your Mac."
        }
    }
    /// Before the system dialog, describe navigation without implying consent.
    func actionTitle(for status: MeetingPermissionStatus) -> String {
        if self == .systemAudio { return "Open Settings" }
        switch status {
        case .notGranted: return "Continue"
        case .allowed: return "Settings"
        case .denied, .restricted, .onStart: return "Open Settings"
        }
    }
    var settingsURL: URL {
        let pane: String
        switch self {
        case .systemAudio, .screenRecording: pane = "Privacy_ScreenCapture"
        case .microphone: pane = "Privacy_Microphone"
        case .speechRecognition: pane = "Privacy_SpeechRecognition"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!
    }
    var recoveryDetail: String {
        if self == .systemAudio {
            return "Enable \(ProductBrand.name) under System Audio Recording Only, then try Start listening. macOS checks audio access when capture starts."
        }
        if self == .screenRecording {
            return "Already enabled? Reopen \(ProductBrand.name). If still blocked, remove the old permission entry and add this app again."
        }
        return purpose
    }
}

enum MeetingPermissionStatus: Equatable {
    case onStart, notGranted, allowed, denied, restricted
    var label: String {
        switch self {
        case .onStart: return "Checked when listening"
        case .notGranted: return "Needs access"
        case .allowed: return "Allowed"
        case .denied: return "Access not available"
        case .restricted: return "Restricted by macOS"
        }
    }
}

/// Reading status never prompts, records audio, or starts a meeting.
@MainActor
protocol MeetingPermissionServing {
    func status(for permission: MeetingPermission) -> MeetingPermissionStatus
    func request(_ permission: MeetingPermission) async -> MeetingPermissionStatus
    func recordDenial(_ permission: MeetingPermission)
    @discardableResult func openSettings(for permission: MeetingPermission) -> Bool
}

@MainActor
final class NativeMeetingPermissions: MeetingPermissionServing {
    private let defaults: UserDefaults
    private let screenAccess: () -> Bool
    private let screenRequestKey: String?
    private var screenRequestedThisSession = false
    init(defaults: UserDefaults = .standard, screenAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         requestIdentity: String? = AppSigningIdentity.permissionScope) {
        self.defaults = defaults; self.screenAccess = screenAccess
        screenRequestKey = requestIdentity.map { "meetingPermissions.screenRequested.\($0)" }
    }
    func status(for permission: MeetingPermission) -> MeetingPermissionStatus {
        switch permission {
        case .systemAudio:
            // Core Audio has no public read-only authorization preflight.
            // Screen preflight describes a different permission. Never substitute it.
            return .onStart
        case .screenRecording:
            // Preflight is read-only. Remember our own request/refusal to avoid duplicate dialogs.
            if screenAccess() { return .allowed }
            let requested = screenRequestedThisSession || screenRequestKey.map { defaults.bool(forKey: $0) } == true
            return requested ? .denied : .notGranted
        case .microphone:
            return Self.microphoneStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        case .speechRecognition:
            return Self.speechStatus(SFSpeechRecognizer.authorizationStatus())
        }
    }

    func request(_ permission: MeetingPermission) async -> MeetingPermissionStatus {
        let existing = status(for: permission)
        guard existing != .allowed && existing != .restricted && permission != .systemAudio else { return existing }
        NSApp.activate()
        switch permission {
        case .systemAudio:
            return .onStart // Only an explicit Start listening starts the tap.
        case .screenRecording:
            // macOS owns the consent dialog. A prior refusal can require Settings instead.
            rememberScreenRequest()
            return CGRequestScreenCaptureAccess() ? .allowed : status(for: permission)
        case .microphone:
            guard existing == .notGranted else { return existing }
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            return status(for: permission)
        case .speechRecognition:
            guard existing == .notGranted else { return existing }
            let result = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            return Self.speechStatus(result)
        }
    }

    func recordDenial(_ permission: MeetingPermission) {
        if permission == .screenRecording { rememberScreenRequest() }
    }

    private func rememberScreenRequest() {
        screenRequestedThisSession = true
        if let screenRequestKey { defaults.set(true, forKey: screenRequestKey) }
    }

    func openSettings(for permission: MeetingPermission) -> Bool {
        if NSWorkspace.shared.open(permission.settingsURL) { return true }
        // A macOS release can change its pane URL; retain a usable Privacy fallback.
        return NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!)
    }

    private static func microphoneStatus(_ status: AVAuthorizationStatus) -> MeetingPermissionStatus {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notGranted
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .notGranted
        }
    }
    private static func speechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> MeetingPermissionStatus {
        switch status {
        case .authorized: return .allowed
        case .notDetermined: return .notGranted
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .notGranted
        }
    }
}
