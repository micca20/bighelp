import SwiftUI

/// Resolves at each consumer so sheets, previews, and hosted rows keep their
/// local appearance and accessibility traits. BighelpTheme remains the authority.
@propertyWrapper
struct BighelpThemeReader: DynamicProperty {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var wrappedValue: BighelpTheme {
        BighelpTheme.resolve(
            appearance: appearance,
            colorScheme: colorScheme,
            contrast: contrast
        )
    }
}
