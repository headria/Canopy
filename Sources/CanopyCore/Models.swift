import Foundation

public enum AudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    public var label: String { self == .microphone ? "You" : "Meeting" }
}

public struct TranscriptSegment: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let source: AudioSource
    public var text: String
    public let timestamp: Date
    public var isFinal: Bool

    public init(id: UUID = UUID(), source: AudioSource, text: String, timestamp: Date = Date(), isFinal: Bool = false) {
        self.id = id; self.source = source; self.text = text
        self.timestamp = timestamp; self.isFinal = isFinal
    }
}

public struct Meeting: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public let startedAt: Date
    public var endedAt: Date?
    public var segments: [TranscriptSegment]
    public var notes: String
    public var summary: String
    public var richNotes: RichMeetingNotes?

    public init(id: UUID = UUID(), title: String, startedAt: Date = Date(), endedAt: Date? = nil,
                segments: [TranscriptSegment] = [], notes: String = "", summary: String = "", richNotes: RichMeetingNotes? = nil) {
        self.id = id; self.title = title; self.startedAt = startedAt; self.endedAt = endedAt
        self.segments = segments; self.notes = notes; self.summary = summary
        self.richNotes = richNotes
    }

    private enum CodingKeys: String, CodingKey { case id, title, startedAt, endedAt, segments, notes, summary, richNotes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        startedAt = try values.decode(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        segments = try values.decode([TranscriptSegment].self, forKey: .segments)
        notes = try values.decode(String.self, forKey: .notes)
        summary = try values.decode(String.self, forKey: .summary)
        richNotes = try values.decodeIfPresent(RichMeetingNotes.self, forKey: .richNotes)
    }

    public mutating func upsert(_ segment: TranscriptSegment) {
        guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if let index = segments.firstIndex(where: { $0.id == segment.id }) { segments[index] = segment }
        else { segments.append(segment) }
        segments.sort { $0.timestamp < $1.timestamp }
    }

    public var transcript: String {
        segments.map { "[\($0.source.label)] \($0.text)" }.joined(separator: "\n")
    }

    public var markdown: String {
        let date = startedAt.formatted(date: .abbreviated, time: .shortened)
        let notebook = richNotes?.nestedMarkdown ?? notes
        return "# \(title)\n\n\(date)\n\n## Notes\n\n\(notebook)\n\n## Summary\n\n\(summary)\n\n## Transcript\n\n\(transcript)\n"
    }
}

public struct Capture: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    /// A filename, never an arbitrary filesystem path.
    public let filename: String
    public let createdAt: Date
    public var isPinned: Bool
    public var extractedText: String
    /// Deduplicates a managed inbox file if the app exits between saving and removing it.
    public let incomingSource: IncomingScreenshot?
    public var imageVersion: CaptureImageVersion?
    public var previewVersion: CaptureImageVersion?

    public init(id: UUID = UUID(), title: String, filename: String, createdAt: Date = Date(),
                isPinned: Bool = false, extractedText: String = "", incomingSource: IncomingScreenshot? = nil, imageVersion: CaptureImageVersion? = nil, previewVersion: CaptureImageVersion? = nil) {
        self.id = id; self.title = title; self.filename = filename; self.createdAt = createdAt
        self.isPinned = isPinned; self.extractedText = extractedText
        self.incomingSource = incomingSource
        self.imageVersion = imageVersion; self.previewVersion = previewVersion
    }
}

public struct CaptureImageVersion: Codable, Equatable, Sendable {
    public let size: Int
    public let modifiedAt: Date
    public static func read(at url: URL) throws -> Self {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = values[.size] as? NSNumber, let modifiedAt = values[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
        return Self(size: size.intValue, modifiedAt: modifiedAt)
    }
}

public struct IncomingScreenshot: Codable, Equatable, Sendable {
    public let filename: String
    public let size: Int
    public let modifiedAt: Date
    public init(filename: String, size: Int, modifiedAt: Date) {
        self.filename = filename; self.size = size; self.modifiedAt = modifiedAt
    }
}

public enum AssistantProvider: String, Codable, CaseIterable, Sendable {
    case compatible, claude
    public var label: String { self == .claude ? "Claude" : "OpenAI-compatible" }
}

public struct AssistantSettings: Codable, Equatable, Sendable {
    public var provider: AssistantProvider
    /// Complete endpoint, including /chat/completions or /messages.
    public var endpoint: String
    public var model: String
    public init(provider: AssistantProvider = .claude, endpoint: String = "https://api.anthropic.com/v1/messages", model: String = "claude-sonnet-4-6") {
        self.provider = provider; self.endpoint = endpoint; self.model = model
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var assistant = AssistantSettings()
    public var jevEndpoint = "https://api.typesafe.ai/v1/systemone"
    public var revealOnHover = true
    public var speechLocale = "en-US"
    public var screenshotWatchingEnabled = true
    public var managesSystemScreenshots = true
    /// Store routing is enabled only after the user chooses it, including upgrades.
    public var screenshotSetupVersion = 0
    /// Nil follows macOS's screenshot destination; a custom folder persists across launches.
    public var screenshotFolder: String?
    /// Only the App Store watcher uses the user-selected folder's security scope.
    public var screenshotFolderBookmark: Data?
    /// The floating workspace has its own position, separate from the top shelf.
    public var workspaceFrame: WorkspaceFrame?
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case assistant, jevEndpoint, revealOnHover, speechLocale, screenshotWatchingEnabled, screenshotFolder, managesSystemScreenshots, screenshotFolderBookmark, workspaceFrame, screenshotSetupVersion
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        assistant = try values.decodeIfPresent(AssistantSettings.self, forKey: .assistant) ?? assistant
        jevEndpoint = try values.decodeIfPresent(String.self, forKey: .jevEndpoint) ?? jevEndpoint
        revealOnHover = try values.decodeIfPresent(Bool.self, forKey: .revealOnHover) ?? revealOnHover
        speechLocale = try values.decodeIfPresent(String.self, forKey: .speechLocale) ?? speechLocale
        screenshotWatchingEnabled = try values.decodeIfPresent(Bool.self, forKey: .screenshotWatchingEnabled) ?? true
        managesSystemScreenshots = try values.decodeIfPresent(Bool.self, forKey: .managesSystemScreenshots) ?? true
        screenshotSetupVersion = try values.decodeIfPresent(Int.self, forKey: .screenshotSetupVersion) ?? 0
        screenshotFolder = try values.decodeIfPresent(String.self, forKey: .screenshotFolder)
        screenshotFolderBookmark = try values.decodeIfPresent(Data.self, forKey: .screenshotFolderBookmark)
        workspaceFrame = try values.decodeIfPresent(WorkspaceFrame.self, forKey: .workspaceFrame)
    }
}

public struct Library: Codable, Equatable, Sendable {
    public var schemaVersion = 2
    public var captures: [Capture] = []
    public var meetings: [Meeting] = []
    public var preferences = Preferences()
    public init() {}
}

public struct AssistantMessage: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let role: String
    public let text: String
    public init(role: String, text: String) { self.role = role; self.text = text }
}
