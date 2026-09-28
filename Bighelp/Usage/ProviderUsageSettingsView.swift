import SwiftUI

/// Settings › Provider Usage: which of the computer's providers the Provider
/// Usage overlay shows. All of them until you hide one; saved on this device.
struct ProviderUsageSettingsView: View {
    @Environment(\.providerUsage) private var store
    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenRaw = ""
    @BighelpThemeReader private var theme

    private var hidden: Set<String> { ProviderUsagePreferences.hidden(hiddenRaw) }

    var body: some View {
        Form {
            Section {
                if let providers = store?.report?.providers, !providers.isEmpty {
                    ForEach(providers) { provider in
                        Toggle(isOn: shown(provider.id)) {
                            HStack(spacing: BighelpTokens.space12) {
                                AIProviderMarkView(providerID: ProviderUsagePresentation.logoProviderID(provider.id),
                                                   providerName: provider.name, context: .chatQuickChoice, size: 26)
                                    .frame(width: 34, height: 34)
                                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .fill(theme.isDarkPalette ? Color(white: 0.16) : .white))
                                Text(provider.name)
                            }
                        }
                        .accessibilityIdentifier("settings.provider-usage.\(provider.id)")
                    }
                } else {
                    Text(emptyText)
                        .foregroundStyle(theme.secondaryText)
                        .accessibilityIdentifier("settings.provider-usage.empty")
                }
            } header: {
                Text("Show in Provider Usage")
            } footer: {
                Text("The providers set up on your computer. New ones show until you turn them off.")
            }
            .listRowBackground(theme.surface)

            if !hidden.isEmpty {
                Section {
                    Button("Show All") { hiddenRaw = "" }
                        .accessibilityIdentifier("settings.provider-usage.show-all")
                }
                .listRowBackground(theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(theme.canvas.ignoresSafeArea())
        .navigationTitle("Provider Usage")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard let store, store.report == nil else { return }
            await store.load(refresh: false)
        }
    }

    private var emptyText: String {
        switch store?.state {
        case .needsPluginUpdate?: "Update the bighelp plugin on your computer to see its providers."
        case .unavailable(let message)?: message
        case .loaded?: "No AI tools found on your computer."
        default: "Looking for providers on your computer…"
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(id) },
            set: { isShown in
                var next = hidden
                if isShown { next.remove(id) } else { next.insert(id) }
                hiddenRaw = ProviderUsagePreferences.raw(next)
            }
        )
    }
}
