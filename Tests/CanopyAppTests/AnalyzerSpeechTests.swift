import AVFoundation
import Foundation
import Testing
import CanopyCore
@testable import CanopyApp

struct AnalyzerSpeechTests {
    @Test func meetingAudioIsTheDefaultAndDoesNotIncludeMicrophone() {
        #expect(CaptureMode.defaultMode == .system)
        #expect(CaptureMode.defaultMode.includesSystem && !CaptureMode.defaultMode.includesMic)
        if SpeechBackend.current == .analyzer { #expect(!MeetingPermission.availableCases.contains(.speechRecognition)) }
    }
    @Test func revisionsAndFinalizationRetainIdentityAndAudioTime() throws {
        let start = Date(timeIntervalSince1970: 1000)
        var accumulator = AnalyzerTranscriptAccumulator(source: .system, startedAt: start)
        let partialResult = accumulator.update(startSeconds: 2.5, text: "The meeting", isFinal: false)
        let partial = try #require(partialResult)
        let finalResult = accumulator.update(startSeconds: 2.5, text: "The meeting starts at nine.", isFinal: true)
        let final = try #require(finalResult)
        #expect(partial.id == final.id && partial.timestamp == final.timestamp)
        #expect(final.timestamp == start.addingTimeInterval(2.5) && final.source == .system)
        let oldRevision = accumulator.update(startSeconds: 2.5, text: "An old revision", isFinal: false)
        #expect(oldRevision == nil)
        let nextResult = accumulator.update(startSeconds: 6, text: "Next sentence", isFinal: false)
        let next = try #require(nextResult)
        let stopped = accumulator.finalizePartials()
        #expect(stopped.count == 1 && stopped[0].id == next.id && stopped[0].isFinal)
        let noPartials = accumulator.finalizePartials()
        #expect(noPartials.isEmpty)
        let invalid = accumulator.update(startSeconds: .nan, text: "Invalid time", isFinal: false)
        #expect(invalid == nil)
    }
    @Test func volatileTimeRevisionsUpdateOneRowAndFinalTextReusesIt() throws {
        var accumulator = AnalyzerTranscriptAccumulator(source: .system)
        let firstValue = accumulator.update(startSeconds: 2, text: "One", isFinal: false)
        let first = try #require(firstValue)
        let revisedValue = accumulator.update(startSeconds: 2.03, text: "One sentence", isFinal: false)
        let revised = try #require(revisedValue)
        let finalValue = accumulator.update(startSeconds: 2.05, text: "One sentence.", isFinal: true)
        let final = try #require(finalValue)
        #expect(first.id == revised.id && first.id == final.id)
        let pending = accumulator.finalizePartials()
        #expect(pending.isEmpty)
    }

    @Test func audioFeederConvertsStereoToMonoAndFinishesItsSequence() async throws {
        guard #available(macOS 26.0, *) else { return }
        let sourceFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: true))
        let target = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 4800)); source.frameLength = 4800
        let pointer = source.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        for index in 0..<9600 { pointer[index] = index % 2 == 1 ? 0.2 : 0 }
        let feeder = AnalyzerAudioFeeder()
        let inputs = feeder.configure(format: target, failure: { Issue.record($0) })
        feeder.append(source); feeder.finish()
        var received = 0
        for await input in inputs {
            #expect(input.buffer.format == target && input.buffer.frameLength > 0)
            #expect(AudioTapPCM.hasSignal(input.buffer)); received += 1
        }
        #expect(received == 1)
        feeder.append(source) // A stopped feeder must not retain or process this input.
    }
}

private final class FixtureSpeechCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [UUID: TranscriptSegment] = [:]
    private var failures: [String] = []
    func receive(_ segment: TranscriptSegment) { lock.withLock { segments[segment.id] = segment } }
    func fail(_ error: CaptureFailure) { lock.withLock { failures.append(error.localizedDescription) } }
    var text: String { lock.withLock { segments.values.map(\.text).joined(separator: " ") } }
    var errors: [String] { lock.withLock { failures } }
}

struct LocalSpeechFixtureTests {
    /// Opt-in integration test: generated audio only; no mic or desktop capture.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_SPEECH_FIXTURE"] != nil))
    func generatedAudioCanBeTranscribedByTheModernLocalEngine() async throws {
        guard #available(macOS 26.0, *) else { return }
        let path = try #require(ProcessInfo.processInfo.environment["CANOPY_SPEECH_FIXTURE"])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let collector = FixtureSpeechCollector()
        let channel = AnalyzerSpeechChannel(source: .system, locale: "en-US", output: { collector.receive($0) },
            failure: { collector.fail($0) }, progress: { preparation in
                if let preparation { print(preparation.message) }
            })
        try await channel.start()
        while file.framePosition < file.length {
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048))
            try file.read(into: buffer)
            channel.append(buffer)
            try await Task.sleep(for: .milliseconds(20))
        }
        for _ in 0..<100 {
            if collector.text.lowercased().contains("project") || !collector.errors.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        await channel.stop()
        #expect(collector.errors.isEmpty)
        #expect(collector.text.lowercased().contains("meeting") && collector.text.lowercased().contains("project") && collector.text.lowercased().contains("tomorrow"))
    }
}

@MainActor
private final class GeneratedFileMeetingInput: SystemAudioCapturing {
    let file: AVAudioFile
    var finished = false
    private var feeding: Task<Void, Never>?
    private var delivery: AudioTapDelivery?
    init(file: AVAudioFile) { self.file = file }
    func start(output: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (CaptureFailure) -> Void,
               notice: @escaping (String?) -> Void, activity: @escaping (Double) -> Void) throws {
        let delivery = AudioTapDelivery(format: file.processingFormat, output: output, failure: failure, notice: notice, activity: activity)
        self.delivery = delivery
        feeding = Task {
            do {
                while file.framePosition < file.length && !Task.isCancelled {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2048) else { throw CaptureError.invalidMicFormat }
                    try file.read(into: buffer); delivery.accept(buffer.audioBufferList)
                    try await Task.sleep(for: .milliseconds(20))
                }
                finished = true
            } catch { if !Task.isCancelled { failure(CaptureFailure(error: error)) } }
        }
    }
    func stop() { feeding?.cancel(); feeding = nil; delivery?.stop(); delivery = nil }
}

@MainActor
private final class FixtureScreenshotSettings: SystemScreenshotManaging {
    func begin(in directory: URL) throws { Issue.record("Generated-audio tests must not change screenshot settings") }
    func end() throws { }
}

private struct FixtureSecrets: SecretStoring {
    func read(_ account: String) throws -> String { "" }
    func write(_ value: String, account: String) throws { Issue.record("Generated-audio tests must not change credentials") }
}

@MainActor
struct MeetingPipelineFixtureTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CANOPY_SPEECH_FIXTURE"] != nil))
    func generatedMeetingAudioTravelsThroughCaptureStateAndSavedTranscript() async throws {
        guard #available(macOS 26.0, *), SpeechBackend.current == .analyzer else { return }
        let path = try #require(ProcessInfo.processInfo.environment["CANOPY_SPEECH_FIXTURE"])
        let input = GeneratedFileMeetingInput(file: try AVAudioFile(forReading: URL(fileURLWithPath: path)))
        let capture = NativeMeetingCapture(systemAudioFactory: { input })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyMeetingFixture-\(UUID())")
        let repository = FileLibraryRepository(directory: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AppState(repository: repository, secrets: FixtureSecrets(), meetingCapture: capture, systemScreenshots: FixtureScreenshotSettings())
        await state.startMeeting(title: "Generated audio", mode: .system)
        #expect(state.recording && state.meetingCaptureMode == .system)
        for _ in 0..<150 {
            if input.finished && state.selectedMeeting?.transcript.lowercased().contains("project") == true { break }
            if !state.recording { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(state.meetingAudioLevel != nil)
        await state.stopMeeting()
        let meeting = try #require(repository.load().meetings.first)
        #expect(meeting.transcript.lowercased().contains("meeting"))
        #expect(meeting.transcript.lowercased().contains("project"))
        #expect(meeting.transcript.lowercased().contains("tomorrow"))
        #expect(meeting.segments.allSatisfy { $0.source == .system && $0.isFinal })
        #expect(meeting.endedAt != nil && !state.recording && state.meetingAudioLevel == nil)
        await state.shutdown()
    }
}
