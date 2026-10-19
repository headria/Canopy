import AVFoundation
import CanopyCore
import Speech

/// Reservations are shared by the two meeting channels and retained for reuse.
/// A single asset task prepares each language; it contains no captured audio.
@available(macOS 26.0, *)
actor SpeechLanguageAssets {
    static let shared = SpeechLanguageAssets()
    private var uses: [String: Int] = [:]
    private var tasks: [String: Task<Void, Error>] = [:]

    func acquire(_ identifier: String, progress: @escaping (SpeechPreparation?) -> Void) async throws -> Locale {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw CaptureFailure("Local meeting transcription doesn't support \(identifier). Choose a supported speech language, such as en-US, in Canopy Settings.")
        }
        let key = locale.identifier
        uses[key, default: 0] += 1
        if tasks[key] == nil {
            tasks[key] = Task {
                // Keep the configured language reserved between meetings, so the
                // next session can reuse it. Retire only inactive old languages.
                for old in await AssetInventory.reservedLocales where old != locale && self.uses[old.identifier, default: 0] == 0 {
                    _ = await AssetInventory.release(reservedLocale: old)
                }
                // False means this app already reserved the locale. Unsupported
                // languages and exhausted reservation capacity throw instead.
                _ = try await AssetInventory.reserve(locale: locale)
                let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                    progress(SpeechPreparation(message: "Downloading language support…", fraction: 0))
                    let observation = request.progress.observe(\.fractionCompleted, options: [.new]) { value, _ in
                        progress(SpeechPreparation(message: "Downloading language support…", fraction: value.fractionCompleted))
                    }
                    defer { observation.invalidate() }
                    try await withTaskCancellationHandler {
                        try await request.downloadAndInstall()
                    } onCancel: { request.progress.cancel() }
                }
                guard await AssetInventory.status(forModules: [module]) == .installed else {
                    throw CaptureFailure("Language support is not ready. Connect to the internet and choose Start listening again.")
                }
            }
        }
        do {
            let task = tasks[key]!
            try await withTaskCancellationHandler {
                try await task.value
                try Task.checkCancellation()
            } onCancel: { task.cancel() }
            return locale
        } catch {
            await release(locale)
            throw error
        }
    }

    func release(_ locale: Locale) async {
        let key = locale.identifier
        guard let count = uses[key] else { return }
        if count > 1 { uses[key] = count - 1; return }
        uses[key] = nil; tasks[key] = nil
        // The configured language stays reserved for the next meeting.
    }
}

/// Stable identities for revisable text. Final results and saved partials update
/// the same row; each channel has a separate accumulator and audio time origin.
struct AnalyzerTranscriptAccumulator {
    let source: AudioSource
    var startedAt: Date
    private var volatile: TranscriptSegment?
    private var lastFinalStart = -Double.infinity
    init(source: AudioSource, startedAt: Date = Date()) { self.source = source; self.startedAt = startedAt }
    mutating func update(startSeconds: Double, text: String, isFinal: Bool) -> TranscriptSegment? {
        guard startSeconds.isFinite, startSeconds >= 0, startSeconds < 1_000_000,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !isFinal, startSeconds <= lastFinalStart { return nil }
        let segment = TranscriptSegment(id: volatile?.id ?? UUID(), source: source, text: text,
            timestamp: startedAt.addingTimeInterval(startSeconds), isFinal: isFinal)
        if isFinal { volatile = nil; lastFinalStart = startSeconds }
        else { volatile = segment }
        return segment
    }
    mutating func finalizePartials() -> [TranscriptSegment] {
        guard var segment = volatile else { return [] }
        segment.isFinal = true; volatile = nil
        return [segment]
    }
}

/// Conversion stays on a serial queue. The gate bounds pending work before it
/// reaches that queue, and AsyncStream bounds audio waiting for the analyzer.
@available(macOS 26.0, *)
final class AnalyzerAudioFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.canopy.analyzer-input")
    private let gate = NSLock()
    private var accepting = false
    private var pending = 0
    private var overflowReported = false
    private var firstAudio: Date?
    var firstAudioDate: Date? { gate.withLock { firstAudio } }
    private var target: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var failure: ((CaptureFailure) -> Void)?

    func configure(format: AVAudioFormat, failure: @escaping (CaptureFailure) -> Void) -> AsyncStream<AnalyzerInput> {
        let pair = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(128))
        queue.sync { target = format; converter = nil; continuation = pair.continuation; self.failure = failure }
        gate.withLock { accepting = true; overflowReported = false; firstAudio = nil }
        return pair.stream
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        gate.lock()
        guard accepting else { gate.unlock(); return }
        if pending >= 64 {
            let shouldReport = !overflowReported; overflowReported = true
            gate.unlock()
            if shouldReport { queue.async { self.failure?(CaptureFailure("Transcription couldn't keep up with the audio. Start listening again.")) } }
            return
        }
        if firstAudio == nil { firstAudio = Date() }
        pending += 1; gate.unlock()
        queue.async {
            defer { self.gate.withLock { self.pending -= 1 } }
            guard let target = self.target, let continuation = self.continuation else { return }
            do {
                let converted = try self.convert(buffer, to: target)
                if converted.frameLength == 0 { return }
                if case .dropped = continuation.yield(AnalyzerInput(buffer: converted)) {
                    self.failure?(CaptureFailure("Transcription couldn't keep up with the audio. Start listening again."))
                }
            } catch { self.failure?(CaptureFailure(error: error)) }
        }
    }
    private func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == target { return buffer }
        if converter?.inputFormat != buffer.format || converter?.outputFormat != target {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converter?.downmix = true
        }
        guard let converter else { throw CaptureFailure("The meeting audio format could not be converted for local transcription.") }
        let count = ceil(Double(buffer.frameLength) * target.sampleRate / buffer.format.sampleRate) + 32
        guard count > 0, count <= 1_048_576,
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)) else {
            throw CaptureFailure("The meeting audio buffer is too large for transcription.")
        }
        var supplied = false
        var error: NSError?
        let result = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        if let error { throw error }
        if result == .error { throw CaptureFailure("The meeting audio could not be converted for transcription.") }
        return output
    }
    func finish() {
        gate.withLock { accepting = false }
        queue.sync { continuation?.finish(); continuation = nil; converter = nil; target = nil; failure = nil }
    }
}

@available(macOS 26.0, *)
actor AnalyzerSpeechChannel: SpeechTranscribing {
    private let localeIdentifier: String
    private let output: (TranscriptSegment) -> Void
    private let failure: (CaptureFailure) -> Void
    private let progress: (SpeechPreparation?) -> Void
    private nonisolated let feeder = AnalyzerAudioFeeder()
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var leasedLocale: Locale?
    private var run: UUID?
    private var accumulator: AnalyzerTranscriptAccumulator

    init(source: AudioSource, locale: String, output: @escaping (TranscriptSegment) -> Void,
         failure: @escaping (CaptureFailure) -> Void, progress: @escaping (SpeechPreparation?) -> Void) {
        localeIdentifier = locale; self.output = output; self.failure = failure; self.progress = progress
        accumulator = AnalyzerTranscriptAccumulator(source: source)
    }
    func start() async throws {
        guard run == nil else { throw CaptureFailure("Local transcription is already running.") }
        let token = UUID(); run = token
        do {
            progress(SpeechPreparation(message: "Preparing local transcription…", fraction: nil))
            let locale = try await SpeechLanguageAssets.shared.acquire(localeIdentifier, progress: progress)
            guard run == token, !Task.isCancelled else {
                await SpeechLanguageAssets.shared.release(locale); throw CancellationError()
            }
            leasedLocale = locale
            let module = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
                throw CaptureFailure("A local transcription audio format is unavailable for this language.")
            }
            try checkRun(token)
            let analyzer = SpeechAnalyzer(modules: [module])
            self.analyzer = analyzer
            try await analyzer.prepareToAnalyze(in: format)
            try checkRun(token)
            let inputs = feeder.configure(format: format, failure: failure)
            results = Task { [weak self] in
                do {
                    for try await result in module.results {
                        guard !Task.isCancelled else { return }
                        await self?.receive(result, token: token)
                    }
                } catch { await self?.receiveFailure(error, token: token) }
            }
            try await analyzer.start(inputSequence: inputs)
            try checkRun(token)
            progress(nil)
        } catch {
            if run == token { await stop() }
            throw error
        }
    }
    nonisolated func append(_ buffer: AVAudioPCMBuffer) { feeder.append(buffer) }
    private func checkRun(_ token: UUID) throws {
        guard run == token else { throw CancellationError() }
        try Task.checkCancellation()
    }
    private func receive(_ result: SpeechTranscriber.Result, token: UUID) {
        guard run == token else { return }
        if let origin = feeder.firstAudioDate { accumulator.startedAt = origin }
        if let segment = accumulator.update(startSeconds: result.range.start.seconds,
            text: String(result.text.characters), isFinal: result.isFinal) { output(segment) }
    }
    private func receiveFailure(_ error: Error, token: UUID) {
        guard run == token else { return }
        failure(CaptureFailure(error: error, prefix: "Local transcription stopped: "))
    }
    func stop() async {
        guard run != nil || analyzer != nil || leasedLocale != nil else { return }
        feeder.finish()
        let analyzer = self.analyzer; self.analyzer = nil
        if let analyzer {
            // Normal Stop drains accepted audio and lets the model finalize it.
            // Cancellation is the bounded fallback if a service fails to finish.
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
                await analyzer.cancelAndFinishNow()
            }
            do { try await analyzer.finalizeAndFinishThroughEndOfInput() }
            catch { await analyzer.cancelAndFinishNow() }
            timeout.cancel()
        }
        await results?.value
        results = nil; run = nil
        for partial in accumulator.finalizePartials() { output(partial) }
        let locale = leasedLocale; leasedLocale = nil
        if let locale { await SpeechLanguageAssets.shared.release(locale) }
        progress(nil)
    }
}
