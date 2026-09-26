import SwiftUI

/// An actual conversation-file destination, never a workspace or import shortcut.
@MainActor
struct ChatSessionFilesView: View {
    let model: ChatModel
    @Environment(\.dismiss) private var dismiss

    private struct Entry: Identifiable {
        let id: String
        let attachment: ChatAttachment
    }

    private var entries: [Entry] {
        let messages = model.items.flatMap { item in
            item.attachments.enumerated().map { index, attachment in
                Entry(id: "message:\(item.id):\(index):\(attachment.id)", attachment: attachment)
            }
        }
        let generated = model.activityLedger.allEvents.flatMap { event in
            (event.generatedMedia?.attachments ?? []).enumerated().map { index, attachment in
                Entry(id: "activity:\(event.id):\(index):\(attachment.id)", attachment: attachment)
            }
        }
        return messages + generated
    }

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView("No files in loaded messages", systemImage: "doc")
                } else {
                    Section {
                        ForEach(entries) { entry in
                            ChatAttachmentGallery(attachments: [entry.attachment], alignsTrailing: false)
                        }
                    } footer: {
                        Text("Files from messages currently loaded in this chat.")
                    }
                }
            }
            .navigationTitle("Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .accessibilityIdentifier("chat.session-files")
        }
    }
}
