import AVFoundation
import CoreAudio
import Foundation
import Testing
import CanopyCore
@testable import CanopyApp

struct AudioTapPCMTests {
    @Test(arguments: [true, false]) func callbackBufferIsCopiedWithItsChannelLayout(interleaved: Bool) throws {
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: interleaved))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)); source.frameLength = 32
        let list = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        for buffer in list {
            let data = try #require(buffer.mData).assumingMemoryBound(to: Float.self)
            for i in 0..<Int(buffer.mDataByteSize) / 4 { data[i] = Float(i + 1) / 100 }
        }
        let copied = try #require(AudioTapPCM.copy(source.audioBufferList, format: format))
        #expect(copied.frameLength == 32 && copied.format == format)
        let target = UnsafeMutableAudioBufferListPointer(copied.mutableAudioBufferList)
        for i in list.indices {
            #expect(list[i].mData != target[i].mData)
            #expect(memcmp(list[i].mData!, target[i].mData!, Int(list[i].mDataByteSize)) == 0)
            memset(list[i].mData!, 0, Int(list[i].mDataByteSize))
            #expect(target[i].mData!.assumingMemoryBound(to: Float.self)[0] == 0.01)
        }
    }

    @Test func mismatchedEmptyAndOversizedBuffersAreRejected() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        var malformed = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 0, mData: source.mutableAudioBufferList.pointee.mBuffers.mData))
        func rejected(_ targetFormat: AVAudioFormat) -> Bool {
            withUnsafePointer(to: &malformed) { AudioTapPCM.copy($0, format: targetFormat) == nil }
        }
        #expect(rejected(format))
        malformed.mBuffers.mDataByteSize = 3
        #expect(rejected(format))
        malformed.mBuffers.mDataByteSize = 300_000
        #expect(rejected(format))
        malformed.mBuffers.mDataByteSize = 128
        let stereo = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        #expect(rejected(stereo))
        malformed.mBuffers.mData = nil
        #expect(rejected(format))
    }

    @Test func silenceHintDoesNotStopCaptureAndClearsWhenSoundArrives() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)); buffer.frameLength = 32
        memset(buffer.mutableAudioBufferList.pointee.mBuffers.mData!, 0, 128)
        var outputs = 0, failures = 0
        var notices: [String?] = []
        let delivery = AudioTapDelivery(format: format, output: { _ in outputs += 1 }, failure: { _ in failures += 1 }, notice: { notices.append($0) })
        delivery.accept(buffer.audioBufferList)
        delivery.checkForSound(); delivery.checkForSound()
        #expect(outputs == 1 && failures == 0 && notices.count == 1)
        buffer.floatChannelData![0][0] = 0.001
        delivery.accept(buffer.audioBufferList)
        #expect(outputs == 2 && notices.count == 2 && notices[1] == nil)
        delivery.stop()
        delivery.accept(buffer.audioBufferList); delivery.checkForSound(); delivery.fail("Late callback")
        #expect(outputs == 2 && failures == 0 && notices.count == 2)
    }

    @Test func repeatedLayoutChangesProduceOnlyOneFailure() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var input = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 3, mData: nil))
        var failures = 0
        let delivery = AudioTapDelivery(format: format, output: { _ in Issue.record("Malformed input was delivered") }, failure: { _ in failures += 1 }, notice: { _ in })
        withUnsafePointer(to: &input) { delivery.accept($0); delivery.accept($0) }
        delivery.fail("Device changed")
        #expect(failures == 1)
    }

    @Test func halErrorsDoNotPretendToKnowTheTCCChoice() {
        let denied = AudioTapError(operation: "start", status: kAudioDevicePermissionsError)
        #expect(CaptureError.permission(for: denied) == nil)
        #expect(CaptureError.message(for: denied).contains("Core Audio error"))
        let unavailable = AudioTapError(operation: "start", status: kAudioHardwareBadDeviceError)
        #expect(CaptureError.permission(for: unavailable) == nil)
        #expect(CaptureError.message(for: unavailable).contains("Core Audio error"))
    }
}

@MainActor
struct AudioOnlyPermissionTests {
    @Test func audioOnlyStatusNeverReadsTheScreenPermissionOrRemembersItsRefusal() async throws {
        let suite = "AudioOnlyPermission-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "meetingPermissions.screenRequested.signer")
        var screenReads = 0
        let permissions = NativeMeetingPermissions(defaults: defaults, screenAccess: { screenReads += 1; return false }, requestIdentity: "signer")
        #expect(permissions.status(for: .systemAudio) == .onStart)
        permissions.recordDenial(.systemAudio)
        #expect(await permissions.request(.systemAudio) == .onStart)
        #expect(screenReads == 0)
        if #available(macOS 14.2, *) { #expect(MeetingPermission.availableCases == (SpeechBackend.current == .analyzer ? [.systemAudio, .microphone] : [.systemAudio, .microphone, .speechRecognition])) }
    }

    @Test func openingAudioSettingsDoesNotStartOrRequestCapture() async throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent("AudioOnlySettings-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        let permissions = FakeMeetingPermissions(); permissions.statuses[.systemAudio] = .onStart
        let state = AppState(repository: repository, permissionService: permissions)
        await state.requestMeetingPermission(.systemAudio)
        #expect(permissions.settings == [.systemAudio] && permissions.requests.isEmpty)
        #expect(!state.recording && state.library.meetings.isEmpty && state.permissionIssue == nil)
        #expect(state.banner?.contains("System Audio Recording Only") == true)
        await state.shutdown()
    }
}

struct MeetingInputActivityTests {
    @Test func inputActivityDistinguishesNoCallbacksFromSilentInputAndReportsAtMostFiveTimesPerSecond() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32)); buffer.frameLength = 32
        memset(buffer.mutableAudioBufferList.pointee.mBuffers.mData!, 0, 128)
        var time = 0.0, levels: [Double] = [], hints: [String?] = []
        let noInput = AudioTapDelivery(format: format, output: { _ in }, failure: { Issue.record($0) }, notice: { hints.append($0) })
        noInput.checkForSound()
        #expect(hints[0]?.contains("not delivering samples") == true)
        let delivery = AudioTapDelivery(format: format, output: { _ in }, failure: { Issue.record($0) }, notice: { hints.append($0) },
                                        activity: { levels.append($0) }, now: { time })
        delivery.accept(buffer.audioBufferList); delivery.checkForSound()
        #expect(levels == [0] && hints.last.flatMap { $0 }?.contains("Connected") == true)
        buffer.floatChannelData![0][0] = 0.25
        time = 0.1; delivery.accept(buffer.audioBufferList)
        #expect(levels == [0] && hints.last! == nil)
        time = 0.3; delivery.accept(buffer.audioBufferList)
        #expect(levels == [0, 0.25])
        delivery.stop(); time = 1; delivery.accept(buffer.audioBufferList)
        #expect(levels.count == 2)
    }
    @Test func levelHandlesNegativePeaksIntegerMinimumAndNonFiniteSamples() throws {
        let floats = try #require(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!, frameCapacity: 3)); floats.frameLength = 3
        floats.floatChannelData![0][0] = .nan; floats.floatChannelData![0][1] = .infinity; floats.floatChannelData![0][2] = -0.7
        #expect(abs(AudioTapPCM.level(floats) - 0.7) < 0.00001)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: false))
        let integers = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)); integers.frameLength = 1
        integers.int16ChannelData![0][0] = .min
        #expect(AudioTapPCM.level(integers) == 1)
    }
}
