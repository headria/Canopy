import AppKit
import CanopyCore
import SwiftUI
import UniformTypeIdentifiers

struct CaptureShelfView: View {
    @ObservedObject var state: AppState
    @State private var dropTarget = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(text: "Your visual working memory")
                    Text("Keep a good thing close.").font(.system(size: 26, weight: .medium, design: .rounded)).tracking(-0.6)
                }
                Spacer()
                Button { state.chooseImages() } label: { Label("Import", systemImage: "plus") }.buttonStyle(CanopyButtonStyle())
                Button { state.takeScreenshot() } label: { Label(state.captureBusy ? "Selecting…" : "Capture", systemImage: "viewfinder") }
                    .buttonStyle(CanopyButtonStyle(primary: true)).disabled(state.captureBusy)
                    .help("Capture a region straight to the top shelf · ⌃⌥S")
            }
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(CanopyTheme.muted)
                    TextField("Find a capture or its text", text: $state.search).textFieldStyle(.plain)
                }.padding(10).frame(width: 260).canopyCard()
                Spacer()
                Menu {
                    Toggle("Detect new screenshots", isOn: Binding(get: { state.library.preferences.screenshotWatchingEnabled }, set: state.setScreenshotWatching))
                    if state.distribution.managesScreenshotSettings {
                        Toggle("Keep screenshots only in Canopy", isOn: Binding(get: { state.library.preferences.managesSystemScreenshots }, set: state.setSystemScreenshotManagement))
                        Button("Use macOS screenshot location") { state.useSystemScreenshotFolder() }
                    }
                    Button("Choose screenshot folder…") { state.watchFolder() }
                    if state.watchedFolder != nil {
                        Button("Reveal screenshot folder") { NSWorkspace.shared.open(state.screenshotDirectory) }
                    }
                } label: { Label(state.isDemo ? "Automatic screenshots" : state.screenshotWatchLabel, systemImage: state.watchedFolder == nil ? "folder.badge.plus" : "eye") }
                    .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    .help("Copy new screenshots from a folder you choose, or pause folder detection.")
            }
            if state.distribution == .appStore {
                HStack(spacing: 16) {
                    Image(systemName: "viewfinder").font(.system(size: 25)).foregroundStyle(CanopyTheme.primary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Capture. Drag. Done.").font(.system(size: 13, weight: .semibold))
                        Text("Press ⌃⌥S anywhere, then drag a region. It appears on the top shelf, ready to share. No Desktop file or corner preview.")
                            .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    }
                    Spacer()
                    Text("⌃ ⌥ S").font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .padding(12).background(CanopyTheme.accent.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                }.padding(16).canopyCard()
            }
            if state.captureNeedsSettings {
                HStack(spacing: 12) {
                    Text("Screen capture access is needed for this action. Your existing screenshots and notes are still available.")
                        .font(.system(size: 11)).foregroundStyle(CanopyTheme.muted)
                    Spacer()
                    Button("Open Settings") { state.openMeetingPermissionSettings(.screenRecording) }
                        .buttonStyle(CanopyButtonStyle(compact: true))
                }.padding(16).canopyCard()
            }
            if state.sortedCaptures.isEmpty {
                EmptyCard(symbol: "rectangle.on.rectangle.angled", title: state.search.isEmpty ? "Your shelf starts here." : "No matching captures.",
                          detail: "Click Capture or press ⌃⌥S to select a region. Drag a screenshot to another app, or discard it with ×.")
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 18)], spacing: 20) {
                        ForEach(state.sortedCaptures) { capture in CaptureCard(state: state, capture: capture) }
                    }.padding(.top, 14).padding(.bottom, 10)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "text.viewfinder")
                Text("Text is recognized on your Mac. Click to edit in Preview · Drag to share a copy")
            }.font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
        }.padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 18).foregroundStyle(CanopyTheme.ink)
            .overlay { if dropTarget { RoundedRectangle(cornerRadius: 18).stroke(CanopyTheme.ink, style: StrokeStyle(lineWidth: 2, dash: [6])).padding(8) } }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in state.importImages([url]) } }
                    }
                }
                return !providers.isEmpty
            }
    }
}

struct CaptureCard: View {
    @ObservedObject var state: AppState
    let capture: Capture
    @State private var image: CGImage?
    @State private var hovered = false
    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(CanopyTheme.ink.opacity(0.2)).frame(width: 1, height: 12)
                .overlay(alignment: .bottom) { Capsule().fill(CanopyTheme.ink).frame(width: 24, height: 4).offset(y: 2) }
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                        else { Image(systemName: "photo").font(.system(size: 24)).foregroundStyle(CanopyTheme.muted) }
                    }.frame(maxWidth: .infinity).frame(height: 150).background(CanopyTheme.border.opacity(0.35))
                        .contentShape(Rectangle())
                        .overlay { CaptureInteractionView(state: state, capture: capture, thumbnail: image) }
                    VStack {
                        Button { state.removeCapture(capture) } label: {
                            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 26, height: 26).background(CanopyTheme.ink.opacity(0.94), in: Circle())
                        }.buttonStyle(.plain).help("Discard screenshot").accessibilityLabel("Discard \(capture.title)")
                    }.padding(8)
                }.clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
                VStack(alignment: .leading, spacing: 8) {
                    Text(capture.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack {
                        Text(capture.createdAt, style: .time).font(.system(size: 10)).foregroundStyle(CanopyTheme.muted)
                        Spacer()
                        IconButton(symbol: capture.isPinned ? "pin.slash" : "pin", help: capture.isPinned ? "Unpin" : "Pin") { state.togglePin(capture) }
                        if !capture.extractedText.isEmpty {
                            IconButton(symbol: "text.alignleft", help: "Copy recognized text") { state.copyText(capture.extractedText) }
                        }
                    }
                }.padding(12)
            }.canopyCard().shadow(color: CanopyTheme.ink.opacity(hovered ? 0.12 : 0.05), radius: hovered ? 12 : 6, y: 5)
                .offset(y: hovered ? -3 : 0).animation(.easeOut(duration: 0.18), value: hovered)
        }.onHover { hovered = $0 }
            .task(id: state.captureRevisions[capture.id, default: 0]) {
                guard let url = state.captureURL(capture) else { return }
                let thumbnail = await CaptureThumbnailStore.shared.image(at: url)
                if !Task.isCancelled { image = thumbnail }
            }
            .contextMenu {
                Button("Copy image") { state.copyCapture(capture) }
                Button("Copy text") { state.copyText(capture.extractedText) }.disabled(capture.extractedText.isEmpty)
                Button(capture.isPinned ? "Unpin" : "Pin") { state.togglePin(capture) }
                Button("Open in Preview") { state.openCaptureInPreview(capture) }
                Button("Save a copy…") { state.saveCaptureCopy(capture) }
                Button("Reveal file") { if let url = state.captureURL(capture) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Divider()
                Button("Discard screenshot", role: .destructive) { state.removeCapture(capture) }
            }
    }
}
