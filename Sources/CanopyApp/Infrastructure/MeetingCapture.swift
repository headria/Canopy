import AVFoundation
import CanopyCore
import ScreenCaptureKit
import Speech

enum CaptureMode: String, CaseIterable, Identifiable {
    case both = "Meeting + microphone", system = "Meeting audio", microphone = "Microphone"
    static let defaultMode: CaptureMode = .system
    var id: String { rawValue }
    var includesMic: Bool { self != .system }
    var includesSystem: Bool { self != .microphone }
}

enum CaptureError: LocalizedError {
    case dictationDisabled, microphoneDenied, speechDenied, systemAudioDenied, screenRecordingDenied, localSpeechUnavailable, noDisplay, invalidMicFormat
    var errorDescription: String? {
        switch self {
        case .dictationDisabled: return MeetingSetupIssue.dictationDisabled.detail
        case .microphoneDenied: return "Allow \(ProductBrand.name) to use your microphone in System Settings → Privacy & Security → Microphone."
        case .speechDenied: return "Allow Speech Recognition for \(ProductBrand.name) in System Settings → Privacy & Security."
        case .systemAudioDenied:
            return "Allow \(ProductBrand.name) under System Audio Recording Only in System Settings → Privacy & Security → Screen & System Audio Recording, then choose Start listening again."
        case .screenRecordingDenied:
            let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? "this app"
            return "macOS hasn't made meeting audio access available to this copy of \(appName). In System Settings → Privacy & Security → Screen & System Audio Recording, check \(appName). If access is already enabled, quit and reopen the app. If it still fails, remove its old entry with − and add \(Bundle.main.bundleURL.path) again with +, then reopen it."
        case .localSpeechUnavailable: return "On-device speech recognition is unavailable for this language. Try en-US in Settings and check that macOS speech assets are installed. \(ProductBrand.name) does not fall back to cloud transcription."
        case .noDisplay: return "No display is available for meeting audio capture."
        case .invalidMicFormat: return "The microphone is unavailable. Select a working input in System Settings → Sound and try again."
        }
    }

    /// Match the SDK error domain and code, rather than its localized TCC wording.
    static func message(for error: Error) -> String {
        if let setup = setupIssue(for: error) { return setup.detail }
        if let tapError = error as? AudioTapError { return tapError.localizedDescription }
        let systemError = error as NSError
        if systemError.domain == SCStreamError.errorDomain,
           systemError.code == SCStreamError.Code.userDeclined.rawValue {
            return CaptureError.screenRecordingDenied.localizedDescription
        }
        return error.localizedDescription
    }

    /// These domain/code pairs are documented in SFSpeechRecognitionTask.h.
    /// Keep localized error text for unknown failures; do not match its wording.
    static func setupIssue(for error: Error) -> MeetingSetupIssue? {
        if let failure = error as? CaptureFailure { return failure.setupIssue }
        if let captureError = error as? CaptureError, case .dictationDisabled = captureError { return .dictationDisabled }
        let error = error as NSError
        return error.domain == "kLSRErrorDomain" && error.code == 201 ? .dictationDisabled : nil
    }

    static func permission(for error: Error) -> MeetingPermission? {
        if let failure = error as? CaptureFailure { return failure.permission }
        if let tapError = error as? AudioTapError { return tapError.permission }
        if let captureError = error as? CaptureError {
            switch captureError {
            case .systemAudioDenied: return .systemAudio
            case .screenRecordingDenied: return .screenRecording
            case .microphoneDenied: return .microphone
            case .speechDenied: return .speechRecognition
            default: return nil
            }
        }
        let systemError = error as NSError
        if systemError.domain == "kAFAssistantErrorDomain", systemError.code == 1700 { return .speechRecognition }
        return systemError.domain == SCStreamError.errorDomain
            && systemError.code == SCStreamError.Code.userDeclined.rawValue ? .screenRecording : nil
    }
}

struct CaptureFailure: LocalizedError, Sendable {
    let message: String
    let permission: MeetingPermission?
    let setupIssue: MeetingSetupIssue?
    init(_ message: String, permission: MeetingPermission? = nil, setupIssue: MeetingSetupIssue? = nil) {
        self.message = message; self.permission = permission; self.setupIssue = setupIssue
    }
    init(error: Error, prefix: String = "") {
        let setup = CaptureError.setupIssue(for: error)
        self.init((setup == nil ? prefix : "") + CaptureError.message(for: error), permission: CaptureError.permission(for: error), setupIssue: setup)
    }
    var errorDescription: String? { message }
}

@MainActor
protocol MeetingCapturing: AnyObject {
    var onSegment: ((TranscriptSegment) -> Void)? { get set }
    var onFailure: ((CaptureFailure) -> Void)? { get set }
    var onNotice: ((String?) -> Void)? { get set }
    var onPreparation: ((SpeechPreparation?) -> Void)? { get set }
    var onAudioLevel: ((Double?) -> Void)? { get set }
    func start(mode: CaptureMode, locale: String) async throws
    func stop() async
}

extension MeetingCapturing {
    var onNotice: ((String?) -> Void)? { get { nil } set { } }
    var onPreparation: ((SpeechPreparation?) -> Void)? { get { nil } set { } }
    var onAudioLevel: ((Double?) -> Void)? { get { nil } set { } }
}

/// One serial queue owns each recognizer and its requests, including input and rotation.
/// Partial results keep the same identity, so they update a row instead of duplicating text.
final class SpeechChannel: SpeechTranscribing {
    private let queue: DispatchQueue
    private let source: AudioSource
    private let recognizer: SFSpeechRecognizer
    private let output: (TranscriptSegment) -> Void
    private let failure: (CaptureFailure) -> Void
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timer: DispatchSourceTimer?
    private var segment: TranscriptSegment?
    private var active = false

    init(source: AudioSource, locale: String, output: @escaping (TranscriptSegment) -> Void, failure: @escaping (CaptureFailure) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { throw CaptureError.localSpeechUnavailable }
        self.recognizer = recognizer; self.source = source; self.output = output; self.failure = failure
        queue = DispatchQueue(label: "com.canopy.speech.\(source.rawValue)")
    }

    func start() async throws { queue.sync { active = true; beginRequest() } }
    func append(_ buffer: AVAudioPCMBuffer) { queue.async { [weak self] in self?.request?.append(buffer) } }
    func append(_ buffer: CMSampleBuffer) { queue.async { [weak self] in self?.request?.appendAudioSampleBuffer(buffer) } }
    func stop() async {
        queue.sync {
            active = false; timer?.cancel(); timer = nil
            commitPartial(); request?.endAudio(); task?.cancel(); task = nil; request = nil
        }
    }

    private func beginRequest() {
        guard active else { return }
        let id = UUID()
        segment = TranscriptSegment(id: id, source: source, text: "")
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true; request.requiresOnDeviceRecognition = true; request.addsPunctuation = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                guard self.active, self.segment?.id == id else { return }
                if let result {
                    self.segment?.text = result.bestTranscription.formattedString
                    self.segment?.isFinal = result.isFinal
                    if let segment = self.segment { self.output(segment) }
                    if result.isFinal { self.rotate(); return }
                }
                if let error {
                    let nsError = error as NSError
                    // Silence is normal; cancellation from rotation is filtered by segment identity.
                    if nsError.domain == "kAFAssistantErrorDomain", nsError.code == 1110 { self.rotate() }
                    else {
                        self.commitPartial(); self.active = false; self.timer?.cancel()
                        self.request = nil; self.task = nil
                        self.failure(CaptureFailure(error: error, prefix: "\(self.source == .microphone ? "Microphone" : "Meeting") transcription stopped: "))
                    }
                }
            }
        }
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 50)
        timer.setEventHandler { [weak self] in self?.rotate() }
        self.timer = timer; timer.resume()
    }

    private func commitPartial() {
        if var segment, !segment.text.isEmpty { segment.isFinal = true; output(segment) }
    }
    private func rotate() {
        commitPartial(); segment = nil
        request?.endAudio(); task?.cancel(); task = nil; request = nil
        beginRequest()
    }
}

final class SystemAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    let speech: any SpeechTranscribing
    let failure: (CaptureFailure) -> Void
    let activity: (Double) -> Void
    private var lastActivity = -Double.infinity
    init(speech: any SpeechTranscribing, failure: @escaping (CaptureFailure) -> Void, activity: @escaping (Double) -> Void) {
        self.speech = speech; self.failure = failure; self.activity = activity
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid, CMSampleBufferGetNumSamples(buffer) > 0,
              let description = CMSampleBufferGetFormatDescription(buffer) else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(buffer))
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        copy.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(buffer, at: 0, frameCount: Int32(frames), into: copy.mutableAudioBufferList)
        if status == noErr {
            speech.append(copy)
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastActivity >= 0.2 { lastActivity = now; activity(AudioTapPCM.level(copy)) }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failure(CaptureFailure(error: error, prefix: "Meeting audio stopped: ")) }
}

@MainActor
final class NativeMeetingCapture: MeetingCapturing {
    var onSegment: ((TranscriptSegment) -> Void)?
    var onFailure: ((CaptureFailure) -> Void)?
    var onNotice: ((String?) -> Void)?
    var onPreparation: ((SpeechPreparation?) -> Void)?
    var onAudioLevel: ((Double?) -> Void)?
    private let makeSystemAudio: @MainActor () -> SystemAudioCapturing?
    private var stopping = false
    private var micSpeech: (any SpeechTranscribing)?
    private var systemSpeech: (any SpeechTranscribing)?
    private var engine: AVAudioEngine?
    private var systemAudio: SystemAudioCapturing?
    private var stream: SCStream?
    private var streamOutput: SystemAudioOutput?
    private var generation = UUID()
    private var startupGeneration = UUID()
    private var engineObserver: NSObjectProtocol?
    init(systemAudioFactory: @escaping @MainActor () -> SystemAudioCapturing? = {
        if #available(macOS 14.2, *) { return SystemAudioTap() }; return nil
    }) { makeSystemAudio = systemAudioFactory }

    func start(mode: CaptureMode, locale: String) async throws {
        guard micSpeech == nil, systemSpeech == nil, engine == nil, systemAudio == nil, stream == nil else {
            throw CaptureFailure("Finish the current meeting before starting another one.")
        }
        try Task.checkCancellation()
        let token = UUID(); generation = token; startupGeneration = token; stopping = false
        if SpeechBackend.current == .legacy {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        try checkStartup(token)
        guard status == .authorized else { throw CaptureError.speechDenied }
        }
        if mode.includesMic {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            try checkStartup(token)
            guard granted else { throw CaptureError.microphoneDenied }
        }
        let output: (TranscriptSegment) -> Void = { [weak self] segment in
            Task { @MainActor in if self?.generation == token { self?.onSegment?(segment) } }
        }
        let failure: (CaptureFailure) -> Void = { [weak self] error in
            Task { @MainActor in
                guard let self, self.generation == token, !self.stopping else { return }
                self.stopping = true // Both recognizers may report the same service failure.
                self.onFailure?(error)
            }
        }
        let activity: (Double) -> Void = { [weak self] level in
            Task { @MainActor in
                if self?.generation == token, self?.stopping == false { self?.onAudioLevel?(level) }
            }
        }
        var startingStream: SCStream?
        do {
            if mode.includesSystem {
                let speech = try makeSpeechChannel(source: .system, locale: locale, output: output, failure: failure, token: token)
                systemSpeech = speech; try await speech.start(); try checkStartup(token)
                if #available(macOS 14.2, *) {
                    guard let tap = makeSystemAudio() else { throw CaptureFailure("Meeting audio capture is unavailable.") }
                    systemAudio = tap
                    try tap.start(output: { speech.append($0) }, failure: failure, notice: { [weak self] message in
                        Task { @MainActor in
                            if self?.generation == token, self?.stopping == false { self?.onNotice?(message) }
                        }
                    }, activity: activity)
                    try checkStartup(token)
                } else {
                    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                    try checkStartup(token)
                    guard let display = content.displays.first else { throw CaptureError.noDisplay }
                    let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    let config = SCStreamConfiguration()
                    config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                    config.sampleRate = 16_000; config.channelCount = 1
                    config.width = 2; config.height = 2; config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let delegate = SystemAudioOutput(speech: speech, failure: failure, activity: activity)
                    streamOutput = delegate
                    let stream = SCStream(filter: filter, configuration: config, delegate: delegate)
                    startingStream = stream
                    try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.canopy.systemaudio"))
                    self.stream = stream
                    try await stream.startCapture()
                    try checkStartup(token)
                }
            }
            if mode.includesMic {
                let speech = try makeSpeechChannel(source: .microphone, locale: locale, output: output, failure: failure, token: token)
                micSpeech = speech; try await speech.start(); try checkStartup(token)
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.invalidMicFormat }
                input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                    // AVAudioEngine reuses tap buffers; copy before dispatching to the recognition queue.
                    guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return }
                    copy.frameLength = buffer.frameLength
                    let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                    let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
                    for index in 0..<min(source.count, target.count) {
                        if let from = source[index].mData, let to = target[index].mData {
                            memcpy(to, from, Int(source[index].mDataByteSize))
                        }
                    }
                    speech.append(copy)
                }
                self.engine = engine
                engineObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { _ in
                    failure(CaptureFailure("Your audio input changed. Capture has stopped; select the new microphone and start again."))
                }
                engine.prepare(); try engine.start()
            }
        } catch {
            if startupGeneration == token { await stop() }
            else if let startingStream { try? await startingStream.stopCapture() }
            throw error
        }
    }

    private func makeSpeechChannel(source: AudioSource, locale: String, output: @escaping (TranscriptSegment) -> Void,
                                   failure: @escaping (CaptureFailure) -> Void, token: UUID) throws -> any SpeechTranscribing {
        if #available(macOS 26.0, *), SpeechBackend.current == .analyzer {
            return AnalyzerSpeechChannel(source: source, locale: locale, output: output, failure: failure, progress: { [weak self] preparation in
                Task { @MainActor in
                    if self?.generation == token, self?.stopping == false { self?.onPreparation?(preparation) }
                }
            })
        }
        return try SpeechChannel(source: source, locale: locale, output: output, failure: failure)
    }

    private func checkStartup(_ token: UUID) throws {
        guard startupGeneration == token else { throw CancellationError() }
        try Task.checkCancellation()
    }

    func stop() async {
        startupGeneration = UUID(); stopping = true
        onNotice?(nil); onPreparation?(nil); onAudioLevel?(nil)
        let stoppedGeneration = generation
        if let engineObserver { NotificationCenter.default.removeObserver(engineObserver); self.engineObserver = nil }
        engine?.inputNode.removeTap(onBus: 0); engine?.stop(); engine = nil
        systemAudio?.stop(); systemAudio = nil
        if let stream { try? await stream.stopCapture() }
        stream = nil; streamOutput = nil
        let mic = micSpeech, system = systemSpeech
        micSpeech = nil; systemSpeech = nil
        await mic?.stop(); await system?.stop()
        // Let final partial-result deliveries reach the main actor before callers finish the meeting.
        await Task.yield()
        if generation == stoppedGeneration { generation = UUID() }
    }
}
