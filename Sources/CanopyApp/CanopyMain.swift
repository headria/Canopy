import AppKit
import CanopyCore
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState!
    private var shelf: ShelfPanelController!
    private var shortcuts: GlobalShortcuts?
    private var statusItem: NSStatusItem!
    private var subscriptions: Set<AnyCancellable> = []
    private var terminating = false
    private var shuttingDown = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureMainMenu()
        let arguments = CommandLine.arguments
        let demo = arguments.contains("--demo") || Bundle.main.object(forInfoDictionaryKey: "CanopyPreviewMode") as? Bool == true
        let directory: URL
        if demo { directory = FileManager.default.temporaryDirectory.appendingPathComponent("CanopyPreview-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true) }
        else {
            // Keep the existing library and Preview namespace through the rebrand.
            directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Canopy", isDirectory: true)
        }
        state = AppState(repository: FileLibraryRepository(directory: directory), demo: demo)
        if demo && arguments.contains("--permission-demo") {
            state.previewMeetingPermissionRecovery(showPrompt: arguments.contains("--permission-prompt-demo"))
        }
        shelf = ShelfPanelController(state: state)
        if demo && arguments.contains("--trace-presentation") {
            shelf.$presentation.sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    print("Canopy preview: \(self.shelf.presentation.mode); window visible: \(self.shelf.panel.isVisible)")
                    fflush(stdout)
                }
            }.store(in: &subscriptions)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self; statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        state.$recording.combineLatest(state.$recordingTransition).sink { [weak self] recording, starting in
            self?.updateStatus(recording: recording, starting: starting)
        }.store(in: &subscriptions)
        if !demo {
            shortcuts = GlobalShortcuts { [weak self] id in
                if id == 1 { self?.shelf.toggle() } else { self?.state.takeScreenshot() }
            }
        }
        if let tabIndex = arguments.firstIndex(of: "--tab"), arguments.indices.contains(tabIndex + 1),
           let tab = ShelfTab.allCases.first(where: { $0.rawValue.lowercased() == arguments[tabIndex + 1] }) { state.tab = tab }
        if demo {
            if arguments.contains("--tab") { shelf.showWorkspace(state.tab) }
            else if arguments.contains("--peek"), let capture = state.library.captures.first { shelf.captureArrived(capture.id) }
            else { shelf.showShelf() }
        }
        if let snapshotIndex = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(snapshotIndex + 1) {
            let output = arguments[snapshotIndex + 1]
            if !demo { shelf.showShelf() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.snapshot(to: output) }
        }
        if !demo {
            let recovered = state.library.meetings.indices.filter { state.library.meetings[$0].endedAt == nil }
            for index in recovered {
                state.library.meetings[index].endedAt = Date()
                let notice = "[Previous capture ended when \(ProductBrand.name) closed.]"
                state.library.meetings[index].notes += "\n\n" + notice
                if let rich = state.library.meetings[index].richNotes, let updated = try? rich.appendingPlainText(notice) { state.library.meetings[index].richNotes = updated }
            }
            if !recovered.isEmpty { state.saveNow() }
            CaptureDragProvider.cleanStaleTransfers()
            state.startScreenshotWatching()
            state.startCaptureEditWatching()
            if AppDistribution.current == .appStore && !UserDefaults.standard.bool(forKey: "store.didShowScreenshotSetup.v2") {
                UserDefaults.standard.set(true, forKey: "store.didShowScreenshotSetup.v2")
                shelf.showWorkspace(.captures)
            }
        }
    }
    private func updateStatus(recording: Bool, starting: Bool) {
        statusItem?.button?.image = recording || starting
            ? NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "\(ProductBrand.name) is listening")
            : CanopyArtwork.menuBarImage
        statusItem?.button?.contentTintColor = recording || starting ? .systemRed : nil
        statusItem?.button?.title = recording ? " REC" : starting ? " …" : ""
        statusItem?.button?.toolTip = recording ? "\(ProductBrand.name) is listening. Open to stop." : "\(ProductBrand.name) · Shelf ⌃⌥Space · Capture ⌃⌥S"
    }

    private func configureMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem(); applicationItem.submenu = NSMenu(title: ProductBrand.name)
        for (title, action, key) in [("Show / Hide Shelf", #selector(toggleShelf), " "),
                                     ("Capture Region", #selector(captureRegion), "s")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = [.control, .option]; item.target = self
            applicationItem.submenu?.addItem(item)
        }
        applicationItem.submenu?.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit \(ProductBrand.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        applicationItem.submenu?.addItem(quitItem); main.addItem(applicationItem)
        let editItem = NSMenuItem(); editItem.submenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                       ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editItem.submenu?.addItem(withTitle: title, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        main.addItem(editItem); NSApp.mainMenu = main
    }
    @objc private func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            shelf.menuBarMouseDown(at: NSEvent.mouseLocation)
            let menu = NSMenu()
            menu.addItem(withTitle: "Open \(ProductBrand.name)", action: #selector(openShelf), keyEquivalent: "")
            menu.addItem(withTitle: "Capture region", action: #selector(captureRegion), keyEquivalent: "")
            if state.recording { menu.addItem(withTitle: "Stop listening", action: #selector(stopListening), keyEquivalent: "") }
            menu.addItem(.separator())
            menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
            menu.addItem(withTitle: "Quit \(ProductBrand.name)", action: #selector(quit), keyEquivalent: "q")
            for item in menu.items { item.target = self }
            if let button = statusItem.button { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY), in: button) }
        } else { shelf.toggle() }
    }
    @objc private func openShelf() { shelf.showShelf() }
    @objc private func toggleShelf() { shelf.toggle() }
    @objc private func captureRegion() { state.takeScreenshot() }
    @objc private func stopListening() { Task { await state.stopMeeting() } }
    @objc private func openSettings() { shelf.showWorkspace(.settings) }
    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        shelf?.reopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminating { return .terminateNow }
        if !shuttingDown {
            shuttingDown = true
            Task {
                shelf.shutdown(); shortcuts?.shutdown(); await state.shutdown()
                terminating = true
                sender.terminate(nil)
            }
        }
        // AppKit's terminateLater enters a nested run loop. If terminate was called
        // inside a main-queue block, that loop cannot execute main-actor cleanup.
        // Return to the event loop, finish cleanup, then reissue termination.
        return .terminateCancel
    }
    private func snapshot(to path: String) {
        guard let view = shelf.panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: URL(fileURLWithPath: path)) }
        NSApp.terminate(nil)
    }
}

@main
struct CanopyMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
