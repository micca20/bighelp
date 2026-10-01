import SwiftUI

/// Historical context is a projection of the exact message, never a provider
/// lookup. Selecting it cannot grant access, refresh data or load remote media.
struct ReferenceHistoryView: View {
    let snapshots: [ReferenceSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshots, id: \.identityKey) { snapshot in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Context saved with this message. It has not been refreshed.")
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                        ReferenceSnapshotSource(snapshot: snapshot)
                        Text(snapshot.fetchedAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.bighelp(.caption)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                } label: {
                    Label(snapshot.displayLabel, systemImage: "doc.text.magnifyingglass")
                        .font(.bighelp(.subheadline))
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("reference-history.snapshot.\(snapshot.identityKey)")
            }
        }
        .padding(12)
        .bighelpSurface(.input)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reference-history.snapshots")
    }
}
