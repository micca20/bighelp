import SwiftUI

struct LoopdyMacInspector: View {
    let session: LoopdyFoundationSession?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Session Details")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)

                if let session {
                    detail("Agent", value: session.agentName, symbol: "person.crop.circle")
                    detail("Messages", value: session.events.count.formatted(), symbol: "text.bubble")
                    detail("Identity", value: session.id, symbol: "number")

                    Divider()
                    Label("Canonical state", systemImage: "checkmark.seal.fill")
                        .font(.subheadline.weight(.medium))
                    Text("The desktop shell resolves this stable foundation session identifier across its sidebar, conversation canvas, and composer. Existing iOS SessionRecord data projects into the same identity and source ordering through a tested adapter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()
                    Label("Native runtime deferred", systemImage: "clock.badge")
                        .font(.subheadline.weight(.medium))
                    Text("This foundation tracer does not embed the native agent runtime from issue 25.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No Details", systemImage: "sidebar.right")
                }
            }
            .padding(18)
        }
        .background(.regularMaterial)
        .accessibilityIdentifier("mac.inspector")
    }

    private func detail(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.body)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct LoopdyMacSettingsView: View {
    let reduceTransparency: Bool
    let reduceMotion: Bool
    let increasedContrast: Bool

    var body: some View {
        Form {
            Section("Appearance") {
                LabeledContent("Color") {
                    Text("Follows System")
                }
                LabeledContent("Transparency") {
                    Text(reduceTransparency ? "Reduced" : "Native materials")
                }
                LabeledContent("Contrast") {
                    Text(increasedContrast ? "Increased" : "Standard")
                }
                LabeledContent("Motion") {
                    Text(reduceMotion ? "Reduced" : "Standard")
                }
            }
            Section("Foundation") {
                Label("Session browsing", systemImage: "checkmark.circle.fill")
                Label("Conversation composition", systemImage: "checkmark.circle.fill")
                Label("Keyboard commands", systemImage: "checkmark.circle.fill")
                Label("Native agent runtime deferred", systemImage: "clock")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .accessibilityIdentifier("mac.settings-route")
    }
}
