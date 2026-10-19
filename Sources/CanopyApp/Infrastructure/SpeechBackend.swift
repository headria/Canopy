import AVFoundation
import Speech

/// The modern engine uses local model assets, independent of the Siri/Dictation service.
enum SpeechBackend {
    case analyzer, legacy
    static var current: SpeechBackend {
        if #available(macOS 26.0, *), SpeechTranscriber.isAvailable { return .analyzer }
        return .legacy
    }
}

struct SpeechPreparation: Equatable, Sendable {
    let message: String
    let fraction: Double?
}

protocol SpeechTranscribing: AnyObject {
    func start() async throws
    func append(_ buffer: AVAudioPCMBuffer)
    func stop() async
}
