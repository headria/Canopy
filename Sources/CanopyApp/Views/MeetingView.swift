import AppKit
import CanopyCore
import SwiftUI

struct MeetingView: View {
    @ObservedObject var state: AppState
    @State private var title = ""
    @State private var mode: CaptureMode = .defaultMode
    @State private var detailTab = "Transcript"
    @State private var deleting: Meeting?
    @State private var notebookFocus = false
    private var listeningStatus: String {
        guard state.meetingCaptureMode?.includesSystem == true else { return "Listening on this Mac" }
        guard let level = state.meetingAudioLevel else { return "Waiting for meeting audio" }
        return level > 0.00001 ? "Receiving meeting audio" : "Waiting for meeting sound"
    }
    private var permissionHelp: String {
        if let setup = state.meetingSetupIssue { return setup.detail }
        if state.permissionRequiresRestart {
            return "Access is enabled, but macOS rejected this session. Quit and reopen Canopy, then choose Start listening."
        }
        if state.permissionIssue == .systemAudio { return CaptureError.systemAudioDenied.localizedDescription }
        if state.permissionIssue == .screenRecording { return CaptureError.screenRecordingDenied.localizedDescription }
        return "\(state.permissionIssue?.purpose ?? "Meeting transcription needs your permission.") macOS will ask you to choose whether to share access. Your other notes and screenshots remain available."
    }
    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            if !notebookFocus || detailTab != "Notes" {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Remember the conversation")
                Text("Be here.\nKeep the details.").font(.system(size: 24, weight: .medium, design: .rounded)).tracking(-0.5)
                    .fixedSize(horizontal: false, vertical: true)
                recordingCard
                HStack {
                    Eyebrow(text: "Your notebook")
                    Spacer()
                    IconButton(symbol: "plus", help: "New quick note") { state.createNote(); detailTab = "Notes" }
                }
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(state.library.meetings) { meeting in
                            Button { state.selectedMeetingID = meeting.id } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: meeting.id == state.activeMeetingID ? "waveform" : "doc.text").padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(meeting.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                        Text(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(state.selectedMeetingID == meeting.id ? CanopyTheme.accent.opacity(0.65) : CanopyTheme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain)
                                .contextMenu {
                                    Button("Delete meeting", role: .destructive) { deleting = meeting }.disabled(meeting.id == state.activeMeetingID)
                                }
                        }
                    }
                }
            }.frame(width: 245)
            }
            if let meeting = state.selectedMeeting { detail(meeting) }
            else { EmptyCard(symbol: "waveform", title: "Stay in the conversation.", detail: "Start a meeting to transcribe its audio on your Mac, or create a quick note. Works with Zoom, Meet, and other audio sources.") }
        }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 16).foregroundStyle(CanopyTheme.ink)
            .onAppear { state.refreshMeetingPermissions() }
            .onChange(of: state.activeMeetingID) { _, id in if id != nil { detailTab = "Transcript" } }
            .alert(state.meetingSetupIssue?.title ?? (state.permissionRequiresRestart ? "Restart Canopy to refresh access" : "Check \(state.permissionIssue?.title.lowercased() ?? "meeting") access"), isPresented: $state.showingPermissionPrompt) {
                if let setup = state.meetingSetupIssue {
                    Button("Open Dictation settings") { state.openMeetingSetupSettings(setup) }
                } else if state.permissionRequiresRestart {
                    Button("Quit Canopy") { NSApp.terminate(nil) }
                } else if let permission = state.permissionIssue {
                    Button(permission.actionTitle(for: state.meetingPermissions[permission] ?? .notGranted)) { Task { await state.requestMeetingPermission(permission) } }
                }
                Button("Not now", role: .cancel) { }
            } message: {
                Text(permissionHelp)
            }
            .alert("Delete this meeting?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Cancel", role: .cancel) { deleting = nil }
                Button("Delete", role: .destructive) { if let deleting { state.deleteMeeting(deleting) }; deleting = nil }
            } message: { Text("Its notes, summary, and transcript will be removed from this Mac.") }
    }
    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            if state.recording {
                Label(listeningStatus, systemImage: "waveform").font(.system(size: 13, weight: .semibold))
                Text("Audio is transcribed locally. No audio file is saved.").font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                if state.meetingCaptureMode?.includesSystem == true {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.meetingAudioLevel == nil ? "Waiting for meeting audio…" :
                             (state.meetingAudioLevel! > 0.00001 ? "Meeting audio is arriving" : "Connected · waiting for sound"))
                            .font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                        ProgressView(value: min(1, (state.meetingAudioLevel ?? 0) * 8))
                            .accessibilityLabel("Meeting audio input level")
                    }
                }
                if let active = state.library.meetings.first(where: { $0.id == state.activeMeetingID }) {
                    Text(active.startedAt, style: .timer).font(.system(size: 20, weight: .medium, design: .monospaced))
                }
                if let notice = state.systemAudioNotice {
                    Text(notice).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Audio settings") { state.openMeetingPermissionSettings(.systemAudio) }
                        .buttonStyle(CanopyButtonStyle(compact: true))
                }
                Button { Task { await state.stopMeeting() } } label: { Label(state.recordingTransition ? "Finishing transcript…" : "Stop listening", systemImage: "stop.fill") }
                    .buttonStyle(CanopyButtonStyle(primary: true)).disabled(state.recordingTransition || state.permissionBusy)
            } else {
                TextField("Meeting title", text: $title).textFieldStyle(.roundedBorder)
                Picker("Audio source", selection: $mode) { ForEach(CaptureMode.allCases) { Text($0.rawValue).tag($0) } }.labelsHidden()
                Button {
                    Task { await state.startMeeting(title: title, mode: mode) }
                } label: { Label(state.recordingTransition ? "Connecting…" : "Start listening", systemImage: "waveform") }
                    .buttonStyle(CanopyButtonStyle(primary: true)).disabled(state.recordingTransition || state.permissionBusy)
                if state.recordingTransition {
                    Button("Cancel preparation") { Task { await state.cancelMeetingPreparation() } }
                        .buttonStyle(CanopyButtonStyle(compact: true))
                }
                if let preparation = state.speechPreparation {
                    Text(preparation.message).font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    if let fraction = preparation.fraction { ProgressView(value: min(1, max(0, fraction))) }
                    else { ProgressView().controlSize(.small) }
                }
                Text(mode.includesMic ? "Use with participants’ permission. Headphones keep your microphone from repeating meeting audio." : "Listens to audio playing from meeting apps. Use with participants’ permission.")
                    .font(.system(size: 10)).foregroundStyle(CanopyTheme.muted).fixedSize(horizontal: false, vertical: true)
                if let setup = state.meetingSetupIssue {
                    Divider()
                    Label(setup.title, systemImage: "waveform").font(.system(size: 11, weight: .semibold))
                    Text(setup.detail).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted).fixedSize(horizontal: false, vertical: true)
                    Button("Open Dictation settings") { state.openMeetingSetupSettings(setup) }
                        .buttonStyle(CanopyButtonStyle(primary: true, compact: true))
                }
                if let permission = state.permissionIssue {
                    Divider()
                    Label(state.permissionRequiresRestart ? "Restart to refresh access" : "\(permission.title) needs attention", systemImage: "lock.fill")
                        .font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(state.permissionRequiresRestart ? "Access is enabled. Quit and reopen Canopy to refresh this session." : permission.recoveryDetail).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        if state.permissionRequiresRestart {
                            Button("Quit Canopy") { NSApp.terminate(nil) }
                                .buttonStyle(CanopyButtonStyle(primary: true, compact: true))
                        } else {
                            Button(state.permissionBusy ? "Checking…" : permission.actionTitle(for: state.meetingPermissions[permission] ?? .notGranted)) {
                                Task { await state.requestMeetingPermission(permission) }
                            }.buttonStyle(CanopyButtonStyle(primary: true, compact: true))
                        }
                        Button("Check again") { state.refreshMeetingPermissions() }
                            .buttonStyle(CanopyButtonStyle(compact: true))
                    }.disabled(state.permissionBusy || state.recordingTransition)
                }
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).canopyCard()
    }
    private func detail(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    TextField("Title", text: Binding(get: { state.library.meetings.first { $0.id == meeting.id }?.title ?? "" }, set: { state.renameMeeting($0, meetingID: meeting.id) }))
                        .font(.system(size: 19, weight: .semibold, design: .rounded)).textFieldStyle(.plain)
                    Text("\(meeting.segments.count) passages · \(meeting.id == state.activeMeetingID ? "Live transcript" : "Saved on this Mac")")
                        .font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                }
                Spacer()
                if detailTab == "Notes" {
                    IconButton(symbol: notebookFocus ? "sidebar.left" : "arrow.up.left.and.arrow.down.right", help: notebookFocus ? "Show meeting sidebar" : "Focus on notes") { notebookFocus.toggle() }
                    if notebookFocus && state.recording {
                        Button { Task { await state.stopMeeting() } } label: { Label("Stop listening", systemImage: "stop.fill") }
                            .buttonStyle(CanopyButtonStyle(compact: true)).disabled(state.recordingTransition)
                    }
                }
                IconButton(symbol: "square.and.arrow.up", help: "Export Markdown") { state.exportMeeting() }
            }
            HStack(spacing: 6) {
                ForEach(meeting.summary.isEmpty ? ["Notes", "Transcript"] : ["Notes", "Transcript", "Summary"], id: \.self) { tab in
                    Button { detailTab = tab } label: {
                        Text(tab).font(.system(size: 11, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 7)
                            .background(detailTab == tab ? CanopyTheme.accent : CanopyTheme.surface.opacity(0.85), in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
                if detailTab == "Transcript" { IconButton(symbol: "doc.on.doc", help: "Copy transcript") { state.copyText(meeting.transcript) } }
            }
            Group {
                if detailTab == "Notes" {
                    MeetingNotesView(state: state, meetingID: meeting.id).id(meeting.id)
                } else if detailTab == "Transcript" {
                    if meeting.segments.isEmpty {
                        EmptyCard(symbol: "ear", title: meeting.endedAt == nil ? "Waiting for speech." : "No speech was transcribed.",
                                  detail: meeting.endedAt == nil
                                    ? "Recognized speech appears here. Check the audio indicator while the meeting is playing."
                                    : "This meeting ended without recognized speech. Start listening while the call is audible and check whether the audio indicator moves.").canopyCard()
                    } else {
                        ScrollViewReader { reader in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(meeting.segments) { segment in
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Text(segment.source.label.uppercased()).font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                                                Text(segment.timestamp, style: .time).font(.system(size: 9)).foregroundStyle(CanopyTheme.muted)
                                                if !segment.isFinal { Circle().fill(CanopyTheme.ink).frame(width: 4, height: 4) }
                                            }
                                            Text(segment.text).font(.system(size: 13)).textSelection(.enabled).lineSpacing(3)
                                        }.id(segment.id)
                                    }
                                }.padding(16)
                            }.canopyCard()
                                .onChange(of: meeting.segments.count) { _, _ in if meeting.id == state.activeMeetingID, let last = meeting.segments.last { reader.scrollTo(last.id, anchor: .bottom) } }
                        }
                    }
                } else {
                    ScrollView {
                        Text(.init(meeting.summary)).font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    }.canopyCard()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
