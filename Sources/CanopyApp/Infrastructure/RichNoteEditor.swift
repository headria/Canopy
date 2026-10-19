import AppKit
import CanopyCore
import SwiftUI
import WebKit

/// One offline document editor. Swift owns identity, persistence and export;
/// the bundled editor owns text selection, formatting and undo.
struct RichNoteEditor: NSViewRepresentable {
    let state: AppState
    let meetingID: UUID

    func makeCoordinator() -> Coordinator { Coordinator(state: state, meetingID: meetingID) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(context.coordinator, name: "canopyNotes")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.allowsLinkPreview = false
        view.navigationDelegate = context.coordinator
        context.coordinator.webView = view
        state.registerNoteEditor(context.coordinator.token) { [weak coordinator = context.coordinator] in await coordinator?.flush() }
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "NoteEditor") {
            context.coordinator.resourceURL = url
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            DispatchQueue.main.async { state.banner = "The notes editor is missing from this app bundle. Reinstall Canopy; your notes are preserved." }
        }
        return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {
        // Library publishes on each edit. Reloading here would reset the caret and undo.
    }
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        Task { @MainActor in
            await coordinator.flush(in: nsView)
            nsView.configuration.userContentController.removeScriptMessageHandler(forName: "canopyNotes")
            nsView.stopLoading()
            coordinator.state.unregisterNoteEditor(coordinator.token)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let state: AppState
        let meetingID: UUID
        let token = UUID()
        private var session = UUID()
        private var lastRevision = -1
        private var loaded = false
        private var restarts = 0
        weak var webView: WKWebView?
        var resourceURL: URL?
        init(state: AppState, meetingID: UUID) { self.state = state; self.meetingID = meetingID }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame,
                  let resourceURL, let frameURL = message.frameInfo.request.url, frameURL.isFileURL,
                  frameURL.standardizedFileURL.path == resourceURL.standardizedFileURL.path,
                  let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            if kind == "ready" { openDocument(); return }
            guard matchesIdentity(body) else { return }
            switch kind {
            case "loaded": loaded = true
            case "change": apply(body)
            case "transient": state.noteEditorTransient(token, open: body["open"] as? Bool == true)
            case "openLink":
                if let address = body["url"] as? String, RichMeetingNotes.isWebLink(address), let url = URL(string: address) { NSWorkspace.shared.open(url) }
            case "error":
                loaded = false
                state.banner = "This formatted note could not be opened. Its saved content is preserved."
            default: break
            }
        }
        private func openDocument() {
            guard let webView, let meeting = state.library.meetings.first(where: { $0.id == meetingID }) else { return }
            session = UUID(); lastRevision = -1; loaded = false
            state.noteEditorTransient(token, open: false)
            let config: [String: Any] = ["meetingID": meetingID.uuidString, "session": session.uuidString,
                                        "plainText": meeting.notes, "json": meeting.richNotes?.json as Any? ?? NSNull()]
            webView.callAsyncJavaScript("window.canopyNotes.open(config)", arguments: ["config": config], in: nil, in: .page) { [weak self] result in
                if case .failure = result { Task { @MainActor in self?.state.banner = "Could not open the notes editor. Your saved notes are preserved." } }
            }
        }
        private func matchesIdentity(_ body: [String: Any]) -> Bool {
            guard let rawSession = body["session"] as? String, UUID(uuidString: rawSession) == session,
                  let rawID = body["meetingID"] as? String, UUID(uuidString: rawID) == meetingID else { return false }
            return true
        }
        private func apply(_ body: [String: Any]) {
            guard state.library.meetings.contains(where: { $0.id == meetingID }) else { return }
            guard matchesIdentity(body), let revision = body["revision"] as? Int, revision > lastRevision,
                  let json = body["json"] as? String, let markdown = body["markdown"] as? String,
                  let text = body["plainText"] as? String else { return }
            do {
                let notes = try RichMeetingNotes(json: json, markdown: markdown)
                guard state.updateRichNotes(notes, plainText: text, meetingID: meetingID) else { throw MeetingNotesError.invalidDocument }
                lastRevision = revision
            } catch {
                loaded = false
                state.banner = "The note editor paused because it could not save. The previous saved version is preserved; you can copy the visible text before reopening."
                webView?.callAsyncJavaScript("window.canopyNotes.blockSaving()", arguments: [:], in: nil, in: .page, completionHandler: nil)
            }
        }
        func flush(in explicitView: WKWebView? = nil) async {
            guard loaded, let view = explicitView ?? webView else { return }
            await withCheckedContinuation { continuation in
                let ticket = FlushTicket(continuation: continuation, apply: { [weak self] value in
                    if let body = value as? [String: Any] { self?.apply(body) }
                })
                view.callAsyncJavaScript("return window.canopyNotes.snapshot()", arguments: [:], in: nil, in: .page) { result in
                    Task { @MainActor in ticket.finish(try? result.get()) }
                }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    ticket.finish(nil)
                }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            decisionHandler(url?.isFileURL == true && url?.standardizedFileURL.path == resourceURL?.standardizedFileURL.path ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            loaded = false; state.noteEditorTransient(token, open: false)
            if restarts == 0 { restarts += 1; webView.reload() }
            else { state.banner = "The notes editor stopped. Reopen this note to try again; its saved content is preserved." }
        }
    }

    @MainActor
    private final class FlushTicket {
        private var continuation: CheckedContinuation<Void, Never>?
        let apply: (Any?) -> Void
        init(continuation: CheckedContinuation<Void, Never>, apply: @escaping (Any?) -> Void) { self.continuation = continuation; self.apply = apply }
        func finish(_ value: Any?) {
            guard let continuation else { return }
            self.continuation = nil; apply(value); continuation.resume()
        }
    }
}
