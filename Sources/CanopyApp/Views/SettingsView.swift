import AppKit
import CanopyCore
import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState
    @State private var draft = Preferences()
    @State private var ready = false
    @State private var showingPrivacy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Eyebrow(text: "Make yourself at home")
                        Text("Your tools. Your terms.").font(.system(size: 26, weight: .medium, design: .rounded)).tracking(-0.6)
                    }
                    Spacer()
                    Button("Save settings", action: save).buttonStyle(CanopyButtonStyle(primary: true))
                }
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label { Text("Daily flow") } icon: { BrandMark(size: 14) }.font(.system(size: 14, weight: .semibold))
                        Toggle("Reveal when hovering over the menu bar", isOn: $draft.revealOnHover)
                        Toggle("Watch a screenshot folder", isOn: screenshotWatchingBinding)
                        if state.distribution.managesScreenshotSettings {
                        Toggle("Keep screenshots only in \(ProductBrand.name)", isOn: screenshotManagementBinding)
                        Text("While \(ProductBrand.name) is running, screenshots go straight to your shelf and the macOS corner preview is hidden. Quit or turn this off to restore your previous screenshot settings. × discards a capture.")
                            .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                        } else {
                            Button("Choose screenshot folder…") { state.watchFolder(); syncScreenshotFolderDraft() }
                                .buttonStyle(CanopyButtonStyle(compact: true))
                            Text("Click Capture on the top shelf or press ⌃⌥S to capture directly into \(ProductBrand.name). To also use ⇧⌘3 or ⇧⌘4, choose the folder where macOS saves your screenshots. Folder detection keeps the originals and uses macOS’s thumbnail setting.")
                                .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                        }
                        field("Speech language (locale)", text: $draft.speechLocale)
                        Text("⌃⌥Space opens the shelf. ⌃⌥S captures a region. Escape tucks it away. Pin the shelf to keep it open.").font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).canopyCard()
                    VStack(alignment: .leading, spacing: 12) {
                        Label("On your Mac", systemImage: "lock.shield").font(.system(size: 14, weight: .semibold))
                        Text("Captures, notes, and transcripts stay in Application Support. Audio is processed in memory and never saved. Screenshot text recognition and meeting transcription run on your Mac.")
                            .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                        HStack {
                            Button("Reveal library") { NSWorkspace.shared.open(state.repository.directory) }.buttonStyle(CanopyButtonStyle(compact: true))
                            Button("Privacy policy") { showingPrivacy = true }.buttonStyle(CanopyButtonStyle(compact: true))
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).canopyCard()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Meeting permissions", systemImage: "checkmark.shield").font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Button("Check again") { state.refreshMeetingPermissions() }.buttonStyle(CanopyButtonStyle(compact: true))
                            .disabled(state.permissionBusy)
                    }
                    Text("Permissions are optional. Continue opens the macOS permission request; Open Settings lets you review a previous choice. Neither starts a recording.")
                        .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    ForEach(MeetingPermission.availableCases) { permission in
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(permission.title).font(.system(size: 12, weight: .semibold))
                                Text(permission.purpose).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                            }
                            Spacer()
                            let status = state.meetingPermissions[permission] ?? .notGranted
                            Text(status.label).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                            Button(permission.actionTitle(for: status)) {
                                if status == .allowed || status == .restricted || status == .onStart { state.openMeetingPermissionSettings(permission) }
                                else { Task { await state.requestMeetingPermission(permission) } }
                            }.buttonStyle(CanopyButtonStyle(compact: true))
                                .disabled(state.permissionBusy || state.recording || state.recordingTransition)
                        }.padding(.vertical, 6)
                    }
                    Divider()
                    if SpeechBackend.current == .legacy {
                    HStack(spacing: 14) {
                        Text("If speech recognition reports Siri or Dictation is disabled, enable Dictation in Keyboard settings.")
                            .font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                        Spacer()
                        Button("Dictation settings") { state.openMeetingSetupSettings(.dictationDisabled) }
                            .buttonStyle(CanopyButtonStyle(compact: true))
                    }
                    } else {
                        Text("Language support downloads automatically the first time you listen. Meeting audio stays on your Mac.")
                            .font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).canopyCard()
            }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 18)
        }.foregroundStyle(CanopyTheme.ink)
            .sheet(isPresented: $showingPrivacy) { PrivacyPolicyView() }
            .onAppear {
                if !ready {
                    draft = state.library.preferences
                    ready = true
                }
                state.refreshMeetingPermissions()
            }
    }
    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) { Eyebrow(text: label); TextField(label, text: text).textFieldStyle(.roundedBorder) }
    }
    private var screenshotWatchingBinding: Binding<Bool> {
        if state.distribution == .direct { return $draft.screenshotWatchingEnabled }
        return Binding(get: { state.library.preferences.screenshotWatchingEnabled }, set: {
            state.setScreenshotWatching($0)
            syncScreenshotFolderDraft()
        })
    }
    private func syncScreenshotFolderDraft() {
        draft.screenshotWatchingEnabled = state.library.preferences.screenshotWatchingEnabled
        draft.managesSystemScreenshots = state.library.preferences.managesSystemScreenshots
        draft.screenshotSetupVersion = state.library.preferences.screenshotSetupVersion
        draft.screenshotFolder = state.library.preferences.screenshotFolder
        draft.screenshotFolderBookmark = state.library.preferences.screenshotFolderBookmark
    }
    private func save() {
        state.saveLocalPreferences(draft)
    }
    private var screenshotManagementBinding: Binding<Bool> {
        if state.distribution == .direct { return $draft.managesSystemScreenshots }
        return Binding(get: { state.library.preferences.managesSystemScreenshots }, set: {
            state.setSystemScreenshotManagement($0)
            syncScreenshotFolderDraft()
        })
    }
}
