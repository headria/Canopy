import Foundation

public protocol LibraryRepository {
    func load() throws -> Library
    func save(_ library: Library) throws
}

public enum LibraryError: LocalizedError {
    case unsupportedVersion(Int), invalidFilename
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "Library version \(version) is newer than this app. Update \(ProductBrand.name) before opening it."
        case .invalidFilename: return "The capture filename is invalid."
        }
    }
}

public struct FileLibraryRepository: LibraryRepository {
    private struct Header: Decodable { let schemaVersion: Int }
    public let directory: URL
    public var capturesDirectory: URL { directory.appendingPathComponent("Captures", isDirectory: true) }
    public var libraryURL: URL { directory.appendingPathComponent("library.json") }
    public init(directory: URL) { self.directory = directory }

    public func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: libraryURL.path) else { return Library() }
        let data = try Data(contentsOf: libraryURL)
        let version = try JSONDecoder().decode(Header.self, from: data).schemaVersion
        guard [1, 2].contains(version) else { throw LibraryError.unsupportedVersion(version) }
        var library = try JSONDecoder().decode(Library.self, from: data)
        // Version 2 protects structured notes from being overwritten by an older app.
        library.schemaVersion = 2
        return library
    }

    public func save(_ library: Library) throws {
        try FileManager.default.createDirectory(at: capturesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for folder in [directory, capturesDirectory] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if library.schemaVersion == 2, FileManager.default.fileExists(atPath: libraryURL.path) {
            let original = try Data(contentsOf: libraryURL)
            if try JSONDecoder().decode(Header.self, from: original).schemaVersion == 1 {
                let backups = directory.appendingPathComponent("Backups", isDirectory: true)
                try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                var backup = backups.appendingPathComponent("library-v1.json")
                if FileManager.default.fileExists(atPath: backup.path), try Data(contentsOf: backup) != original {
                    backup = backups.appendingPathComponent("library-v1-\(UUID().uuidString).json")
                }
                if !FileManager.default.fileExists(atPath: backup.path) {
                    try original.write(to: backup, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
                }
            }
        }
        try encoder.encode(library).write(to: libraryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: libraryURL.path)
    }

    public func captureURL(filename: String) throws -> URL {
        guard !filename.isEmpty, filename == (filename as NSString).lastPathComponent,
              !filename.contains(".."), !filename.contains("\\") else { throw LibraryError.invalidFilename }
        return capturesDirectory.appendingPathComponent(filename)
    }
}
