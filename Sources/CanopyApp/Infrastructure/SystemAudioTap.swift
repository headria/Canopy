import AVFoundation
import CoreAudio

/// Capture lifetime belongs to the main actor; HAL callbacks receive only immutable
/// format/delivery closures and copy their borrowed input before returning.
@MainActor
protocol SystemAudioCapturing: AnyObject {
    func start(output: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (CaptureFailure) -> Void, notice: @escaping (String?) -> Void, activity: @escaping (Double) -> Void) throws
    func stop()
}

struct AudioTapError: LocalizedError {
    let operation: String
    let status: OSStatus
    var errorDescription: String? {
        return "Meeting audio could not \(operation) (Core Audio error \(status)). Check your audio output in System Settings → Sound and try again."
    }
    // HAL ownership/permission errors do not establish the user's TCC choice.
    var permission: MeetingPermission? { nil }
    static func check(_ status: OSStatus, operation: String) throws {
        if status != noErr { throw AudioTapError(operation: operation, status: status) }
    }
}

/// Copies both interleaved and planar PCM without retaining HAL-owned memory.
/// A changing/malformed layout is rejected before any bytes are copied.
enum AudioTapPCM {
    /// Normalized peak for the input indicator; no samples leave this process.
    static func level(_ buffer: AVAudioPCMBuffer) -> Double {
        var peak = 0.0
        for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = audio.mData else { continue }
            func scan<T>(_ pointer: UnsafePointer<T>, count: Int, value: (T) -> Double) {
                for sample in UnsafeBufferPointer(start: pointer, count: count) {
                    let amplitude = abs(value(sample))
                    if amplitude.isFinite { peak = max(peak, amplitude) }
                }
            }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32: scan(data.assumingMemoryBound(to: Float.self), count: Int(audio.mDataByteSize) / 4, value: { Double($0) })
            case .pcmFormatFloat64: scan(data.assumingMemoryBound(to: Double.self), count: Int(audio.mDataByteSize) / 8, value: { $0 })
            case .pcmFormatInt16: scan(data.assumingMemoryBound(to: Int16.self), count: Int(audio.mDataByteSize) / 2, value: { Double($0) / 32768 })
            case .pcmFormatInt32: scan(data.assumingMemoryBound(to: Int32.self), count: Int(audio.mDataByteSize) / 4, value: { Double($0) / 2147483648 })
            default: break
            }
        }
        return min(1, peak)
    }
    static func copy(_ input: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let bytesPerFrame = Int(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0, !source.isEmpty else { return nil }
        let bytes = Int(source[0].mDataByteSize)
        guard bytes > 0, bytes % bytesPerFrame == 0 else { return nil }
        let frames = bytes / bytesPerFrame
        guard frames <= 65_536, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let target = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        guard source.count == target.count else { return nil }
        for index in source.indices {
            guard source[index].mDataByteSize == target[index].mDataByteSize,
                  source[index].mNumberChannels == target[index].mNumberChannels,
                  source[index].mData != nil, target[index].mData != nil else { return nil }
        }
        for index in source.indices {
            memcpy(target[index].mData!, source[index].mData!, Int(source[index].mDataByteSize))
        }
        return buffer
    }

    static func hasSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audio in buffers {
            guard let data = audio.mData else { continue }
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32:
                if UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(audio.mDataByteSize) / 4).contains(where: { $0.isFinite && $0 != 0 }) { return true }
            case .pcmFormatFloat64:
                if UnsafeBufferPointer(start: data.assumingMemoryBound(to: Double.self), count: Int(audio.mDataByteSize) / 8).contains(where: { $0.isFinite && $0 != 0 }) { return true }
            case .pcmFormatInt16:
                if UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: Int(audio.mDataByteSize) / 2).contains(where: { $0 != 0 }) { return true }
            case .pcmFormatInt32:
                if UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int32.self), count: Int(audio.mDataByteSize) / 4).contains(where: { $0 != 0 }) { return true }
            default: break
            }
        }
        return false
    }
}

/// Confined to the HAL delivery queue. A silent input is a hint, never a
/// permission diagnosis; it cannot stop a quiet meeting. Stop disables late callbacks.
final class AudioTapDelivery {
    let format: AVAudioFormat
    private let output: (AVAudioPCMBuffer) -> Void
    private let failure: (CaptureFailure) -> Void
    private let notice: (String?) -> Void
    private let activity: (Double) -> Void
    private let now: () -> Double
    private var lastActivity = -Double.infinity
    private var receivedFrames = false
    private var active = true
    private var failed = false
    private var receivedSignal = false
    private var showedNotice = false
    init(format: AVAudioFormat, output: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (CaptureFailure) -> Void, notice: @escaping (String?) -> Void,
         activity: @escaping (Double) -> Void = { _ in }, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.format = format; self.output = output; self.failure = failure; self.notice = notice
        self.activity = activity; self.now = now
    }
    func accept(_ input: UnsafePointer<AudioBufferList>) {
        guard active, !failed else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard !buffers.isEmpty, buffers[0].mDataByteSize > 0 else { return }
        guard let buffer = AudioTapPCM.copy(input, format: format) else {
            fail("The meeting audio format changed. Start listening again to use the new output.")
            return
        }
        receivedFrames = true
        let level = AudioTapPCM.level(buffer)
        if !receivedSignal, level > 0.00001 {
            receivedSignal = true
            if showedNotice { notice(nil) }
        }
        let time = now()
        if time - lastActivity >= 0.2 { lastActivity = time; activity(level) }
        output(buffer)
    }
    func checkForSound() {
        guard active, !failed, !receivedSignal, !showedNotice else { return }
        showedNotice = true
        notice(receivedFrames
            ? "Connected, but no meeting sound is arriving. Make sure you can hear the call. If sound is audible, check System Audio Recording Only access for Canopy, then stop and start listening again."
            : "The audio connection is not delivering samples. Stop and start listening again. If it continues, check your audio output and Canopy's System Audio Recording Only access.")
    }
    func fail(_ message: String) {
        guard active, !failed else { return }
        failed = true; failure(CaptureFailure(message))
    }
    func stop() { active = false }
}

/// macOS 14.2+ offers a system-audio permission separate from screen recording.
/// A private, unmuted tap preserves normal playback and never captures screen pixels.
@available(macOS 14.2, *)
@MainActor
final class SystemAudioTap: SystemAudioCapturing {
    /// Nil is normal meeting output; a non-nil list is used only by the
    /// generated-audio diagnostic to capture its dedicated playback process.
    private let onlyProcesses: [AudioObjectID]?
    private var tap: AudioObjectID = kAudioObjectUnknown
    private var device: AudioObjectID = kAudioObjectUnknown
    private var io: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.canopy.audio-tap")
    private typealias Listener = @convention(block) (UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, Listener)] = []
    private var delivery: AudioTapDelivery?
    private var soundCheck: DispatchWorkItem?
    init(onlyProcesses: [AudioObjectID]? = nil) { self.onlyProcesses = onlyProcesses }

    func start(output: @escaping (AVAudioPCMBuffer) -> Void, failure: @escaping (CaptureFailure) -> Void, notice: @escaping (String?) -> Void, activity: @escaping (Double) -> Void) throws {
        stop()
        do {
            // An app that has never produced audio may not have a HAL process
            // object yet. Canopy does not play sounds; macOS 26+ also excludes its bundle ID.
            var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
            var pid = getpid()
            var process: AudioObjectID = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioObjectID>.size)
            try AudioTapError.check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process), operation: "identify this app")
            let description: CATapDescription
            if let onlyProcesses { description = CATapDescription(monoMixdownOfProcesses: onlyProcesses) }
            else {
                description = CATapDescription(monoGlobalTapButExcludeProcesses: process == kAudioObjectUnknown ? [] : [process])
                if #available(macOS 26.0, *) { description.bundleIDs = [Bundle.main.bundleIdentifier ?? "com.canopy.desktop"] }
            }
            description.name = "Canopy meeting audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try AudioTapError.check(AudioHardwareCreateProcessTap(description, &tap), operation: "create its audio tap")

            address = Self.address(kAudioTapPropertyFormat)
            var asbd = AudioStreamBasicDescription()
            size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try AudioTapError.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd), operation: "read its audio format")
            guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
                  let format = AVAudioFormat(streamDescription: &asbd) else {
                throw CaptureFailure("The meeting audio format is unavailable. Check your audio output and try again.")
            }

            address = Self.address(kAudioTapPropertyUID)
            var tapUID: CFString = "" as CFString
            size = UInt32(MemoryLayout<CFString>.size)
            let uidStatus = withUnsafeMutablePointer(to: &tapUID) { pointer in
                AudioObjectGetPropertyData(tap, &address, 0, nil, &size, pointer)
            }
            try AudioTapError.check(uidStatus, operation: "read its audio tap identifier")
            let config: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Canopy meeting audio",
                kAudioAggregateDeviceUIDKey: "com.canopy.audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                // Begin input immediately, including when a meeting is already
                // playing. No physical input device or microphone is attached.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceSubDeviceListKey: [],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: false]]
            ]
            try AudioTapError.check(AudioHardwareCreateAggregateDevice(config as CFDictionary, &device), operation: "create its audio input")
            if #available(macOS 15.0, *) {
                try AudioHardwareAggregateDevice(id: device).setClockSource(AudioHardwareTap(id: tap))
            }
            let (inputStream, inputFormat) = try Self.inputStream(device)
            let delivery = AudioTapDelivery(format: inputFormat, output: output, failure: failure, notice: notice, activity: activity)
            self.delivery = delivery
            try AudioTapError.check(AudioDeviceCreateIOProcIDWithBlock(&io, device, queue, Self.ioBlock(delivery)), operation: "prepare its audio input")

            // Fail clearly if the device disappears or its format changes, instead
            // of feeding incompatible buffers to the speech recognizer.
            try watch(tap, selector: kAudioTapPropertyFormat, listener: Self.formatListener(tap, selector: kAudioTapPropertyFormat, expected: format, delivery: delivery))
            try watch(inputStream, selector: kAudioStreamPropertyVirtualFormat, listener: Self.formatListener(inputStream, selector: kAudioStreamPropertyVirtualFormat, expected: inputFormat, delivery: delivery))
            try watch(device, selector: kAudioDevicePropertyNominalSampleRate, listener: Self.rateListener(device, expected: inputFormat.sampleRate, delivery: delivery))
            try watch(device, selector: kAudioDevicePropertyDeviceIsAlive, listener: Self.aliveListener(device, delivery: delivery))
            // macOS owns the audio-only authorization prompt at this operation.
            // We never perform a recording probe while reading permission status.
            try AudioTapError.check(AudioDeviceStart(device, io), operation: "start")
            let check = Self.soundCheck(delivery)
            soundCheck = check
            queue.asyncAfter(deadline: .now() + 12, execute: check)
        } catch {
            stop()
            throw error
        }
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func inputStream(_ device: AudioObjectID) throws -> (AudioObjectID, AVAudioFormat) {
        var address = Self.address(kAudioDevicePropertyStreams); address.mScope = kAudioDevicePropertyScopeInput
        var size: UInt32 = 0
        try AudioTapError.check(AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size), operation: "read its input streams")
        guard size == MemoryLayout<AudioObjectID>.size else { throw CaptureFailure("The meeting audio input has an unexpected stream layout.") }
        var stream: AudioObjectID = kAudioObjectUnknown
        try AudioTapError.check(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &stream), operation: "read its input stream")
        address = Self.address(kAudioStreamPropertyVirtualFormat)
        var asbd = AudioStreamBasicDescription(); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try AudioTapError.check(AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &asbd), operation: "read its input format")
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate > 0, asbd.mChannelsPerFrame > 0,
              let format = AVAudioFormat(streamDescription: &asbd) else { throw CaptureFailure("The meeting audio input format is unavailable.") }
        return (stream, format)
    }

    nonisolated private static func soundCheck(_ delivery: AudioTapDelivery) -> DispatchWorkItem {
        DispatchWorkItem { delivery.checkForSound() }
    }
    nonisolated private static func ioBlock(_ delivery: AudioTapDelivery) -> AudioDeviceIOBlock {
        { _, input, _, _, _ in delivery.accept(input) }
    }
    nonisolated private static func formatListener(_ object: AudioObjectID, selector: AudioObjectPropertySelector, expected: AVAudioFormat, delivery: AudioTapDelivery) -> Listener {
        { _, _ in
            var address = Self.address(selector)
            var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &asbd)
            if status != noErr || AVAudioFormat(streamDescription: &asbd) != expected {
                delivery.fail("Your meeting audio format changed. Start listening again to reconnect.")
            }
        }
    }
    nonisolated private static func rateListener(_ device: AudioObjectID, expected: Double, delivery: AudioTapDelivery) -> Listener {
        { _, _ in
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            var rate: Float64 = 0; var size = UInt32(MemoryLayout<Float64>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) != noErr || abs(rate - expected) > 0.01 {
                delivery.fail("Your meeting audio sample rate changed. Start listening again to reconnect.")
            }
        }
    }
    nonisolated private static func aliveListener(_ device: AudioObjectID, delivery: AudioTapDelivery) -> Listener {
        { _, _ in
            var address = Self.address(kAudioDevicePropertyDeviceIsAlive)
            var alive: UInt32 = 0; var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) != noErr || alive == 0 {
                delivery.fail("Your meeting audio output became unavailable. Start listening again to reconnect.")
            }
        }
    }
    private func watch(_ object: AudioObjectID, selector: AudioObjectPropertySelector, listener: @escaping Listener) throws {
        var address = Self.address(selector)
        try AudioTapError.check(AudioObjectAddPropertyListenerBlock(object, &address, queue, listener), operation: "monitor its audio input")
        listeners.append((object, address, listener))
    }

    func stop() {
        soundCheck?.cancel(); soundCheck = nil
        if let delivery { queue.sync { delivery.stop() } }; delivery = nil
        for (object, var address, listener) in listeners {
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
        }
        listeners.removeAll()
        if let io {
            AudioDeviceStop(device, io)
            AudioDeviceDestroyIOProcID(device, io)
        }
        io = nil
        if device != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(device); device = kAudioObjectUnknown }
        if tap != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tap); tap = kAudioObjectUnknown }
    }
}
