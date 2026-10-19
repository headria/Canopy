import CanopyCore
import Foundation

@MainActor
extension AppState {
    func updateNotes(_ value: String, meetingID: UUID) {
        guard let index = library.meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        library.meetings[index].notes = value; library.meetings[index].richNotes = nil; saveSoon()
    }
    func renameMeeting(_ value: String, meetingID: UUID) {
        guard let index = library.meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        library.meetings[index].title = value; saveSoon()
    }
    @discardableResult
    func updateRichNotes(_ notes: RichMeetingNotes, plainText: String, meetingID: UUID) -> Bool {
        guard let index = library.meetings.firstIndex(where: { $0.id == meetingID }), plainText.utf8.count <= 8_000_000 else { return false }
        guard library.meetings[index].richNotes != notes || library.meetings[index].notes != plainText else { return true }
        library.meetings[index].notes = plainText; library.meetings[index].richNotes = notes; saveSoon()
        return true
    }
    func registerNoteEditor(_ token: UUID, flush: @escaping @MainActor () async -> Void) { noteEditorFlushers[token] = flush }
    func unregisterNoteEditor(_ token: UUID) { noteEditorFlushers.removeValue(forKey: token); noteEditorTransientTokens.remove(token) }
    func noteEditorTransient(_ token: UUID, open: Bool) {
        if open { noteEditorTransientTokens.insert(token) } else { noteEditorTransientTokens.remove(token) }
    }
    func flushNoteEditors() async {
        for flush in Array(noteEditorFlushers.values) { await flush() }
    }
}
