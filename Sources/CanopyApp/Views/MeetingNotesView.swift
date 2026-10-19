import SwiftUI

struct MeetingNotesView: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    var body: some View {
        RichNoteEditor(state: state, meetingID: meetingID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16)).canopyCard()
    }
}
