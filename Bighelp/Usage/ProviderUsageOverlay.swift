import SwiftUI

/// Presents Provider Usage over whatever is on screen and shares the store
/// with the screens that open it (chat ⋯, ☰, the context window, Settings).
struct ProviderUsageHost: ViewModifier {
    @Bindable var store: ProviderUsageStore
    let hostName: String?
    let onOpenSettings: () -> Void

    func body(content: Content) -> some View {
        content
            .environment(\.providerUsage, store)
            .fullScreenCover(isPresented: $store.isPresented) {
                ProviderUsageOverlay(store: store, hostName: hostName, onOpenSettings: onOpenSettings)
                    .presentationBackground(.clear)
            }
    }
}

extension ProviderUsageStore {
    /// Shows the overlay without the full-screen slide; the panel fades in itself.
    func show(agentID: String) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { present(agentID: agentID) }
    }
}

/// A floating Liquid Glass panel: one card per provider with its logo, what's
/// left of each limit, balances, and a link to manage the account.
struct ProviderUsageOverlay: View {
    let store: ProviderUsageStore
    var hostName: String?
    var onOpenSettings: () -> Void = {}

    @AppStorage(ProviderUsagePreferences.hiddenKey) private var hiddenRaw = ""
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @BighelpThemeReader private var theme

    private var providers: [ProviderUsage] {
        ProviderUsagePresentation.visible(store.report?.providers ?? [], hidden: ProviderUsagePreferences.hidden(hiddenRaw))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(appeared ? 0.2 : 0)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            panel
                .frame(maxWidth: 460)
                .padding(.horizontal, BighelpTokens.space16)
                .padding(.vertical, BighelpTokens.space24)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.94)
                .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(response: 0.35, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-usage")
    }

    /// Hugs its cards; scrolls only when they'd run past the screen.
    private var panel: some View {
        ViewThatFits(in: .vertical) {
            panelChrome {
                VStack(spacing: BighelpTokens.space12) { content }
                    .padding(.horizontal, BighelpTokens.space16)
                    .padding(.bottom, BighelpTokens.space20)
            }
            panelChrome {
                ScrollView {
                    VStack(spacing: BighelpTokens.space12) { content }
                        .padding(.horizontal, BighelpTokens.space16)
                        .padding(.bottom, BighelpTokens.space20)
                }
                .scrollBounceBehavior(.basedOnSize)
                .refreshable { await store.load(refresh: true) }
            }
        }
    }

    private func panelChrome<Body: View>(@ViewBuilder _ body: () -> Body) -> some View {
        VStack(spacing: 0) {
            header
            body()
        }
        .background { panelBackground }
        .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 36, style: .continuous)
                .strokeBorder(.white.opacity(theme.isDarkPalette ? 0.12 : 0.55), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.14), radius: 30, y: 12)
    }

    @ViewBuilder
    private var panelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 36, style: .continuous)
        if reduceTransparency {
            shape.fill(theme.surface)
        } else {
            #if os(visionOS)
            Color.clear.glassBackgroundEffect(in: shape)
            #else
            if #available(iOS 26.0, *) {
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                shape.fill(.ultraThinMaterial)
            }
            #endif
        }
    }

    private var header: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: BighelpTokens.space4) {
                Text("Provider Usage")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(theme.primaryText)
                    .accessibilityAddTraits(.isHeader)
                Text("Current provider limits")
                    .bighelpFont(.metadata)
                    .foregroundStyle(theme.secondaryText)
                if let updated = ProviderUsagePresentation.updatedText(store.report?.fetchedAt) {
                    Button {
                        Task { await store.load(refresh: true) }
                    } label: {
                        HStack(spacing: 4) {
                            if store.isRefreshing {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                            Text(updated)
                        }
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.tertiaryText)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isRefreshing)
                    .accessibilityLabel("\(updated). Refresh")
                    .accessibilityIdentifier("provider-usage.refresh")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 56)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(theme.surface.opacity(0.7)))
                    .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .accessibilityIdentifier("provider-usage.close")
        }
        .padding(.top, BighelpTokens.space20)
        .padding(.horizontal, BighelpTokens.space16)
        .padding(.bottom, BighelpTokens.space16)
    }

    @ViewBuilder
    private var content: some View {
        if case .unavailable(let message) = store.state, store.report != nil {
            note(message, systemImage: "exclamationmark.triangle")
        }
        if store.state == .needsPluginUpdate {
            message(title: "Update the bighelp plugin\(hostName.map { " on \($0)" } ?? "") to see usage.",
                    detail: "Provider usage comes from the plugin on your computer.",
                    action: ("Open Settings", openSettings))
        } else if store.report == nil {
            if case .unavailable(let text) = store.state {
                message(title: text, detail: nil, action: ("Try Again", { Task { await store.load(refresh: false) } }))
            } else {
                ProgressView("Checking your computer…")
                    .frame(maxWidth: .infinity, minHeight: 140)
            }
        } else {
            if store.report?.providers.isEmpty == true {
                message(title: "No AI tools found\(hostName.map { " on \($0)" } ?? "").",
                        detail: "bighelp shows coding tools installed on the computer (Claude Code, Codex, Copilot, OpenCode, Gemini CLI) and providers set up in Hermes.",
                        action: nil)
            } else if providers.isEmpty {
                message(title: "All providers are hidden.", detail: "Choose which to show in Settings › Provider Usage.",
                        action: ("Open Settings", openSettings))
            } else {
                ForEach(providers) { ProviderUsageCard(provider: $0) }
            }
        }
    }

    private func message(title: String, detail: String?, action: (String, () -> Void)?) -> some View {
        VStack(spacing: BighelpTokens.space8) {
            Text(title)
                .bighelpFont(.body, weight: .semibold)
                .foregroundStyle(theme.primaryText)
            if let detail {
                Text(detail).bighelpFont(.metadata).foregroundStyle(theme.secondaryText)
            }
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.action)
                    .padding(.top, BighelpTokens.space4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, BighelpTokens.space24)
        .accessibilityIdentifier("provider-usage.message")
    }

    private func note(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .bighelpFont(.metadata)
            .foregroundStyle(theme.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func openSettings() {
        close()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            onOpenSettings()
        }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.18)) { appeared = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(reduceMotion ? 60 : 180))
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { store.isPresented = false }
        }
    }
}

/// One provider: logo, plan, what's left of each limit, balances, and Manage.
struct ProviderUsageCard: View {
    let provider: ProviderUsage
    @Environment(\.openURL) private var openURL
    @BighelpThemeReader private var theme

    var body: some View {
        HStack(alignment: .top, spacing: BighelpTokens.space12) {
            logo
            VStack(alignment: .leading, spacing: BighelpTokens.space4) {
                titleRow
                if provider.status == .ok {
                    windows
                    facts
                } else if let message = provider.message {
                    Text(message)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                footer
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(theme.surface.opacity(provider.status == .ok ? 0.6 : 0.3))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(.white.opacity(theme.isDarkPalette ? 0.08 : 0.5), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider-usage.\(provider.id)")
    }

    private var logo: some View {
        AIProviderMarkView(providerID: ProviderUsagePresentation.logoProviderID(provider.id),
                           providerName: provider.name, context: .chatQuickChoice, size: 34)
            .frame(width: 56, height: 56)
            .background {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .fill(theme.isDarkPalette ? Color(white: 0.16) : .white)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(theme.primaryText.opacity(0.06), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var titleRow: some View {
        HStack(spacing: BighelpTokens.space8) {
            Text(provider.name)
                .font(.headline)
                .foregroundStyle(theme.primaryText)
                .lineLimit(1)
            if let plan = provider.plan { badge(plan, color: theme.secondaryText) }
            if provider.activeInHermes { badge("In use", color: theme.action) }
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .lineLimit(1)
    }

    @ViewBuilder
    private var windows: some View {
        ForEach(Array(provider.windows.enumerated()), id: \.element.id) { index, window in
            let color = ProviderUsagePresentation.barColor(for: provider, window: window, theme: theme)
            let left = ProviderUsagePresentation.percentText(window.leftPercent)
            let reset = ProviderUsagePresentation.resetText(window.resetsAt)
            VStack(alignment: .leading, spacing: 3) {
                if index == 0 {
                    Text(window.detail ?? window.label)
                        .bighelpFont(.body)
                        .foregroundStyle(theme.secondaryText)
                        .monospacedDigit()
                } else {
                    Text(window.label)
                        .bighelpFont(.metadata)
                        .foregroundStyle(theme.secondaryText)
                }
                HStack(spacing: BighelpTokens.space8) {
                    Text((provider.approximate ? "About " : "") + "\(left) left")
                        .font((index == 0 ? Font.subheadline : .caption).weight(.semibold))
                        .foregroundStyle(color)
                        .monospacedDigit()
                    if let reset {
                        Text(reset).font(.caption).foregroundStyle(theme.tertiaryText)
                    }
                }
                ProviderUsageBar(fraction: window.leftPercent / 100, color: color, height: index == 0 ? 8 : 5)
            }
            .padding(.top, index == 0 ? 0 : BighelpTokens.space4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.name), \(window.label), \(Int(window.usedPercent.rounded())) percent used\(reset.map { ", \($0.lowercased())" } ?? "")")
        }
    }

    @ViewBuilder
    private var facts: some View {
        ForEach(provider.facts) { fact in
            HStack {
                Text(fact.label).foregroundStyle(theme.secondaryText)
                Spacer(minLength: BighelpTokens.space8)
                Text(fact.value).foregroundStyle(theme.primaryText).monospacedDigit()
            }
            .bighelpFont(.metadata)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var footer: some View {
        let via = provider.detectedVia.contains("cli") ? "On this computer" : provider.detectedVia.contains("hermes") ? "In Hermes" : nil
        if via != nil || provider.manageURL != nil {
            HStack {
                if let via { Text(via).font(.caption2).foregroundStyle(theme.tertiaryText) }
                Spacer(minLength: 0)
                if let url = provider.manageURL {
                    Button {
                        openURL(url)
                    } label: {
                        Label("Manage", systemImage: "arrow.up.right")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.action)
                    .accessibilityHint("Opens \(provider.name) in the browser")
                    .accessibilityIdentifier("provider-usage.manage.\(provider.id)")
                }
            }
            .padding(.top, 2)
        }
    }
}

struct ProviderUsageBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.16))
                Capsule().fill(color).frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}
