import CanopyCore
import Foundation
import Testing
@testable import CanopyApp

private struct NotebookSecrets: SecretStoring {
    func read(_ account: String) throws -> String { Issue.record("Notes must not read keys"); return "" }
    func write(_ value: String, account: String) throws { Issue.record("Notes must not write keys") }
}

@MainActor
struct MeetingNotebookStateTests {
    private func formatted(_ text: String) throws -> RichMeetingNotes {
        let node: [String: Any] = ["type": "doc", "content": [["type": "paragraph", "content": [["type": "text", "text": text, "marks": [["type": "bold"]]]]]]]
        return try RichMeetingNotes(json: String(decoding: JSONSerialization.data(withJSONObject: node), as: UTF8.self), markdown: "**\(text)**")
    }
    @Test func formattedNotesSurviveShutdownWithoutAlteringTranscriptSummaryOrPreferences() async throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        var library = Library()
        let original = Meeting(title: "Planning", segments: [TranscriptSegment(source: .system, text: "Original transcript", isFinal: true)], notes: "Original note", summary: "Existing summary")
        library.meetings = [original]; try repository.save(library)
        let state = AppState(repository: repository, secrets: NotebookSecrets(), systemScreenshots: UnmanagedSystemScreenshots())
        let preferences = state.library.preferences
        let rich = try formatted("Send review")
        state.updateRichNotes(rich, plainText: "Send review", meetingID: original.id)
        await state.shutdown()
        let reopened = AppState(repository: repository, secrets: NotebookSecrets(), systemScreenshots: UnmanagedSystemScreenshots())
        let saved = try #require(reopened.selectedMeeting)
        #expect(saved.richNotes == rich && saved.notes == "Send review")
        #expect(saved.segments == original.segments && saved.summary == original.summary)
        #expect(reopened.library.preferences == preferences)
        await reopened.shutdown()
    }
    @Test func delayedEditorUpdatesNeverFollowSelectedMeetingAndMissingMeetingsAreNoOps() async throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        let first = Meeting(title: "First"), second = Meeting(title: "Second", notes: "Stay intact")
        var library = Library(); library.meetings = [first, second]; try repository.save(library)
        let state = AppState(repository: repository, secrets: NotebookSecrets(), systemScreenshots: UnmanagedSystemScreenshots())
        state.selectedMeetingID = second.id
        let rich = try formatted("Late first edit")
        state.updateRichNotes(rich, plainText: "Late first edit", meetingID: first.id)
        state.renameMeeting("Renamed first", meetingID: first.id)
        state.updateRichNotes(rich, plainText: "Missing", meetingID: UUID())
        #expect(state.library.meetings[1] == second)
        #expect(state.library.meetings[0].notes == "Late first edit" && state.library.meetings[0].title == "Renamed first")
        await state.shutdown()
        #expect(try repository.load().meetings[1] == second)
    }
    @Test func shutdownFlushesActiveDocumentAndUnregisteringOneEditorKeepsOthers() async throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        let state = AppState(repository: repository, secrets: NotebookSecrets(), systemScreenshots: UnmanagedSystemScreenshots())
        state.createNote(); let id = try #require(state.selectedMeetingID), rich = try formatted("Last edit before quit")
        let old = UUID(), active = UUID(); var flushes = 0
        state.registerNoteEditor(old) { Issue.record("Unregistered editor must not flush") }
        state.registerNoteEditor(active) { flushes += 1; state.updateRichNotes(rich, plainText: "Last edit before quit", meetingID: id) }
        state.noteEditorTransient(old, open: true); state.noteEditorTransient(active, open: true)
        state.unregisterNoteEditor(old)
        #expect(state.noteEditorTransientTokens == [active])
        await state.shutdown()
        #expect(flushes == 1)
        #expect(try repository.load().meetings[0].richNotes == rich)
        state.unregisterNoteEditor(active)
        #expect(state.noteEditorFlushers.isEmpty && state.noteEditorTransientTokens.isEmpty)
    }
    @Test func rejectedOversizedEditsReportFailureAndPreserveTheSavedNote() async throws {
        let repository = FileLibraryRepository(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: repository.directory) }
        var library = Library(); let original = Meeting(title: "Keep", notes: "Original note")
        library.meetings = [original]; try repository.save(library)
        let state = AppState(repository: repository, secrets: NotebookSecrets(), systemScreenshots: UnmanagedSystemScreenshots())
        let rich = try formatted("New note")
        #expect(!state.updateRichNotes(rich, plainText: String(repeating: "x", count: 8_000_001), meetingID: original.id))
        #expect(state.library.meetings[0] == original)
        #expect(!state.updateRichNotes(rich, plainText: "Missing", meetingID: UUID()))
        await state.shutdown()
        #expect(try repository.load().meetings[0] == original)
    }
}
