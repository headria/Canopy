import CryptoKit
import Foundation

/// Private working copies keep screenshot editing separate from shelf storage.
/// Retain legacy paths and fingerprints to recover previously saved Preview edits.
struct CaptureEditStore {
    let directory: URL

    init(libraryDirectory: URL) {
        #if CANOPY_APP_STORE
        directory = libraryDirectory.appendingPathComponent("Preview Edits", isDirectory: true)
        #else
        let namespace = SHA256.hash(data: Data(libraryDirectory.standardizedFileURL.path.utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        // Existing live Preview documents must keep their original working paths.
        directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".canopy/Preview Edits", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
        #endif
    }
    func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    func removeUntrackedFiles(keeping filenames: Set<String>) throws {
        try prepareDirectory()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard file.pathExtension == "png", !filenames.contains(file.lastPathComponent) else { continue }
            try remove(filename: file.lastPathComponent)
        }
    }
    func url(filename: String) throws -> URL {
        guard filename == (filename as NSString).lastPathComponent, !filename.contains(".."),
              !filename.contains("\\"), filename.hasSuffix(".png"), !filename.isEmpty else { throw CocoaError(.fileReadInvalidFileName) }
        return directory.appendingPathComponent(filename)
    }
    func stage(from source: URL, filename: String) throws -> URL {
        try prepareDirectory()
        let destination = try url(filename: filename)
        try Data(contentsOf: source).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
        return destination
    }
    func remove(filename: String) throws {
        let target = try url(filename: filename)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
    }
}
