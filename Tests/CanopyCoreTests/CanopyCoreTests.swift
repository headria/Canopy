import CanopyCore
import Foundation
import Testing

struct CanopyCoreTests {
    @Test func testPartialIsReplacedByFinalAndOrderedBySourceTime() {
        var meeting = Meeting(title: "Sync")
        let id = UUID()
        meeting.upsert(TranscriptSegment(id: id, source: .microphone, text: "I will", timestamp: Date(timeIntervalSince1970: 20)))
        meeting.upsert(TranscriptSegment(source: .system, text: "What is next?", timestamp: Date(timeIntervalSince1970: 10), isFinal: true))
        let final = TranscriptSegment(id: id, source: .microphone, text: "I will send it tomorrow.", timestamp: Date(timeIntervalSince1970: 20), isFinal: true)
        meeting.upsert(final); meeting.upsert(final)
        expectEqual(meeting.segments.count, 2)
        expectEqual(meeting.segments.last, final)
        expectEqual(meeting.transcript, "[Meeting] What is next?\n[You] I will send it tomorrow.")
        meeting.upsert(TranscriptSegment(source: .system, text: "  \n"))
        expectEqual(meeting.segments.count, 2)
    }

    @Test func testLibraryRoundTripAndAtomicReplacement() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory)
        expectEqual(try repository.load(), Library())
        var library = Library()
        library.meetings = [Meeting(title: "Meeting", notes: "Follow up")]
        library.captures = [Capture(title: "Screenshot", filename: "valid.png", isPinned: true, extractedText: "Some text")]
        try repository.save(library)
        expectEqual(try repository.load(), library)
        library.meetings[0].notes = "Updated notes"
        try repository.save(library)
        expectEqual(try repository.load().meetings[0].notes, "Updated notes")
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.libraryURL.path)
        expectEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @Test func testUnknownVersionAndCorruptionArePreserved() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileLibraryRepository(directory: directory)
        var library = Library(); library.schemaVersion = 9
        try repository.save(library)
        let original = try Data(contentsOf: repository.libraryURL)
        expectThrows(try repository.load())
        expectEqual(try Data(contentsOf: repository.libraryURL), original)
        let corrupt = Data("{broken".utf8)
        try corrupt.write(to: repository.libraryURL)
        expectThrows(try repository.load())
        expectEqual(try Data(contentsOf: repository.libraryURL), corrupt)
    }

    @Test func testCaptureFilenamesCannotEscapeStorage() throws {
        let repository = FileLibraryRepository(directory: URL(fileURLWithPath: "/tmp/canopy-tests"))
        for path in ["../secret.png", "/etc/passwd", "a/b.png", "", "..", "a\\b.png"] {
            expectThrows(try repository.captureURL(filename: path), path)
        }
        expectEqual(try repository.captureURL(filename: "image.png").path, "/tmp/canopy-tests/Captures/image.png")
    }

    @Test func testEndpointPolicyPreventsInsecureCredentialTransport() throws {
        for endpoint in ["http://example.com/v1", "file:///tmp/api", "https://user:password@example.com", "https://example.com#fragment", "not a url"] {
            expectThrows(try EndpointPolicy.validate(endpoint), endpoint)
        }
        for endpoint in ["https://api.typesafe.ai/v1/systemone", "http://localhost:11434/v1/chat/completions", "http://127.0.0.1:8080"] {
            expectNoThrow(try EndpointPolicy.validate(endpoint))
        }
    }

    @Test func testContextIsOptInAndBounded() {
        expectEqual(PromptBuilder.context(meeting: nil, captures: []), "")
        let capture = Capture(title: "Design", filename: "a.png", extractedText: "Selected image text")
        var meeting = Meeting(title: "Planning", notes: "Only explicit owners")
        meeting.segments = [TranscriptSegment(source: .system, text: String(repeating: "x", count: 50_000))]
        let context = PromptBuilder.context(meeting: meeting, captures: [capture])
        expectTrue(context.count <= 40_000)
        expectTrue(context.contains("[Earlier context omitted"))
        expectTrue(context.hasPrefix("MEETING: Planning\nNOTES:\nOnly explicit owners"))
        expectTrue(context.hasSuffix("Selected image text"))
    }

    @Test func testClaudeAndCompatibleRequestsUseTheirOwnAuthAndShape() throws {
        let client = HTTPAssistantClient()
        let message = AssistantMessage(role: "user", text: "Hello")
        let claude = try client.makeRequest(settings: AssistantSettings(), apiKey: "test-key", messages: [message], context: "Untrusted reference")
        expectEqual(claude.value(forHTTPHeaderField: "x-api-key"), "test-key")
        expectNil(claude.value(forHTTPHeaderField: "Authorization"))
        let json = try unwrap(JSONSerialization.jsonObject(with: unwrap(claude.httpBody)) as? [String: Any])
        expectTrue((json["system"] as? String)?.contains("<reference_context>") == true)
        expectEqual(json["max_tokens"] as? Int, 2048)
        let settings = AssistantSettings(provider: .compatible, endpoint: "http://localhost:11434/v1/chat/completions", model: "local")
        let compatible = try client.makeRequest(settings: settings, apiKey: "", messages: [message], context: "")
        expectNil(compatible.value(forHTTPHeaderField: "x-api-key"))
        expectNoThrow(try client.makeRequest(settings: settings, apiKey: "", messages: [message], context: ""))
        expectThrows(try client.makeRequest(settings: AssistantSettings(), apiKey: "", messages: [message], context: ""))
        let history = (0..<21).map { AssistantMessage(role: $0 % 2 == 0 ? "user" : "assistant", text: "Message \($0)") }
        let bounded = try client.makeRequest(settings: AssistantSettings(), apiKey: "test", messages: history, context: "")
        let boundedBody = try unwrap(JSONSerialization.jsonObject(with: unwrap(bounded.httpBody)) as? [String: Any])
        expectEqual((boundedBody["messages"] as? [[String: String]])?.first?["role"], "user")
    }

    @Test func testProviderResponsesAndEmptyResponses() throws {
        let claude = Data(#"{"content":[{"type":"text","text":"One"},{"type":"thinking","thinking":"private"},{"type":"text","text":"Two"}]}"#.utf8)
        expectEqual(try HTTPAssistantClient.decode(claude, provider: .claude), "One\nTwo")
        let compatible = Data(#"{"choices":[{"message":{"content":"Answer"}}]}"#.utf8)
        expectEqual(try HTTPAssistantClient.decode(compatible, provider: .compatible), "Answer")
        expectThrows(try HTTPAssistantClient.decode(Data(#"{"choices":[]}"#.utf8), provider: .compatible))
    }

    @Test func testJevUsesDocumentedTypedQuestionsAndValidatesProbabilities() throws {
        let request = try JevClient().makeRequest(endpoint: "https://api.typesafe.ai/v1/systemone", apiKey: "test-key", state: "I will send the draft.")
        expectEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try unwrap(JSONSerialization.jsonObject(with: unwrap(request.httpBody)) as? [String: Any])
        expectEqual(body["model"] as? String, "jev-latest")
        expectEqual((body["questions"] as? [String: Any])?.count, 3)
        let response = Data(#"{"answers":{"kind":{"type":"choice","choice":"action_item","confidence":0.9},"action":{"type":"noul","noul":0.95},"question":{"type":"noul","noul":0.1}}}"#.utf8)
        let signals = try JevClient.decode(response)
        expectEqual(signals.kind, "action_item"); expectEqual(signals.actionProbability, 0.95)
        let invalid = Data(#"{"answers":{"kind":{"choice":"unknown","confidence":1.2},"action":{"noul":0.9},"question":{"noul":0.2}}}"#.utf8)
        expectThrows(try JevClient.decode(invalid))
    }

    @Test func testMarkdownExportIncludesNotesSummaryAndSpeakerLabels() {
        let meeting = Meeting(title: "Daily sync", segments: [TranscriptSegment(source: .microphone, text: "I'll review it.", isFinal: true)], notes: "Check design", summary: "Design review")
        expectTrue(meeting.markdown.contains("# Daily sync"))
        expectTrue(meeting.markdown.contains("## Notes\n\nCheck design"))
        expectTrue(meeting.markdown.contains("[You] I'll review it."))
    }
}

private func expectEqual<T: Equatable>(_ actual: T, _ expected: T, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(actual == expected, sourceLocation: sourceLocation)
}
private func expectTrue(_ value: Bool, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value, sourceLocation: sourceLocation)
}
private func expectNil<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(value == nil, sourceLocation: sourceLocation)
}
private func expectThrows<T>(_ expression: @autoclosure () throws -> T, _ message: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression(); Issue.record("Expected an error: \(message)", sourceLocation: sourceLocation) } catch { }
}
private func expectNoThrow<T>(_ expression: @autoclosure () throws -> T, sourceLocation: SourceLocation = #_sourceLocation) {
    do { _ = try expression() } catch { Issue.record(error, sourceLocation: sourceLocation) }
}
private func unwrap<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
    try #require(value, sourceLocation: sourceLocation)
}
