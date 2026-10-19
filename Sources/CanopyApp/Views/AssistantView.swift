import CanopyCore
import SwiftUI

struct AssistantView: View {
    @ObservedObject var state: AppState
    @State private var question = ""
    @State private var showContext = false
    private let prompts = ["Explain this simply", "Help me prepare", "What should I follow up on?"]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "A thought partner, within reach")
                    Text("A little clarity goes a long way.").font(.system(size: 26, weight: .medium, design: .rounded)).tracking(-0.6)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(state.library.preferences.assistant.provider.label).font(.system(size: 11, weight: .semibold))
                    Text(state.library.preferences.assistant.model).font(.system(size: 9)).foregroundStyle(CanopyTheme.muted)
                }
                IconButton(symbol: "arrow.counterclockwise", help: "Clear conversation") { state.messages = [] }.disabled(state.assistantBusy)
            }
            HStack(spacing: 14) {
                Toggle("Selected meeting", isOn: $state.includeMeeting).toggleStyle(.checkbox).disabled(state.selectedMeeting == nil)
                Toggle("Pinned capture text", isOn: $state.includeCaptures).toggleStyle(.checkbox)
                Spacer()
                Button { showContext.toggle() } label: { Label("Preview context", systemImage: "eye") }.buttonStyle(.plain).font(.system(size: 11))
            }.font(.system(size: 11)).padding(12).canopyCard()
            if showContext {
                ScrollView { Text(state.assistantContext.isEmpty ? "No context selected." : state.assistantContext).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                    .frame(height: 90).canopyCard()
            }
            if state.messages.isEmpty {
                VStack(spacing: 20) {
                    Image(systemName: "sparkles").font(.system(size: 35, weight: .light)).foregroundStyle(CanopyTheme.ink)
                        .frame(width: 78, height: 78).background(CanopyTheme.accent.opacity(0.4), in: RoundedRectangle(cornerRadius: 26))
                    VStack(spacing: 7) {
                        Text("Bring your next question.").font(.system(size: 21, weight: .medium, design: .rounded))
                        Text("Prepare for an interview, understand a capture, or find the next step in a meeting.")
                            .font(.system(size: 12)).foregroundStyle(CanopyTheme.muted)
                    }
                    HStack(spacing: 8) {
                        ForEach(prompts, id: \.self) { prompt in Button(prompt) { question = prompt }.buttonStyle(CanopyButtonStyle(compact: true)) }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(state.messages) { message in
                                VStack(alignment: .leading, spacing: 7) {
                                    HStack {
                                        Eyebrow(text: message.role == "user" ? "You" : CanopyArtwork.name)
                                        Spacer()
                                        if message.role == "assistant" { IconButton(symbol: "doc.on.doc", help: "Copy answer") { state.copyText(message.text) } }
                                    }
                                    Text(.init(message.text)).font(.system(size: 13)).lineSpacing(3).textSelection(.enabled)
                                }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(message.role == "user" ? CanopyTheme.accent.opacity(0.25) : CanopyTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                                    .id(message.id)
                            }
                            if state.assistantBusy { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(CanopyTheme.muted) }.padding(12) }
                        }.padding(.bottom, 10)
                    }.onChange(of: state.messages.count) { _, _ in if let last = state.messages.last { reader.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            VStack(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    TextField("Ask anything useful…", text: $question, axis: .vertical).textFieldStyle(.plain).font(.system(size: 14)).lineLimit(1...3)
                        .onSubmit(send).disabled(state.assistantBusy)
                    if state.assistantBusy {
                        Button { state.cancelAnswer() } label: { Label("Cancel", systemImage: "stop") }.buttonStyle(CanopyButtonStyle())
                    } else {
                        Button(action: send) { Label("Ask", systemImage: "arrow.up") }.buttonStyle(CanopyButtonStyle(primary: true))
                            .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }.padding(14).canopyCard()
                HStack {
                    Image(systemName: "arrow.up.right.square")
                    Text(state.contextDescription).lineLimit(1)
                    Spacer()
                    Text("\(state.assistantContext.count) context characters").font(.system(size: 9, design: .monospaced))
                }.font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
            }
        }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 18).foregroundStyle(CanopyTheme.ink)
            .onChange(of: state.messages.count) { _, _ in
                if state.messages.last(where: { $0.role == "user" })?.text == question { question = "" }
            }
    }
    private func send() {
        guard !state.assistantBusy, !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        state.ask(question)
        if state.pendingAIRequest == nil { question = "" }
    }
}
