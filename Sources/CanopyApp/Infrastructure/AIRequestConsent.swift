import CanopyCore
import Foundation

/// Immutable request content: changing the selection or endpoint while reviewing
/// consent cannot send different text or credentials to a different recipient.
struct AIRequestConsent: Identifiable {
    enum Action {
        case answer(settings: AssistantSettings, history: [AssistantMessage], context: String)
        case summary(settings: AssistantSettings, meetingID: UUID, context: String)
        case signals(endpoint: String, meetingID: UUID, text: String)
    }
    let id = UUID()
    let action: Action
    var endpoint: String {
        switch action {
        case .answer(let settings, _, _), .summary(let settings, _, _): return settings.endpoint
        case .signals(let endpoint, _, _): return endpoint
        }
    }
    var recipient: String { URL(string: endpoint)?.host ?? endpoint }
    var content: String {
        switch action {
        case .answer(_, let history, let context):
            return PromptBuilder.requestPreview(messages: history, context: context)
        case .summary(_, _, let context):
            return PromptBuilder.requestPreview(messages: [AssistantMessage(role: "user", text: PromptBuilder.summary)], context: context)
        case .signals(_, _, let text): return text
        }
    }
}
