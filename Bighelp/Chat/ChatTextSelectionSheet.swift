import SwiftUI
import UIKit

struct NativeTextSelectionSheet: View {
    let text: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            NativeSelectableTextView(text: text)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .accessibilityIdentifier("chat.message.text-selection")
    }
}

private struct NativeSelectableTextView: UIViewRepresentable {
    let text: String

    final class Coordinator {
        var selectedInitialWord = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.adjustsFontForContentSizeCategory = true
        view.font = UIFont.bighelp(.body)
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 20, right: 16)
        view.accessibilityLabel = "Selectable message from \(text.isEmpty ? "agent" : "chat")"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if view.text != text {
            view.text = text
            context.coordinator.selectedInitialWord = false
        }
        guard !context.coordinator.selectedInitialWord, !text.isEmpty else { return }
        context.coordinator.selectedInitialWord = true
        let range = (text as NSString).rangeOfCharacter(from: .alphanumerics)
        guard range.location != NSNotFound else { return }
        DispatchQueue.main.async {
            view.selectedRange = range
            _ = view.becomeFirstResponder()
        }
    }
}
