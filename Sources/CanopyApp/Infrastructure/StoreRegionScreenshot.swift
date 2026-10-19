import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

enum RegionCaptureGeometry {
    /// ScreenCaptureKit uses a top-left desktop origin; AppKit uses bottom-left.
    static func screenRect(from appKitRect: CGRect, primaryScreenTop: CGFloat) -> CGRect {
        CGRect(x: appKitRect.minX, y: primaryScreenTop - appKitRect.maxY,
            width: appKitRect.width, height: appKitRect.height)
    }
}

@MainActor
enum StoreRegionScreenshot {
    static func capture(to url: URL) async throws -> Bool {
        guard #available(macOS 26.0, *) else { throw CocoaError(.featureUnsupported) }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw StoreScreenshotError.permissionDenied }
        guard let rectangle = await RegionSelectionController.shared.select() else { return false }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: rectangle.midX, y: rectangle.midY)) }) else {
            throw CocoaError(.fileReadUnknown)
        }
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = rectangle.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        configuration.width = max(1, Int(rectangle.width * CGFloat(filter.pointPixelScale)))
        configuration.height = max(1, Int(rectangle.height * CGFloat(filter.pointPixelScale)))
        configuration.showsCursor = false
        // Excluding the app removes its shelf/selector even before the window
        // server has applied an orderOut, avoiding a timing-dependent shade.
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return true
    }
}

enum StoreScreenshotError: LocalizedError {
    case permissionDenied
    var errorDescription: String? {
        "Allow Canopy in System Settings → Privacy & Security → Screen & System Audio Recording to capture your selected screen region, then try Capture region again."
    }
}

/// Selection draws only an overlay. No display pixels are read until mouse-up.
@MainActor
private final class RegionSelectionController {
    static let shared = RegionSelectionController()
    private var panels: [NSPanel] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?
    private var escapeMonitor: Any?
    private var screenMonitor: Any?
    private var selectionToken: UUID?
    func select() async -> CGRect? {
        guard continuation == nil else { return nil }
        let token = UUID()
        return await withTaskCancellationHandler {
          guard !Task.isCancelled else { return nil }
          return await withCheckedContinuation { continuation in
            selectionToken = token
            self.continuation = continuation
            guard let primary = NSScreen.screens.first else { finish(nil, token: token); return }
            NSApp.activate()
            for screen in NSScreen.screens {
                let panel = RegionPanel(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
                panel.isReleasedWhenClosed = false; panel.isOpaque = false
                panel.backgroundColor = .clear; panel.hasShadow = false
                panel.level = .screenSaver; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                let view = RegionSelectionView(frame: NSRect(origin: .zero, size: screen.frame.size)) { [weak self] rectangle in
                    let global = rectangle?.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                    self?.finish(global.map { RegionCaptureGeometry.screenRect(from: $0, primaryScreenTop: primary.frame.maxY) }, token: token)
                }
                panel.contentView = view; panel.makeFirstResponder(view)
                panels.append(panel); panel.orderFrontRegardless()
                if screen.frame.contains(NSEvent.mouseLocation) { panel.makeKey() }
            }
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 { self?.finish(nil, token: token); return nil }
                return event
            }
            screenMonitor = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.finish(nil, token: token) }
            }
          }
        } onCancel: {
            Task { @MainActor in self.finish(nil, token: token) }
        }
    }
    private func finish(_ rectangle: CGRect?, token: UUID) {
        guard selectionToken == token else { return }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }; escapeMonitor = nil
        if let screenMonitor { NotificationCenter.default.removeObserver(screenMonitor) }; screenMonitor = nil
        panels.forEach { $0.orderOut(nil); $0.close() }; panels.removeAll()
        let continuation = self.continuation; self.continuation = nil; selectionToken = nil
        continuation?.resume(returning: rectangle)
    }
}

private final class RegionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
private final class RegionSelectionView: NSView {
    private var anchor: CGPoint?
    private var selection = CGRect.zero
    private let completion: (CGRect?) -> Void
    init(frame: NSRect, completion: @escaping (CGRect?) -> Void) { self.completion = completion; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func mouseDown(with event: NSEvent) { anchor = convert(event.locationInWindow, from: nil) }
    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(x: min(anchor.x, point.x), y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x), height: abs(point.y - anchor.y)).intersection(bounds)
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        guard anchor != nil else { return }
        mouseDragged(with: event)
        completion(selection.width >= 2 && selection.height >= 2 ? selection : nil)
    }
    override func cancelOperation(_ sender: Any?) { completion(nil) }
    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        if !selection.isEmpty { shade.appendRect(selection) }
        shade.windingRule = .evenOdd; NSColor.black.withAlphaComponent(0.28).setFill(); shade.fill()
        if !selection.isEmpty { NSColor.white.setStroke(); let border = NSBezierPath(rect: selection); border.lineWidth = 1; border.stroke() }
        let text = "Drag to capture · Escape to cancel" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: bounds.height - 68), withAttributes: attributes)
    }
}
