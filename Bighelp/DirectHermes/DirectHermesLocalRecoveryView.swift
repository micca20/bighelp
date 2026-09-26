import SwiftUI

/// Recovery remains readable even when a new, never-submitted native session
/// never obtained a durable database row. This surface never sends or resumes.
struct DirectHermesLocalRecoveryView: View {
    let records: [DirectHermesDraftStore.RecoveryRecord]

    var body: some View {
        List {
            Section {
                Text("Drafts stay with this host account and profile. A retained submission may already have reached Hermes, so check history before copying it into another chat.")
                    .bighelpFont(.body)
                    .foregroundStyle(.secondary)
            } header: { Text("Before you copy") }
            ForEach(records) { entry in
                Section {
                    if !entry.record.draft.isEmpty {
                        Text("Draft").bighelpFont(.metadata).foregroundStyle(.secondary)
                        Text(entry.record.draft)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("direct-hermes.recovered-draft.\(entry.id)")
                    }
                    ForEach(entry.record.unresolved) { submission in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(submission.rejectionCode == nil ? "Uncertain submission" : "Not sent")
                                .bighelpFont(.metadata).foregroundStyle(.secondary)
                            Text(submission.text).textSelection(.enabled)
                            if let attachments = submission.attachments, !attachments.isEmpty {
                                ChatAttachmentGallery(attachments: attachments, alignsTrailing: false)
                            }
                        }
                    }
                } header: {
                    Text(entry.record.owner?.title ?? "Local draft")
                } footer: {
                    if let owner = entry.record.owner { Text("Profile: \(owner.profile) · Original Hermes session: \(owner.storedID)") }
                }
            }
        }
        .navigationTitle("Local recovery")
        .navigationBarTitleDisplayMode(.inline)
    }
}
