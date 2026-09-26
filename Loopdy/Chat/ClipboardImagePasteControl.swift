import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Native, user-initiated image paste for editing surfaces without an iOS paste hook.
struct ClipboardImagePasteControl: UIViewRepresentable {
    let onPaste: ([NSItemProvider]) -> Void

    func makeUIView(context: Context) -> TargetView {
        TargetView(onPaste: onPaste)
    }

    func updateUIView(_ view: TargetView, context: Context) {
        view.onPaste = onPaste
    }

    static func dismantleUIView(_ view: TargetView, coordinator: ()) {
        view.onPaste = nil
        view.pasteConfiguration = nil
    }

    final class TargetView: UIView {
        var onPaste: (([NSItemProvider]) -> Void)?

        init(onPaste: @escaping ([NSItemProvider]) -> Void) {
            self.onPaste = onPaste
            super.init(frame: .zero)
            pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [UTType.image.identifier])
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = .iconAndLabel
            let control = UIPasteControl(configuration: configuration)
            control.target = self
            control.accessibilityLabel = "Paste Image"
            control.accessibilityIdentifier = "chat.composer.expanded.paste-image"
            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor),
                control.trailingAnchor.constraint(equalTo: trailingAnchor),
                control.topAnchor.constraint(equalTo: topAnchor),
                control.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        required init?(coder: NSCoder) { nil }

        override func paste(itemProviders: [NSItemProvider]) {
            guard window != nil else { return }
            onPaste?(itemProviders)
        }
    }
}
