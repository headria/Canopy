import AppKit
import SwiftUI

/// Only the title area moves the window. Header buttons, text selection and
/// screenshot drags keep their own mouse handling.
struct WorkspaceDragHandle: NSViewRepresentable {
    let dragChanged: (Bool) -> Void
    func makeNSView(context: Context) -> WorkspaceTitleArea {
        let view = WorkspaceTitleArea()
        view.dragChanged = dragChanged
        return view
    }
    func updateNSView(_ view: WorkspaceTitleArea, context: Context) { view.dragChanged = dragChanged }
    static func dismantleNSView(_ view: WorkspaceTitleArea, coordinator: ()) { view.finishDragging() }
}

@MainActor
final class WorkspaceTitleArea: NSView {
    var dragChanged: ((Bool) -> Void)?
    private var anchor: (pointer: NSPoint, origin: NSPoint)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        guard event.type == .leftMouseDown, let window, window.isMovable else { return }
        finishDragging()
        anchor = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
        dragChanged?(true)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor, let window, window.isMovable else { return }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(NSPoint(x: anchor.origin.x + point.x - anchor.pointer.x,
                                      y: anchor.origin.y + point.y - anchor.pointer.y))
    }
    override func mouseUp(with event: NSEvent) { finishDragging() }
    func finishDragging() {
        guard anchor != nil else { return }
        anchor = nil
        dragChanged?(false)
    }
}
