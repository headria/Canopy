import SwiftUI

struct AIConsentView: View {
    @ObservedObject var state: AppState
    let request: AIRequestConsent
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Send this text to \(request.recipient)?").font(.system(size: 20, weight: .semibold))
            Text("This optional AI request sends the text below and authenticates with your saved API key. Screenshot images and audio are excluded. The provider’s privacy and retention terms apply; usage may incur charges.")
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Text(request.endpoint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            ScrollView { Text(request.content).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                .background(CanopyTheme.border.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Button("Cancel") { state.pendingAIRequest = nil }.keyboardShortcut(.cancelAction)
                    .buttonStyle(CanopyButtonStyle())
                Spacer()
                Button("Send to \(request.recipient)") { Task { await state.sendApprovedAIRequest(requestID: request.id) } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(CanopyButtonStyle(primary: true))
            }
        }.padding(24).frame(width: 560, height: 480)
            .foregroundStyle(CanopyTheme.ink).background(CanopyTheme.paper)
            .tint(CanopyTheme.primary).preferredColorScheme(.light)
    }
}
