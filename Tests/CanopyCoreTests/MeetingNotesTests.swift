import CanopyCore
import Foundation
import Testing

struct MeetingNotesTests {
    private let document = """
    {"type":"doc","content":[{"type":"heading","attrs":{"level":2},"content":[{"type":"text","text":"Next steps"}]},{"type":"taskList","content":[{"type":"taskItem","attrs":{"checked":true},"content":[{"type":"paragraph","content":[{"type":"text","text":"Send review"}]}]}]}]}
    """
    @Test func oldLibraryLoadsWithoutWritingAndIsBackedUpBeforeUpgrade() throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        var library = Library(); library.schemaVersion = 1
        library.meetings = [Meeting(title: "Original", segments: [TranscriptSegment(source: .system, text: "Original passage", isFinal: true)], notes: "  Keep this exactly.\n• Details 📝\n", summary: "Original summary")]
        library.captures = [Capture(title: "Original capture", filename: "image.png")]
        library.preferences.speechLocale = "fr-FR"
        try repository.save(library)
        let original = try Data(contentsOf: repository.libraryURL)
        var loaded = try repository.load()
        #expect(loaded.schemaVersion == 2)
        #expect(loaded.meetings == library.meetings && loaded.captures == library.captures && loaded.preferences == library.preferences)
        #expect(loaded.meetings[0].richNotes == nil)
        #expect(try Data(contentsOf: repository.libraryURL) == original)
        loaded.meetings[0].richNotes = try RichMeetingNotes(json: document, markdown: "## Next steps\n\n- [x] Send review")
        try repository.save(loaded)
        let backup = repository.directory.appendingPathComponent("Backups/library-v1.json")
        #expect(try Data(contentsOf: backup) == original)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try repository.load() == loaded)
        try repository.save(loaded)
        #expect(try Data(contentsOf: backup) == original)
    }
    @Test func restoringADifferentOldLibraryKeepsBothUpgradeBackups() throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        var old = Library(); old.schemaVersion = 1; old.meetings = [Meeting(title: "First backup")]
        try repository.save(old); let first = try Data(contentsOf: repository.libraryURL)
        try repository.save(repository.load())
        old.meetings[0].notes = "Different restored notes"; try repository.save(old)
        let second = try Data(contentsOf: repository.libraryURL)
        try repository.save(repository.load())
        let backups = try FileManager.default.contentsOfDirectory(at: repository.directory.appendingPathComponent("Backups"), includingPropertiesForKeys: nil)
        #expect(backups.count == 2)
        let contents = try backups.map { try Data(contentsOf: $0) }
        #expect(contents.contains(first) && contents.contains(second))
    }
    @Test func unknownVersionIsReportedBeforeIncompatibleBodyAndNeverWritten() throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        try FileManager.default.createDirectory(at: repository.directory, withIntermediateDirectories: true)
        let original = Data("{\"schemaVersion\":99,\"meetings\":\"future format\"}".utf8)
        try original.write(to: repository.libraryURL)
        do { _ = try repository.load(); Issue.record("A future library must not open") }
        catch LibraryError.unsupportedVersion(let version) { #expect(version == 99) }
        #expect(try Data(contentsOf: repository.libraryURL) == original)
    }
    @Test func formattedNotesRoundTripAndExportCompletionWithoutLosingLegacyText() throws {
        let rich = try RichMeetingNotes(json: document, markdown: "## Next steps\n\n- [x] Send review")
        let meeting = Meeting(title: "Planning", notes: "Next steps\nSend review", richNotes: rich)
        #expect(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting)) == meeting)
        #expect(meeting.markdown.contains("## Notes\n\n#### Next steps\n\n- [x] Send review"))
        #expect(Meeting(title: "Legacy", notes: "Old note").markdown.contains("## Notes\n\nOld note"))
        let updated = try rich.appendingPlainText("Capture closed")
        #expect(updated.json.contains("Capture closed") && updated.markdown.hasSuffix("Capture closed"))
        #expect(updated.json.contains("taskList") && updated.markdown.contains("- [x] Send review"))
    }
    @Test func invalidAndUnsupportedEditorDocumentsAreRejected() throws {
        for value in ["{broken", "[]", "{\"type\":\"doc\"}", "{\"type\":\"doc\",\"content\":[{\"type\":\"future-widget\"}]}",
                      "{\"type\":\"doc\",\"content\":[{\"type\":\"text\",\"text\":\"link\",\"marks\":[{\"type\":\"link\",\"attrs\":{\"href\":\"javascript:alert(1)\"}}]}]}"] {
            #expect(throws: (any Error).self) { try RichMeetingNotes(json: value, markdown: "") }
        }
        var encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(RichMeetingNotes(json: document, markdown: "Saved"))) as? [String: Any])
        encoded["formatVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: encoded)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(RichMeetingNotes.self, from: data) }
    }
    @Test func webLinksRejectLocalOrExecutableDestinationsAndEmbeddedCredentials() {
        for address in ["https://example.org", "http://localhost:3000/design"] { #expect(RichMeetingNotes.isWebLink(address)) }
        for address in ["file:///etc/passwd", "javascript:alert(1)", "https://user:secret@example.org", "not a link"] { #expect(!RichMeetingNotes.isWebLink(address)) }
    }
    @Test func savedOpaqueNodesStayReadableWithoutBeingAcceptedAsNewEdits() throws {
        let json = "{\"type\":\"doc\",\"content\":[{\"type\":\"future-widget\",\"attrs\":{\"saved\":\"Keep me\"}}]}"
        let encoded = try JSONSerialization.data(withJSONObject: ["formatVersion": 1, "json": json, "markdown": "Keep me"])
        let saved = try JSONDecoder().decode(RichMeetingNotes.self, from: encoded)
        #expect(saved.json == json && saved.markdown == "Keep me")
        #expect(throws: (any Error).self) { try RichMeetingNotes(json: saved.json, markdown: saved.markdown) }
    }
    @Test func exportedHeadingsNestAndRecoveryTextRemainsLiteral() throws {
        let rich = try RichMeetingNotes(json: document, markdown: "# Title\n\n```markdown\n# Literal\n```\n\n## Details\n###### Deep")
        #expect(rich.nestedMarkdown == "### Title\n\n```markdown\n# Literal\n```\n\n#### Details\n###### Deep")
        #expect(try rich.appendingPlainText("") == rich)
        let updated = try rich.appendingPlainText("# Literal\n\n[Keep](text)")
        let root = try #require(JSONSerialization.jsonObject(with: Data(updated.json.utf8)) as? [String: Any])
        let nodes = try #require(root["content"] as? [[String: Any]])
        #expect(nodes.count == 5)
        #expect(nodes.suffix(3).allSatisfy { $0["type"] as? String == "paragraph" })
        #expect(updated.markdown.hasSuffix("\\# Literal  \n  \n\\[Keep\\](text)"))
    }
}
