import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SessionSectionDropDelegate: DropDelegate {
    let targetKey: SessionSectionKey
    @Binding var draggedKey: SessionSectionKey?
    @Binding var lastDropTargetKey: SessionSectionKey?
    let move: (SessionSectionKey, SessionSectionKey) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggedKey != nil && info.hasItemsConforming(to: SessionSectionDragPayload.contentTypes)
    }

    func dropEntered(info: DropInfo) {
        guard
            validateDrop(info: info),
            let draggedKey,
            draggedKey != targetKey,
            lastDropTargetKey != targetKey
        else { return }
        lastDropTargetKey = targetKey
        move(draggedKey, targetKey)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedKey = nil
        lastDropTargetKey = nil
        return true
    }
}

enum SessionSectionDragPayload {
    static let contentTypes = [UTType(exportedAs: "app.loopdy.session-section", conformingTo: .data)]

    static func provider(for key: SessionSectionKey) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(key.rawValue.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: contentTypes[0].identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
