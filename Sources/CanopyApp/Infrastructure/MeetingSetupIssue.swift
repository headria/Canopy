import Foundation

/// A speech-service prerequisite is separate from the app's TCC permissions.
/// Public Speech authorization can be allowed while macOS Dictation is off.
enum MeetingSetupIssue: Equatable, Sendable {
    case dictationDisabled
    var title: String { "Turn on Dictation" }
    var detail: String {
        "Apple's speech recognizer reports that Siri or Dictation is disabled. Turn on Dictation in System Settings → Keyboard → Dictation, then choose Start listening again."
    }
    var settingsURL: URL { URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")! }
}
