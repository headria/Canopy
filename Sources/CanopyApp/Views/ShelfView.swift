import AppKit
import CanopyCore
import SwiftUI

struct ShelfView: View {
    @ObservedObject var state: AppState
    let collapse: () -> Void
    let dismiss: () -> Void
    let dragChanged: (Bool) -> Void
    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            if let banner = state.banner {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                    Text(banner).font(.system(size: 11)).lineLimit(3).textSelection(.enabled)
                    Spacer()
                    Button { state.banner = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss message")
                }.foregroundStyle(CanopyTheme.ink).padding(.horizontal, 22).padding(.vertical, 10)
                    .background(CanopyTheme.accent.opacity(0.45))
            }
            Group {
                switch state.tab {
                case .captures: CaptureShelfView(state: state)
                case .meetings: MeetingView(state: state)
                case .settings: SettingsView(state: state)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(CanopyTheme.paper)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.65), lineWidth: 1))
        .preferredColorScheme(.light)
        .tint(CanopyTheme.primary)
        .font(.system(size: 12))
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshMeetingPermissions()
        }
    }
    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                BrandMark(size: 20).foregroundStyle(CanopyTheme.accent)
                Text(CanopyArtwork.name).font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer(minLength: 16)
            }
            .overlay { WorkspaceDragHandle(dragChanged: dragChanged) }
            .help("Drag the title area to move the window")
            if state.recording || state.recordingTransition {
                HStack(spacing: 6) {
                    Circle().fill(Color(red: 1, green: 0.51, blue: 0.43)).frame(width: 6, height: 6)
                    Text(state.recording ? "LISTENING" : "CONNECTING").font(.system(size: 9, weight: .bold, design: .monospaced)).tracking(1)
                    if state.recording { Button("Stop") { Task { await state.stopMeeting() } }.buttonStyle(.plain).padding(.leading, 6) }
                }.padding(10).background(.white.opacity(0.08), in: Capsule())
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "lock.shield"); Text("LOCAL FIRST")
                }.font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(1).foregroundStyle(CanopyTheme.accent)
            }
            Button(action: state.takeScreenshot) { Image(systemName: "camera").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Capture region · ⌃⌥S").accessibilityLabel("Capture region")
                .disabled(state.captureBusy)
            Button(action: collapse) { Image(systemName: "chevron.up").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Back to small shelf").accessibilityLabel("Back to small shelf")
            Button(action: dismiss) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Close · Escape").accessibilityLabel("Close workspace")
        }.foregroundStyle(.white).padding(.horizontal, 22).padding(.vertical, 10).background(CanopyTheme.ink)
    }
    private var navigation: some View {
        HStack(spacing: 6) {
            ForEach(ShelfTab.allCases) { tab in
                Button { state.tab = tab } label: {
                    HStack(spacing: 7) {
                        Image(systemName: tab.symbol)
                        Text(tab.rawValue)
                        if tab == .captures, !state.library.captures.isEmpty {
                            Text("\(state.library.captures.count)").font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 2)
                                .background(CanopyTheme.ink.opacity(0.08), in: Capsule())
                        }
                    }.font(.system(size: 12, weight: .semibold)).padding(.horizontal, 15).padding(.vertical, 10)
                        .foregroundStyle(state.tab == tab ? CanopyTheme.ink : CanopyTheme.muted)
                        .background(state.tab == tab ? CanopyTheme.surface : Color.clear, in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(state.tab == tab ? .isSelected : [])
            }
            Spacer()
            if state.isDemo { Text("PREVIEW LIBRARY").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(CanopyTheme.muted) }
        }.padding(.horizontal, 20).padding(.vertical, 12)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(CanopyTheme.ink.opacity(0.5)).frame(width: 4, height: 4)
            Text(state.recording ? "Transcribing on this Mac · No audio saved" : CanopyArtwork.tagline)
            Spacer()
            Text("⌃ ⌥ SPACE").font(.system(size: 9, weight: .medium, design: .monospaced))
            Text("to open").foregroundStyle(CanopyTheme.muted.opacity(0.7))
        }.font(.system(size: 10)).foregroundStyle(CanopyTheme.muted).padding(.horizontal, 24).padding(.vertical, 12)
            .overlay(alignment: .top) { Rectangle().fill(CanopyTheme.border.opacity(0.5)).frame(height: 1) }
    }
}
