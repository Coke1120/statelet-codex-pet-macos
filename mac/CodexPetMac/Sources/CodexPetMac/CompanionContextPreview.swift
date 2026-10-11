import SwiftUI

/// One bounded, in-memory submission shared by preview and both send actions.
/// Keep the captured attachment text; never reopen files when reviewing/sending.
struct CompanionContextPreview: Identifiable {
    let id = UUID()
    let messages: [CompanionMessage]
    let displayMessage: CompanionMessage
    let prompt: String

    init(history: [CompanionMessage], draft: String, attachments: [CompanionAttachment]) throws {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = attachments.map { "\n\nAttached text (\($0.name)):\n\($0.text)" }.joined()
        messages = history + [CompanionMessage(role: .user, text: text + context)]
        prompt = try CompanionChatPolicy.prompt(messages: messages)
        displayMessage = CompanionMessage(role: .user, text: text + (attachments.isEmpty ? "" : "\n\n📎 " + attachments.map(\.name).joined(separator: ", ")))
    }
}

struct CompanionContextPreviewView: View {
    let preview: CompanionContextPreview
    let onBack: () -> Void
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Review context").font(.headline)
            Text("These messages and attached text will be sent through your Codex connection with Statelet’s chat instructions.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Earlier attachments stay in this conversation. Use New chat to leave earlier context out.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(preview.messages) { message in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(message.id == preview.messages.last?.id ? "YOUR MESSAGE" :
                                 (message.role == .user ? "EARLIER · YOU" : "EARLIER · STATELET"))
                                .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                            Text(message.text).font(.body).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.padding(.trailing, 8)
            }
            Divider()
            HStack {
                Button("Back to draft", action: onBack).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Send", action: onSend).keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
