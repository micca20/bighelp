import SwiftUI

typealias ReferenceSendAction = @MainActor (ReferenceFrozenDraft, MidSessionChatBehavior?) async -> Void
struct ReferenceSendHandler {
    let action: ReferenceSendAction
}

/// Cache revisions remain unconsumed while another provider or preview owns the
/// drawer. Observe readiness too, so that finishing that work drains one refresh.
@MainActor
struct ReferenceDiscoveryRefresh: ViewModifier {
    let hub: ReferenceHubStore
    let revision: Int?
    @State private var consumedRevision: Int?

    init(hub: ReferenceHubStore, revision: Int?) {
        self.hub = hub
        self.revision = revision
        _consumedRevision = State(initialValue: revision)
    }

    private struct RefreshKey: Equatable {
        let revision: Int?
        let isReady: Bool
    }

    private var isReady: Bool {
        hub.isPresented && !hub.isLoading && !hub.isResolving && hub.preview == nil
    }

    func body(content: Content) -> some View {
        let key = RefreshKey(revision: revision, isReady: isReady)
        content.onChange(of: key) { _, current in
            guard current.isReady, isReady, let revision = current.revision, revision != consumedRevision else { return }
            // Consume before refreshSearch changes readiness. Never bind/resetDraft,
            // dismiss a preview, or request editor focus for a display publication.
            consumedRevision = revision
            hub.refreshSearch()
        }
    }
}

/// Skills and commands remain available in chat. Retired provider references in
/// saved transcripts keep their renderer; new provider submissions are unavailable.
@MainActor
struct ReferenceChatComposition<Content: View>: View {
    let model: ChatModel
    let catalog: SessionCatalogStore
    let featureStore: ShellFeatureStore
    let appState: AppState
    @ViewBuilder let content: (ReferenceHubStore, ReferenceSendHandler) -> Content
    @State private var hub = ReferenceHubStore(owner: nil, providers: [])

    var body: some View {
        content(hub, ReferenceSendHandler(action: { _, _ in
            hub.showMessage("GitHub and Wiki references are no longer available. Your draft has been kept.")
        }))
    }
}
