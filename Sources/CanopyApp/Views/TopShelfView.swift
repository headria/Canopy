import AppKit
import CanopyCore
import SwiftUI

/// A small, nonactivating surface for screenshots. The workspace is an explicit
/// destination rather than the default response to every capture.
struct TopShelfView: View {
    @ObservedObject var state: AppState
    let arrivalID: UUID?
    let openShelf: () -> Void
    let openWorkspace: (ShelfTab) -> Void
    let dismiss: () -> Void

    private var captures: [Capture] {
        if let arrivalID { return state.library.captures.filter { $0.id == arrivalID } }
        return Array(state.library.captures.sorted { $0.createdAt > $1.createdAt }.prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            if arrivalID != nil { arrivalToolbar } else { shelfToolbar }
            if !captures.isEmpty {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(captures) { capture in
                        HangingCapture(state: state, capture: capture, large: arrivalID != nil)
                    }
                }
            } else {
                Text("Click Capture or press ⌃⌥S, then drag a region.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(CanopyTheme.ink.opacity(0.94), in: Capsule()).padding(.top, 9)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers.prefix(20) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in state.importImages([url]) }
                }
            }
            return !providers.isEmpty
        }
    }

    private var arrivalToolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(CanopyTheme.accent)
            Text("On your shelf").font(.system(size: 11, weight: .medium))
            railButton("square.stack", help: "Show recent screenshots", action: openShelf)
            railButton("chevron.up", help: "Tuck away", action: dismiss)
        }.padding(.leading, 12).padding(.trailing, 5).frame(height: 32).railCapsule()
    }

    private var shelfToolbar: some View {
        HStack(spacing: 4) {
            BrandMark(size: 15).foregroundStyle(CanopyTheme.accent)
                .padding(.leading, 7).padding(.trailing, 3).help(CanopyArtwork.name)
            Button { openWorkspace(.captures) } label: {
                Text("\(state.library.captures.count) on shelf")
                    .font(.system(size: 11, weight: .medium)).padding(.trailing, 5)
            }.buttonStyle(.plain).help("Open screenshot library")
            divider
            Button(action: state.takeScreenshot) {
                Label("Capture", systemImage: "camera")
                    .font(.system(size: 11, weight: .semibold)).padding(.horizontal, 8).frame(height: 26)
                    .background(CanopyTheme.accent.opacity(0.18), in: Capsule())
            }.buttonStyle(.plain).help("Capture a region · ⌃⌥S")
                .accessibilityLabel("Capture region").disabled(state.captureBusy)
            railButton("square.stack.3d.up", help: "Open library") { openWorkspace(.captures) }
            railButton(state.recording ? "waveform.circle.fill" : "waveform", help: "Meeting notes") { openWorkspace(.meetings) }
                .foregroundStyle(state.recording ? Color.red : Color.white)
            railButton("slider.horizontal.3", help: "Settings") { openWorkspace(.settings) }
            divider
            railButton(state.isPinnedOpen ? "pin.fill" : "pin", help: state.isPinnedOpen ? "Unpin shelf" : "Keep shelf open") { state.isPinnedOpen.toggle() }
            railButton("chevron.up", help: "Tuck away · ⌃⌥Space", action: dismiss)
        }.padding(.horizontal, 5).frame(height: 36).railCapsule()
    }

    private var divider: some View { Rectangle().fill(.white.opacity(0.18)).frame(width: 1, height: 14).padding(.horizontal, 4) }
    private func railButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).frame(width: 26, height: 26).contentShape(Circle()) }
            .buttonStyle(RailButtonStyle()).help(help).accessibilityLabel(help)
    }
}

private struct HangingCapture: View {
    @ObservedObject var state: AppState
    let capture: Capture
    let large: Bool
    @State private var image: CGImage?
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 10)
            VStack(spacing: 0) {
                ZStack {
                    CanopyTheme.ink
                    if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                }.frame(height: large ? 110 : 86).clipped()
                .contentShape(Rectangle())
                .overlay { CaptureInteractionView(state: state, capture: capture, thumbnail: image) }
                .overlay(alignment: .topLeading) {
                    if capture.isPinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).padding(5)
                            .background(CanopyTheme.ink.opacity(0.9), in: Circle()).padding(5)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    Button { state.removeCapture(capture) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white).frame(width: 22, height: 22)
                            .background(CanopyTheme.ink.opacity(0.94), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                    }.buttonStyle(.plain).padding(5).help("Discard screenshot")
                        .accessibilityLabel("Discard \(capture.title)")
                }
                HStack(spacing: 5) {
                    Text(copied ? "Copied" : (large ? "Click to edit · drag to share" : capture.title))
                        .font(.system(size: 9, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: copied ? "checkmark" : "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold)).opacity(copied || hovering ? 1 : 0.4)
                }.foregroundStyle(.white.opacity(0.88)).padding(.horizontal, 8).frame(height: 24)
                    .background(CanopyTheme.ink)
            }
            .frame(width: large ? 200 : 132)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.white.opacity(hovering ? 0.55 : 0.22), lineWidth: 1))
            .overlay(alignment: .top) { Capsule().fill(CanopyTheme.accent).frame(width: 17, height: 3).offset(y: -1) }
            .shadow(color: .black.opacity(0.22), radius: 5, y: 3)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .contextMenu {
                Button("Copy image", action: copyImage)
                Button("Copy recognized text") { state.copyText(capture.extractedText) }.disabled(capture.extractedText.isEmpty)
                Button(capture.isPinned ? "Unpin" : "Pin") { state.togglePin(capture) }
                Button("Open in Preview", action: openImage)
                Button("Save a copy…") { state.saveCaptureCopy(capture) }
                Button("Reveal file") { if let url = state.captureURL(capture) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                Divider()
                Button("Discard screenshot", role: .destructive) { state.removeCapture(capture) }
            }
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
        }
        .task(id: state.captureRevisions[capture.id, default: 0]) {
            guard let url = state.captureURL(capture) else { return }
            let thumbnail = await CaptureThumbnailStore.shared.image(at: url)
            if !Task.isCancelled { image = thumbnail }
        }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(nanoseconds: 1_500_000_000); copied = false } catch { }
        }
    }
    private func copyImage() { state.copyCapture(capture); copied = true }
    private func openImage() { state.openCaptureInPreview(capture) }
}

private struct RailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(.white.opacity(configuration.isPressed ? 0.2 : 0), in: Circle())
    }
}

private extension View {
    func railCapsule() -> some View {
        self.foregroundStyle(.white)
            .background(CanopyTheme.ink.opacity(0.94), in: Capsule())
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
    }
}
