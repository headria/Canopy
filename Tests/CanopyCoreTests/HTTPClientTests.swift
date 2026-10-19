import CanopyCore
import Foundation
import Testing

private final class StubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "stub.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == "/wait" { return }
        let code = Int(url.lastPathComponent) ?? 200
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = Data(#"{"choices":[{"message":{"content":"A validated answer"}}]}"#.utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct HTTPClientTests {
    private func client() -> HTTPAssistantClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return HTTPAssistantClient(session: URLSession(configuration: configuration))
    }
    private func settings(path: String) -> AssistantSettings {
        AssistantSettings(provider: .compatible, endpoint: "https://stub.invalid/\(path)", model: "test-model")
    }
    @Test func responsePassesThroughInjectedTransport() async throws {
        let response = try await client().answer(settings: settings(path: "200"), apiKey: "fake", messages: [AssistantMessage(role: "user", text: "Question")], context: "")
        #expect(response == "A validated answer")
    }
    @Test(arguments: [401, 429, 500]) func httpErrorsRetainTheirStatusWithoutProviderBody(_ status: Int) async {
        do {
            _ = try await client().answer(settings: settings(path: "\(status)"), apiKey: "fake", messages: [], context: "")
            Issue.record("Expected HTTP \(status) to fail")
        } catch { #expect(error as? ServiceError == .http(status)) }
    }
    @Test func cancellationStopsPendingTransport() async {
        let client = client(), settings = settings(path: "wait")
        let task = Task { try await client.answer(settings: settings, apiKey: "fake", messages: [], context: "") }
        for _ in 0..<10 { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled request unexpectedly succeeded") }
        catch { #expect((error as? URLError)?.code == .cancelled || error is CancellationError) }
    }
}
