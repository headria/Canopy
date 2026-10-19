import AppKit
import CanopyCore
import Carbon
import Combine
import CoreGraphics
import SwiftUI

final class ShelfPanel: NSPanel {
    var allowsKeyboardFocus = false
    override var canBecomeKey: Bool { allowsKeyboardFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class ShelfPanelController: ObservableObject {
    let panel: ShelfPanel
    @Published private(set) var presentation = ShelfPresentation()
    private let state: AppState
    private var timer: Timer?
    private var hoverReveal = ShelfHoverReveal()
    private var escapeMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: NSObjectProtocol?
    private var pendingCapture: UUID?
    private var captureSuppressed = false
    private var previousApp: NSRunningApplication?
    private var screen: NSScreen?
    private var compactContent: NSView?
    private var workspaceContent: NSView?
    private var dismissalGeneration = UUID()
    private var workspacePlacement = WorkspacePlacement()
    private var workspaceDragging = false
    var isVisible: Bool { presentation.mode != .hidden && !captureSuppressed }

    init(state: AppState, monitorsPointer: Bool = true) {
        self.state = state
        if let frame = state.library.preferences.workspaceFrame { workspacePlacement.remember(frame.rectangle) }
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 180),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.hasShadow = false; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.contentView = NSHostingView(rootView: ShelfSurfaceView(state: state, controller: self))
        compactContent = panel.contentView
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, let self, self.isVisible, event.window === self.panel,
               self.state.noteEditorTransientTokens.isEmpty,
               (self.panel.firstResponder as? NSTextView)?.hasMarkedText() != true {
                self.hide(); return nil
            }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isVisible else { return }
                self.selectScreen(); self.position()
            }
        }
        if monitorsPointer {
            let presses: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: presses) { [weak self] _ in
                let point = NSEvent.mouseLocation
                Task { @MainActor in
                    self?.workspaceMouseDown(at: point, fromOtherApp: true)
                    self?.menuBarMouseDown(at: point)
                }
            }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: presses) { [weak self] event in
                // Preserve the status button's normal show/hide toggle on mouse-up.
                self?.menuBarMouseDown(at: NSEvent.mouseLocation, dismissShelf: false)
                if !NSScreen.screens.contains(where: { Self.menuBarContains(NSEvent.mouseLocation, frame: $0.frame, visibleFrame: $0.visibleFrame) }) {
                    self?.workspaceMouseDown(at: NSEvent.mouseLocation, in: event.window)
                }
                return event
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.checkPointer() }
            }
        }
        state.beforeCapture = { [weak self] in self?.beginCapture() }
        state.onCaptureAdded = { [weak self] id in self?.captureArrived(id) }
        state.onCaptureRemoved = { [weak self] id in
            guard let self else { return }
            if self.presentation.mode == .arrival(id) { self.hide() }
            else if self.isVisible { self.position() }
        }
        state.onCaptureOpen = { [weak self] in self?.hide() }
        state.onCaptureInteractionEnded = { [weak self] in self?.endInteraction() }
        state.afterCapture = { [weak self] in
            guard let self else { return }
            self.endCapture()
            // A failed request from the compact shelf must remain actionable.
            // Cancellation has no error and quietly returns to the previous app.
            if self.state.captureError != nil { self.showWorkspace(.captures) }
        }
    }

    func toggle() {
        switch presentation.mode {
        case .hidden, .arrival: showShelf()
        case .shelf, .workspace: hide()
        }
    }

    func reopen() {
        if presentation.mode == .workspace {
            guard !captureSuppressed, !state.captureBusy else { return }
            showWorkspace(state.tab)
            panel.orderFrontRegardless()
        } else { showShelf() }
    }

    func showShelf(explicitly: Bool = true) {
        guard !state.captureBusy else { return }
        if !isVisible { selectScreen() }
        update { $0.openShelf(at: Date(), explicitly: explicitly) }
    }

    func showWorkspace(_ tab: ShelfTab) {
        guard !state.captureBusy else { return }
        if !isVisible { selectScreen() }
        if presentation.mode != .workspace { previousApp = NSWorkspace.shared.frontmostApplication }
        state.tab = tab
        update { $0.openWorkspace() }
        NSApp.activate(ignoringOtherApps: true); panel.makeKey()
    }

    func captureArrived(_ id: UUID) {
        if state.captureBusy || state.captureInteractionActive { pendingCapture = id; return }
        if !isVisible { selectScreen() }
        update { $0.captureArrived(id, at: Date()) }
        if presentation.mode != .workspace, isVisible {
            // A logically visible shelf can be behind another window or on the
            // previous display. Every arrival presents it on the working screen.
            selectScreen(); position(); panel.orderFrontRegardless()
        }
    }

    func hide() {
        hide(restoringFocus: true)
    }

    private func hide(restoringFocus: Bool) {
        hoverReveal.disarm(); state.isPinnedOpen = false
        update(restoringFocus: restoringFocus) { $0.hide() }
    }

    private func beginCapture() {
        pendingCapture = nil
        if presentation.mode == .workspace {
            // Keep the SwiftUI hierarchy (including an unsent question or settings
            // draft) alive while excluding our window from the screen capture.
            captureSuppressed = true; panel.orderOut(nil)
            restoreFocus(clear: false)
        } else { hide() }
    }

    private func endCapture() {
        if captureSuppressed {
            captureSuppressed = false
            position(); panel.orderFrontRegardless()
            NSApp.activate(ignoringOtherApps: true); panel.makeKey()
        }
        if let id = pendingCapture { pendingCapture = nil; captureArrived(id) }
    }

    private func endInteraction() {
        if let id = pendingCapture, !state.captureBusy {
            pendingCapture = nil; captureArrived(id)
        } else { update { $0.resumeAfterInteraction(at: Date()) } }
    }

    private func restoreFocus(clear: Bool = true) {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           let previousApp, !previousApp.isTerminated,
           previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp.activate(options: [])
        }
        if clear { previousApp = nil }
    }

    private func update(restoringFocus: Bool = true, _ change: (inout ShelfPresentation) -> Void) {
        let wasVisible = isVisible
        let wasWorkspace = presentation.mode == .workspace
        var next = presentation; change(&next)
        guard next != presentation else { return }
        let leavingWorkspace = wasWorkspace && next.mode != .workspace
        if leavingWorkspace {
            workspacePlacement.remember(panel.frame)
            // Save before switching the shared panel to temporary shelf geometry.
            state.rememberWorkspaceFrame(panel.frame)
            workspaceDragging = false
            panel.orderOut(nil)
        }
        panel.allowsKeyboardFocus = next.mode == .workspace
        panel.isMovable = next.mode == .workspace
        dismissalGeneration = UUID()
        presentation = next
        if leavingWorkspace {
            if restoringFocus { restoreFocus() }
            else { previousApp = nil }
        }
        if !isVisible { panel.orderOut(nil); return }
        if next.mode == .workspace {
            if workspaceContent == nil {
                workspaceContent = NSHostingView(rootView: ShelfView(state: state,
                    collapse: { [weak self] in self?.showShelf() },
                    dismiss: { [weak self] in self?.hide() },
                    dragChanged: { [weak self] in self?.workspaceDragChanged($0) }))
            }
            panel.contentView = workspaceContent
        } else {
            panel.contentView = compactContent
        }
        position()
        if !wasVisible || leavingWorkspace {
            panel.alphaValue = 0; panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in context.duration = 0.16; panel.animator().alphaValue = 1 }
        }
    }

    private func selectScreen() {
        let point = NSEvent.mouseLocation
        screen = NSScreen.screens.first(where: {
            $0.frame.contains(point) || Self.menuBarContains(point, frame: $0.frame, visibleFrame: $0.visibleFrame)
        }) ?? NSScreen.main
    }

    private func position() {
        guard let screen = screen ?? NSScreen.main else { return }
        if presentation.mode == .workspace {
            guard !workspaceDragging else { return }
            let frame = workspacePlacement.frame(on: NSScreen.screens.map(\.visibleFrame), preferredDisplay: screen.visibleFrame)
            panel.hasShadow = true
            panel.setFrame(frame, display: true)
            workspacePlacement.remember(frame)
            return
        }
        let frame = screen.visibleFrame
        let size: NSSize
        switch presentation.mode {
        case .workspace: return
        case .arrival: size = NSSize(width: 244, height: 196)
        case .shelf:
            let count = min(4, state.library.captures.count)
            let cardsWidth = CGFloat(count * 132 + max(0, count - 1) * 12 + 24)
            size = NSSize(width: min(max(420, cardsWidth), frame.width - 20), height: count == 0 ? 100 : 176)
        case .hidden: return
        }
        panel.hasShadow = presentation.mode == .workspace
        let top = min(frame.maxY, screen.frame.maxY - max(NSStatusBar.system.thickness, screen.safeAreaInsets.top))
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: top - size.height - 3, width: size.width, height: size.height), display: true)
    }

    func workspaceDragChanged(_ dragging: Bool) {
        if dragging {
            guard presentation.mode == .workspace, !captureSuppressed else { return }
            workspaceDragging = true
        } else {
            guard workspaceDragging else { return }
            workspaceDragging = false
            if presentation.mode == .workspace {
                workspacePlacement.remember(panel.frame)
                position()
                state.rememberWorkspaceFrame(panel.frame)
            }
        }
    }

    private func checkPointer() {
        checkPointer(at: NSEvent.mouseLocation, now: Date(), mouseButtons: NSEvent.pressedMouseButtons)
    }

    /// Also used by native integration tests without moving the real pointer.
    func checkPointer(at point: NSPoint, now: Date, mouseButtons: Int = 0, menuIsOpen: Bool? = nil) {
        guard !state.captureBusy, !state.captureInteractionActive, !workspaceDragging, !state.isDemo else {
            hoverReveal.suspend(); return
        }
        let hoveredScreen = NSScreen.screens.first { Self.menuBarContains(point, frame: $0.frame, visibleFrame: $0.visibleFrame) }
        let display = hoveredScreen.flatMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value }
        let shouldReveal = hoverReveal.sample(display: display,
                                             eligible: !isVisible && state.library.preferences.revealOnHover && mouseButtons == 0,
                                             at: now)
        if isVisible {
            update { $0.tick(at: now, pointerInside: pointerIsInside(point), pinned: state.isPinnedOpen) }
        } else if shouldReveal, let hoveredScreen {
            guard !(menuIsOpen ?? Self.hasOpenMenu(on: hoveredScreen)) else { return }
            screen = hoveredScreen
            update { $0.openShelf(at: now, explicitly: false) }
        }
    }

    func menuBarMouseDown(at point: NSPoint, dismissShelf: Bool = true) {
        guard NSScreen.screens.contains(where: { Self.menuBarContains(point, frame: $0.frame, visibleFrame: $0.visibleFrame) }) else { return }
        hoverReveal.disarm()
        if dismissShelf, presentation.mode != .workspace, !state.isPinnedOpen, !state.captureInteractionActive { hide() }
    }

    /// Outside clicks dismiss only the large workspace. Leave the receiving
    /// app's event and focus intact; the compact shelf keeps its existing policy.
    func workspaceMouseDown(at point: NSPoint, in eventWindow: NSWindow? = nil, fromOtherApp: Bool = false) {
        guard isVisible, presentation.mode == .workspace,
              !state.captureBusy, !state.captureInteractionActive, !workspaceDragging,
              panel.attachedSheet == nil, NSApp.modalWindow == nil,
              !panel.frame.contains(point) else { return }
        var owner = eventWindow
        while let window = owner {
            if window === panel { return }
            owner = window.parent ?? window.sheetParent
        }
        // App-owned picker menus can extend beyond the panel's frame.
        if let eventWindow, eventWindow.level.rawValue >= NSWindow.Level.popUpMenu.rawValue { return }
        let focusTarget = previousApp
        hide(restoringFocus: false)
        if fromOtherApp {
            let token = dismissalGeneration
            // Give the clicked app time to activate. For nonactivating menu-bar
            // extras, restore the prior app only if Canopy still owns focus.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, focusTarget] in
                guard let self, self.dismissalGeneration == token,
                      self.presentation.mode == .hidden, NSApp.modalWindow == nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                      let focusTarget, !focusTarget.isTerminated,
                      focusTarget.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                focusTarget.activate(options: [])
            }
        }
    }

    static func menuBarRect(frame: NSRect, visibleFrame: NSRect) -> NSRect {
        // visibleFrame excludes the displayed menu bar, including taller bars
        // on notched screens. An auto-hidden bar retains a narrow top trigger.
        let height = max(4, frame.maxY - visibleFrame.maxY)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    static func menuBarContains(_ point: NSPoint, frame: NSRect, visibleFrame: NSRect) -> Bool {
        let bar = menuBarRect(frame: frame, visibleFrame: visibleFrame)
        return point.x >= bar.minX && point.x < bar.maxX && point.y >= bar.minY && point.y <= bar.maxY
    }

    private static func hasOpenMenu(on screen: NSScreen) -> Bool {
        // Window layers and bounds cover keyboard-opened menus too. No window
        // content is captured; the query runs only when a hover would reveal.
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return false }
        let layer = CGWindowLevelForKey(.popUpMenuWindow)
        return windows.contains { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.int32Value == layer,
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
            // CGWindow bounds use a top-left origin relative to the main display.
            let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
            let appKitRect = NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
            return appKitRect.intersects(screen.frame)
        }
    }

    private func pointerIsInside(_ point: NSPoint) -> Bool {
        if panel.frame.contains(point) { return true }
        if presentation.mode == .workspace { return false }
        if let screen, Self.menuBarContains(point, frame: screen.frame, visibleFrame: screen.visibleFrame) { return true }
        // Keep the route from the menu bar to the shelf's toolbar available.
        if let screen, point.y >= panel.frame.maxY - 42, point.y <= screen.frame.maxY,
           abs(point.x - panel.frame.midX) < max(150, panel.frame.width / 2) { return true }
        return false
    }

    func shutdown() {
        dismissalGeneration = UUID()
        timer?.invalidate()
        panel.orderOut(nil)
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        state.beforeCapture = nil; state.afterCapture = nil; state.onCaptureAdded = nil; state.onCaptureRemoved = nil; state.onCaptureOpen = nil; state.onCaptureInteractionEnded = nil
        panel.contentView = nil; workspaceContent = nil; compactContent = nil
    }
}

private struct ShelfSurfaceView: View {
    @ObservedObject var state: AppState
    @ObservedObject var controller: ShelfPanelController
    var body: some View {
        switch controller.presentation.mode {
        case .workspace:
            EmptyView()
        case .arrival(let id):
            TopShelfView(state: state, arrivalID: id, openShelf: { controller.showShelf() }, openWorkspace: controller.showWorkspace, dismiss: controller.hide)
        case .hidden, .shelf:
            TopShelfView(state: state, arrivalID: nil, openShelf: { controller.showShelf() }, openWorkspace: controller.showWorkspace, dismiss: controller.hide)
        }
    }
}

/// Carbon hot keys avoid requiring Accessibility permission for a keyboard monitor.
@MainActor
final class GlobalShortcuts {
    private var keys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    let action: (UInt32) -> Void
    init(action: @escaping (UInt32) -> Void) {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, data in
            guard let event, let data else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let owner = Unmanaged<GlobalShortcuts>.fromOpaque(data).takeUnretainedValue()
            Task { @MainActor in owner.action(id.id) }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        register(code: UInt32(kVK_Space), id: 1)
        register(code: UInt32(kVK_ANSI_S), id: 2)
    }
    private func register(code: UInt32, id: UInt32) {
        var key: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x434E5059, id: id)
        if RegisterEventHotKey(code, UInt32(controlKey | optionKey), identifier, GetApplicationEventTarget(), 0, &key) == noErr, let key { keys.append(key) }
    }
    func shutdown() {
        keys.forEach { UnregisterEventHotKey($0) }; keys = []
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
}
