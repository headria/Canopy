import AppKit
import CanopyCore
import SwiftUI

/// Native mouse tracking separates click from drag and reports the drag lifetime,
/// including for a nonactivating shelf that receives its very first mouse click.
struct CaptureInteractionView: NSViewRepresentable {
    @ObservedObject var state: AppState
    let capture: Capture
    let thumbnail: CGImage?

    func makeNSView(context: Context) -> CaptureMouseView { CaptureMouseView() }
    func updateNSView(_ view: CaptureMouseView, context: Context) {
        view.source = state.captureURL(capture); view.title = capture.title
        view.thumbnail = thumbnail.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
        view.onOpen = { state.openCaptureInPreview(capture) }
        view.onHold = { held in if held { state.beginCaptureInteraction() } else { state.endCaptureInteraction() } }
        view.onError = { state.banner = "Could not share screenshot: \($0.localizedDescription)" }
        view.setAccessibilityLabel("Edit \(capture.title) in Preview")
        view.setAccessibilityHelp("Click to edit in Preview. Drag to another app to send a copy.")
        let menu = NSMenu()
        menu.addAction("Open in Preview") { state.openCaptureInPreview(capture) }
        menu.addAction("Copy image") { state.copyCapture(capture) }
        if !capture.extractedText.isEmpty { menu.addAction("Copy recognized text") { state.copyText(capture.extractedText) } }
        menu.addAction(capture.isPinned ? "Unpin" : "Pin") { state.togglePin(capture) }
        menu.addAction("Save a copy…") { state.saveCaptureCopy(capture) }
        menu.addItem(.separator())
        menu.addAction("Discard screenshot") { state.removeCapture(capture) }
        view.menu = menu
    }
    static func dismantleNSView(_ view: CaptureMouseView, coordinator: ()) { view.finishInteraction() }
}

@MainActor
final class CaptureMouseView: NSView, NSDraggingSource {
    var source: URL?
    var title = "Screenshot"
    var thumbnail: NSImage?
    var onOpen: (() -> Void)?
    var onHold: ((Bool) -> Void)?
    var onError: ((Error) -> Void)?
    private var downPoint: NSPoint?
    private var provider: CaptureDragProvider?
    private var held = false
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func accessibilityPerformPress() -> Bool { onOpen?(); return true }

    override func mouseDown(with event: NSEvent) {
        guard source != nil else { return }
        downPoint = convert(event.locationInWindow, from: nil)
        didDrag = false; setHeld(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let downPoint, !didDrag, let source else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 4 else { return }
        didDrag = true
        do {
            let snapshot = try CaptureDragSnapshot.read(from: source, title: title)
            let writer = try CaptureDragProvider(snapshot: snapshot)
            provider = writer
            let item = NSDraggingItem(pasteboardWriter: writer)
            let image = thumbnail ?? NSImage(data: snapshot.png)
            let size = image?.size ?? bounds.size
            let scale = min(bounds.width / max(1, size.width), bounds.height / max(1, size.height))
            let frame = NSRect(x: bounds.midX - size.width * scale / 2, y: bounds.midY - size.height * scale / 2,
                               width: size.width * scale, height: size.height * scale)
            item.setDraggingFrame(frame, contents: image)
            let session = beginDraggingSession(with: [item], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = true
        } catch { onError?(error) }
    }
    override func mouseUp(with event: NSEvent) {
        guard provider == nil else { return }
        let opens = downPoint != nil && !didDrag && bounds.contains(convert(event.locationInWindow, from: nil))
        if opens { onOpen?() }
        finishInteraction()
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.contains(.copy), let provider { CaptureDragLifetime.retainForReceiver(provider) }
        else { provider?.removeTransfer() }
        provider = nil; finishInteraction()
    }
    func finishInteraction() {
        // A drag source remains alive until AppKit ends its active session.
        guard provider == nil else { return }
        downPoint = nil
        setHeld(false)
    }
    private func setHeld(_ value: Bool) {
        guard held != value else { return }
        held = value; onHold?(value)
    }
}

private final class CaptureMenuAction: NSObject {
    let invoke: () -> Void
    init(_ invoke: @escaping () -> Void) { self.invoke = invoke }
    @objc func invokeAction() { invoke() }
}
private extension NSMenu {
    func addAction(_ title: String, action: @escaping () -> Void) {
        let handler = CaptureMenuAction(action)
        let item = NSMenuItem(title: title, action: #selector(CaptureMenuAction.invokeAction), keyEquivalent: "")
        item.target = handler; item.representedObject = handler
        addItem(item)
    }
}
