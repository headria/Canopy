import AppKit
import UniformTypeIdentifiers
import ImageIO

@MainActor
protocol CaptureOpening {
    func openForEditing(_ url: URL) async throws
}


struct NativePreviewOpener: CaptureOpening {
    func openForEditing(_ url: URL) async throws {
        guard let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: preview, configuration: configuration)
    }
}

/// An immutable drag copy. A receiver can finish reading it after the shelf image
/// is edited or discarded; no temporary export is left on the user's Desktop.
struct CaptureDragSnapshot: Sendable {
    let png: Data
    let filename: String

    var tiff: Data? { NSBitmapImageRep(data: png)?.representation(using: .tiff, properties: [:]) }

    static func read(from url: URL, title: String) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size < 40_000_000 else { throw CocoaError(.fileReadTooLarge) }
        let data = try Data(contentsOf: url)
        guard data.count < 40_000_000, let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == UTType.png.identifier else { throw CocoaError(.fileReadCorruptFile) }
        return Self(png: data, filename: exportFilename(title))
    }

    static func exportFilename(_ title: String) -> String {
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        var name = title.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if name.lowercased().hasSuffix(".png") { name.removeLast(4) }
        var result = ""
        for character in name {
            guard result.utf8.count + String(character).utf8.count <= 180 else { break }
            result.append(character)
        }
        return (result.isEmpty ? "Screenshot" : result) + ".png"
    }

    func write(to destination: URL) throws {
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".Canopy-drag-\(UUID())")
        defer { try? files.removeItem(at: staging) }
        try png.write(to: staging, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.path)
        // Same-folder move publishes a complete file and refuses an existing name.
        try files.moveItem(at: staging, to: destination)
    }
}

/// Native image formats serve editors and message composers; a promised PNG file
/// serves Finder and apps that accept file attachments rather than image bytes.
@MainActor
final class CaptureDragProvider: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    nonisolated let snapshot: CaptureDragSnapshot
    private let writes = OperationQueue()
    nonisolated let transferDirectory: URL
    let transferURL: URL

    static var transfersDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("Canopy Drag Transfers", isDirectory: true) }
    static func cleanStaleTransfers() {
        let files = FileManager.default
        guard let children = try? files.contentsOfDirectory(at: transfersDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        for url in children {
            guard UUID(uuidString: url.lastPathComponent) != nil,
                  let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  Date().timeIntervalSince(created) > 300 else { continue }
            try? files.removeItem(at: url)
        }
    }

    init(snapshot: CaptureDragSnapshot) throws {
        self.snapshot = snapshot
        Self.cleanStaleTransfers()
        transferDirectory = Self.transfersDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        transferURL = transferDirectory.appendingPathComponent(snapshot.filename)
        try FileManager.default.createDirectory(at: transferDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do { try snapshot.write(to: transferURL) }
        catch { try? FileManager.default.removeItem(at: transferDirectory); throw error }
        super.init()
        fileType = UTType.png.identifier
        delegate = self
        writes.name = "Canopy drag copies"; writes.qualityOfService = .userInitiated
        writes.maxConcurrentOperationCount = 1
    }
    deinit { try? FileManager.default.removeItem(at: transferDirectory) }
    func removeTransfer() { try? FileManager.default.removeItem(at: transferDirectory) }
    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.writableTypes(for: pasteboard)
    }
    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return transferURL.absoluteString }
        if type == .png { return snapshot.png }
        if type == .tiff { return snapshot.tiff }
        return super.pasteboardPropertyList(forType: type)
    }
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { snapshot.filename }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        do { try snapshot.write(to: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { writes }
}

/// File-promise delegates are weak. Keep successful drag writers alive briefly for
/// receivers that request the file after the native dragging session has ended.
@MainActor
enum CaptureDragLifetime {
    private static var pending: [UUID: CaptureDragProvider] = [:]
    static func retainForReceiver(_ provider: CaptureDragProvider) {
        let id = UUID(); pending[id] = provider
        Task {
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            provider.removeTransfer()
            pending[id] = nil
        }
    }
}
