import SwiftUI

@MainActor
struct BighelpLinkRenameDeviceView: View {
    let store: BighelpLinkDeviceStore
    let deviceID: String
    let initialName: String

    @State private var name: String

    init(store: BighelpLinkDeviceStore, deviceID: String, initialName: String) {
        self.store = store
        self.deviceID = deviceID
        self.initialName = initialName
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Form {
            Section {
                TextField("Device name", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .onSubmit(save)
                    .accessibilityIdentifier("link.rename-device.field")
            } footer: {
                Text("Use a name that helps you recognize this device. Device names are not security credentials.")
                    .bighelpFont(.metadata)
            }

            if let validationError = store.renameValidationError {
                Section {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("link.rename-device.validation")
                }
            }

            if let actionError = store.actionError {
                Section {
                    Label(actionError, systemImage: "arrow.clockwise.circle")
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("link.rename-device.error")
                }
            }
        }
        .bighelpFormSurface()
        .environment(\.defaultMinListRowHeight, BighelpTokens.hitTarget)
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Rename Device")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    .bighelpToolbarText()
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save", action: save)
                    .disabled(store.pendingAction != nil)
                    .accessibilityIdentifier("link.rename-device.save")
            }
        }
        .interactiveDismissDisabled(store.pendingAction != nil)
    }

    private func save() {
        let originalRevision = store.device(id: deviceID)?.revision
        Task {
            await store.renameDevice(id: deviceID, name: name)
            guard
                store.renameValidationError == nil,
                store.actionError == nil,
                let originalRevision,
                store.device(id: deviceID)?.revision != originalRevision
            else { return }
            dismiss()
        }
    }

    @Environment(\.dismiss) private var dismiss
    @BighelpThemeReader private var theme
}
