import Foundation

public enum MeetingNotesError: LocalizedError {
    case invalidDocument, unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidDocument: return "This formatted note could not be read. Its saved content is preserved."
        case .unsupportedVersion: return "This note uses a newer editor format. Update Canopy to open it."
        }
    }
}

/// The editor's lossless document and a portable Markdown export. Plain text stays
/// in Meeting.notes for existing integrations; opening an old note never rewrites it.
public struct RichMeetingNotes: Codable, Equatable, Sendable {
    public let formatVersion: Int
    public let json: String
    public let markdown: String
    public init(json: String, markdown: String) throws {
        guard json.utf8.count <= 8_000_000, markdown.utf8.count <= 8_000_000,
              let data = json.data(using: .utf8),
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], root["type"] as? String == "doc" else {
            throw MeetingNotesError.invalidDocument
        }
        var count = 0
        try Self.validate(root, depth: 0, count: &count)
        self.formatVersion = 1; self.json = json; self.markdown = markdown
    }
    private enum CodingKeys: String, CodingKey { case formatVersion, json, markdown }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .formatVersion)
        guard version == 1 else { throw MeetingNotesError.unsupportedVersion(version) }
        let json = try values.decode(String.self, forKey: .json), markdown = try values.decode(String.self, forKey: .markdown)
        guard json.utf8.count <= 8_000_000, markdown.utf8.count <= 8_000_000,
              let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], root["type"] as? String == "doc" else { throw MeetingNotesError.invalidDocument }
        // Keep opaque saved nodes intact. One unsupported note must not hide the
        // rest of the library; the editor validates its own schema before editing.
        formatVersion = version; self.json = json; self.markdown = markdown
    }
    private static func validate(_ node: [String: Any], depth: Int, count: inout Int) throws {
        count += 1
        let nodes: Set<String> = ["doc", "paragraph", "heading", "text", "hardBreak", "bulletList", "orderedList", "listItem", "taskList", "taskItem", "blockquote", "horizontalRule", "codeBlock"]
        guard depth <= 64, count <= 100_000, let type = node["type"] as? String, nodes.contains(type) else { throw MeetingNotesError.invalidDocument }
        if type == "doc" { guard depth == 0, let children = node["content"] as? [[String: Any]], !children.isEmpty else { throw MeetingNotesError.invalidDocument } }
        if type == "text" { guard let text = node["text"] as? String, !text.isEmpty else { throw MeetingNotesError.invalidDocument } }
        if let raw = node["marks"] {
            guard let marks = raw as? [[String: Any]] else { throw MeetingNotesError.invalidDocument }
            for mark in marks {
                guard let type = mark["type"] as? String, ["bold", "italic", "strike", "underline", "code", "link"].contains(type) else { throw MeetingNotesError.invalidDocument }
                if type == "link" {
                    guard let attrs = mark["attrs"] as? [String: Any], let href = attrs["href"] as? String, isWebLink(href) else { throw MeetingNotesError.invalidDocument }
                }
            }
        }
        if let raw = node["content"] {
            guard let children = raw as? [[String: Any]] else { throw MeetingNotesError.invalidDocument }
            for child in children { try validate(child, depth: depth + 1, count: &count) }
        }
    }
    public static func isWebLink(_ value: String) -> Bool {
        guard let url = URL(string: value), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return false }
        return true
    }
    public func appendingPlainText(_ text: String) throws -> Self {
        guard !text.isEmpty else { return self }
        guard var root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw MeetingNotesError.invalidDocument }
        var content = root["content"] as? [[String: Any]] ?? []
        for line in text.components(separatedBy: "\n") {
            var paragraph: [String: Any] = ["type": "paragraph"]
            if !line.isEmpty { paragraph["content"] = [["type": "text", "text": line]] }
            content.append(paragraph)
        }
        root["content"] = content
        let updated = try JSONSerialization.data(withJSONObject: root, options: .sortedKeys)
        let escaped = text.map { "\\`*_[]<>#-+!".contains($0) ? "\\" + String($0) : String($0) }.joined().replacingOccurrences(of: "\n", with: "  \n")
        return try Self(json: String(decoding: updated, as: UTF8.self), markdown: markdown + "\n\n" + escaped)
    }
    /// Note headings sit beneath the meeting export's Notes section. Code remains literal.
    public var nestedMarkdown: String {
        var fence: String?
        return markdown.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let delimiter = String(trimmed.prefix(3))
                if fence == nil { fence = delimiter } else if fence == delimiter { fence = nil }
                return line
            }
            guard fence == nil else { return line }
            let level = line.prefix { $0 == "#" }.count
            guard (1...6).contains(level), line.dropFirst(level).first == " " else { return line }
            return String(repeating: "#", count: min(6, level + 2)) + line.dropFirst(level)
        }.joined(separator: "\n")
    }
}
