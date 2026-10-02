import SwiftUI

/// Files an agent sent that are still on their way to this phone: a picture's
/// glow or a file's tile, the same size as what replaces it, in place of the
/// message's raw file line.
struct PendingAgentFilesView: View {
    let fileNames: [String]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal) { row }
                .scrollIndicators(.hidden)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(fileNames.count == 1 ? "Loading \(fileNames[0])" : "Loading \(fileNames.count) files")
        .accessibilityIdentifier("chat.message-attachments.loading")
    }

    private var row: some View {
        HStack(alignment: .bottom, spacing: BighelpTokens.space8) {
            ForEach(Array(fileNames.enumerated()), id: \.offset) { index, name in
                if Self.isPicture(name) {
                    BighelpImageGeneratingView(caption: "Loading your image", variant: .develop, size: .compact,
                                               aspectRatio: 4.0 / 3.0, phaseOffset: Double(index) * 0.4)
                        .frame(width: uiV3Enabled ? 208 : 176, height: uiV3Enabled ? 156 : 132)
                        .clipShape(.rect(cornerRadius: uiV3Enabled ? BighelpTokens.radius20 : BighelpTokens.radius12))
                } else {
                    fileTile(name)
                }
            }
        }
    }

    private func fileTile(_ name: String) -> some View {
        HStack(spacing: BighelpTokens.space8) {
            Image(systemName: Self.isVideo(name) ? "film.fill" : "doc.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.action)
                .frame(width: 36, height: 36)
                .background(theme.action.opacity(0.10), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .bighelpMessageFont(.label)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("Loading…")
                    .bighelpMessageFont(.metadata)
                    .bighelpShimmer(isActive: true)
            }
        }
        .padding(BighelpTokens.space12)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: .rect(cornerRadius: BighelpTokens.radius12))
        .overlay {
            RoundedRectangle(cornerRadius: BighelpTokens.radius12)
                .stroke(Color(uiColor: .separator), lineWidth: BighelpTokens.hairline)
        }
    }

    static func isPicture(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    static func isVideo(_ name: String) -> Bool {
        ["mp4", "m4v", "mov", "webm"].contains(URL(fileURLWithPath: name).pathExtension.lowercased())
    }

    @BighelpThemeReader private var theme: BighelpTheme
    @Environment(\.bighelpUIV3Enabled) private var uiV3Enabled
}
