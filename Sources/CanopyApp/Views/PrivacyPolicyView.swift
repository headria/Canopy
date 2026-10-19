import SwiftUI

struct PrivacyPolicyView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Your privacy in \(CanopyArtwork.name)").font(.system(size: 22, weight: .semibold))
            ScrollView {
                Text(policy).font(.system(size: 12)).lineSpacing(5).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let url = Self.publicURL(for: "CanopyPrivacyPolicyURL") { Link("Published privacy policy", destination: url) }
                if let url = Self.publicURL(for: "CanopySupportURL") { Link("Support", destination: url) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    .buttonStyle(CanopyButtonStyle(primary: true))
            }
        }.padding(24).frame(width: 600, height: 540)
            .foregroundStyle(CanopyTheme.ink).background(CanopyTheme.paper)
            .tint(CanopyTheme.primary).preferredColorScheme(.light)
    }
    private var policy: String {
        guard let url = Bundle.main.url(forResource: "PrivacyPolicy", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Screenshots, notes and meeting transcripts stay on your Mac. AI tools are unavailable in this version. See the product page for the full privacy policy."
        }
        return text
    }
    static func publicURL(for key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }
}
