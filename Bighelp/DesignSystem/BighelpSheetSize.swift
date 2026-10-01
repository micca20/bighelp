import SwiftUI

/// How big a sheet opens on the Mac. There sheets are panels sized to their
/// content, and detents (iPhone) don't apply, so a sheet that names no size
/// opens small. iPhone, iPad and Vision Pro ignore this.
enum BighelpSheetSize: Sendable {
    /// A short choice or confirmation.
    case compact
    /// A form, list or editor: most sheets.
    case standard
    /// A studio, board or anything with a big preview.
    case large

    /// Mac sheets open at their content's minimum size, so this is the size they open at.
    fileprivate var preferred: CGSize {
        switch self {
        case .compact: CGSize(width: 480, height: 420)
        case .standard: CGSize(width: 680, height: 740)
        case .large: CGSize(width: 920, height: 780)
        }
    }

    #if targetEnvironment(macCatalyst)
    /// The preferred size, kept clear of the screen's edges and menu bar.
    @MainActor fileprivate var opening: CGSize {
        let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds }.first
            ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        return CGSize(width: min(preferred.width, screen.width - 80), height: min(preferred.height, screen.height - 140))
    }
    #endif
}

extension View {
    /// The sheet's size on the Mac; put it on the sheet's content.
    func bighelpSheetSize(_ size: BighelpSheetSize = .standard) -> some View {
        #if targetEnvironment(macCatalyst)
        frame(minWidth: size.opening.width, maxWidth: .infinity, minHeight: size.opening.height, maxHeight: .infinity)
        #else
        self
        #endif
    }
}
