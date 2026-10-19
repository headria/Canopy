import AppKit
import CanopyCore
import Vision

protocol ScreenshotServing {
    func capture(to url: URL) async throws -> Bool
    func importImage(from source: URL, to destination: URL) throws
    func recognizeText(at url: URL) async throws -> String
}

struct NativeScreenshotService: ScreenshotServing {
    func capture(to url: URL) async throws -> Bool {
        #if CANOPY_APP_STORE
        return try await StoreRegionScreenshot.capture(to: url)
        #else
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", "-t", "png", url.path]
            process.terminationHandler = { process in
                let exists = FileManager.default.fileExists(atPath: url.path)
                // Escape cancels selection without adding an empty card.
                if exists { continuation.resume(returning: true) }
                else if process.terminationStatus == 0 || process.terminationStatus == 1 { continuation.resume(returning: false) }
                else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        #endif
    }
    func importImage(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)
        guard data.count < 40_000_000, let representation = NSBitmapImageRep(data: data),
              let png = representation.representation(using: .png, properties: [:]) else { throw CocoaError(.fileReadCorruptFile) }
        try png.write(to: destination, options: .atomic)
    }
    func recognizeText(at url: URL) async throws -> String {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            try VNImageRequestHandler(url: url).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}

enum ScreenshotLocation {
    static var systemDirectory: URL {
        #if !CANOPY_APP_STORE
        if let location = try? MacScreenshotPreferences().read().effectiveScreenshotLocation, !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        #endif
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
    }
}

@MainActor
protocol ScreenshotWatching: AnyObject {
    func start(directory: URL, includeExisting: Bool, onCapture: @escaping (URL) async throws -> Void, onError: @escaping (ScreenshotWatchIssue) -> Void) async throws
    func stop()
}

struct ScreenshotWatchIssue {
    let message: String
    let stopped: Bool
}

/// Polls off the main thread, without requiring a running Spotlight index or changing
/// the system screenshot destination. A generation token retires old scans on restart.
@MainActor
final class ScreenshotWatcher: ScreenshotWatching {
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var discovery = ScreenshotDiscovery()
    private let interval: UInt64
    private let acceptsAllImages: Bool
    init(interval: UInt64 = 700_000_000, acceptsAllImages: Bool = false) { self.interval = interval; self.acceptsAllImages = acceptsAllImages }

    func start(directory: URL, includeExisting: Bool = false, onCapture: @escaping (URL) async throws -> Void, onError: @escaping (ScreenshotWatchIssue) -> Void) async throws {
        stop()
        let token = generation
        let existing = try await Self.scan(directory, includeOtherCaptures: includeExisting, acceptsAllImages: acceptsAllImages)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        discovery.begin(with: includeExisting ? [] : existing)
        task = Task { [weak self] in
            var reportedError: String?
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                do {
                    try await Task.sleep(nanoseconds: self.interval)
                    let files = try await Self.scan(directory, includeOtherCaptures: includeExisting, acceptsAllImages: self.acceptsAllImages)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    for file in self.discovery.ready(in: files) {
                        // Screen recordings write over a much longer period. Leave
                        // them in place until writes have been quiet for five seconds.
                        if ["mov", "mp4"].contains(file.url.pathExtension.lowercased()), Date().timeIntervalSince(file.modifiedAt) < 5 { continue }
                        do {
                            try await onCapture(file.url)
                            guard self.generation == token else { return }
                            self.discovery.markImported(file)
                            reportedError = nil
                        } catch is CancellationError { return }
                        catch {
                            let message = "Could not import a screenshot: \(error.localizedDescription)"
                            if reportedError != message { reportedError = message; onError(ScreenshotWatchIssue(message: message, stopped: false)) }
                        }
                    }
                } catch is CancellationError { return }
                catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    onError(ScreenshotWatchIssue(message: "Screenshot detection cannot read \(directory.lastPathComponent): \(error.localizedDescription). Choose the folder again to grant access.", stopped: true))
                    return
                }
            }
        }
    }
    func stop() { generation = UUID(); task?.cancel(); task = nil; discovery = ScreenshotDiscovery() }

    private nonisolated static func scan(_ directory: URL, includeOtherCaptures: Bool, acceptsAllImages: Bool) async throws -> [ScreenshotFileSnapshot] {
        try await Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
            return files.compactMap { url in
                let otherCapture = includeOtherCaptures && ["mov", "mp4", "pdf"].contains(url.pathExtension.lowercased())
                guard (ScreenshotClassification.imageExtensions.contains(url.pathExtension.lowercased()) || otherCapture),
                      let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
                let knownScreenshot = includeOtherCaptures || acceptsAllImages || ScreenshotClassification.isScreenshot(url: url, metadataFlag: false)
                let metadataFlag: Bool
                if !knownScreenshot, let item = MDItemCreate(nil, url.path as CFString) {
                    metadataFlag = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue == true
                } else { metadataFlag = false }
                return ScreenshotFileSnapshot(url: url, size: values.fileSize ?? 0, modifiedAt: values.contentModificationDate ?? .distantPast,
                                              // The owned inbox accepts every supported image, including
                                              // localized or custom screenshot names without Spotlight.
                                              isScreenshot: knownScreenshot || metadataFlag)
            }
        }.value
    }
}
