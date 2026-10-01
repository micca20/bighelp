import SwiftUI
import UIKit

/// Opens the system Find and Find and Replace bar on the editor it's attached to.
@MainActor
final class YAMLEditorFinder {
    fileprivate weak var textView: UITextView?

    func present(replacing: Bool) {
        textView?.findInteraction?.presentFindNavigator(showingReplace: replacing)
    }
}

/// A plain-text editor for YAML. Smart quotes, dashes and autocorrect are off
/// because they silently change what Hermes reads, and it has the system's
/// Find and Replace (also Command-F on a keyboard).
struct YAMLTextView: UIViewRepresentable {
    @Binding var text: String
    var isEditable = true
    var finder: YAMLEditorFinder?
    var insets = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: 15, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.autocapitalizationType = .none
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.dataDetectorTypes = []
        view.isFindInteractionEnabled = true
        view.alwaysBounceVertical = true
        #if !os(visionOS)
        view.keyboardDismissMode = .interactive
        #endif
        view.textContainerInset = insets
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        finder?.textView = view
        view.isEditable = isEditable
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textViewDidChange(_ textView: UITextView) {
            if text.wrappedValue != textView.text { text.wrappedValue = textView.text }
        }
    }
}

/// The YAML document with the whole screen to itself. Edits go straight into the
/// same draft, so closing this keeps them; nothing reaches Hermes until Save.
@MainActor
struct RawConfigurationExpandedEditor: View {
    @Bindable var store: RawConfigurationStore
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var finder = YAMLEditorFinder()

    var body: some View {
        NavigationStack {
            YAMLTextView(text: $store.draft, isEditable: store.canEdit, finder: finder,
                         insets: UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12))
                .privacySensitive()
                .accessibilityLabel("Private raw Hermes configuration")
                .accessibilityIdentifier("host.raw-config.expanded-editor")
                .safeAreaInset(edge: .bottom, spacing: 0) { status }
                .navigationTitle("config.yaml")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                            .accessibilityIdentifier("host.raw-config.expanded-done")
                            .bighelpToolbarText()
                    }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Menu {
                            Button("Find", systemImage: "magnifyingglass") { finder.present(replacing: false) }
                                .accessibilityIdentifier("host.raw-config.find")
                            Button("Find and Replace", systemImage: "arrow.left.arrow.right") {
                                finder.present(replacing: true)
                            }
                            .accessibilityIdentifier("host.raw-config.find-replace")
                        } label: {
                            Label("Find", systemImage: "magnifyingglass")
                        }
                        .accessibilityIdentifier("host.raw-config.find-menu")
                        Button("Save") { onSave() }
                            .fontWeight(.semibold)
                            .disabled(!store.canSave)
                            .accessibilityIdentifier("host.raw-config.expanded-save")
                    }
                }
        }
        .expandedEditorSizing()
    }

    private var status: some View {
        HStack {
            Text(store.hasChanges ? "Unsaved changes" : "No changes")
            Spacer()
            if store.remainingBytes < 0 {
                Text("\((-store.remainingBytes).formatted()) bytes over the limit")
                    .foregroundStyle(.red)
            } else {
                Text("\(store.draft.utf8.count.formatted()) bytes")
            }
        }
        .font(.bighelp(.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.vertical, BighelpTokens.space8)
        .background(.bar)
    }
}

private extension View {
    /// A page-sized sheet on iPad and Vision Pro, where a form sheet is too small to edit in.
    @ViewBuilder
    func expandedEditorSizing() -> some View {
        if #available(iOS 18, visionOS 2, *) {
            presentationSizing(.page)
        } else {
            self
        }
    }
}
