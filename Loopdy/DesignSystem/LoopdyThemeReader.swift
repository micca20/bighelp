import SwiftUI

/// Resolves at each consumer so sheets, previews, and hosted rows keep their
/// local appearance and accessibility traits. LoopdyTheme remains the authority.
@propertyWrapper
struct LoopdyThemeReader: DynamicProperty {
    @Environment(\.appAppearance) private var appearance
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var wrappedValue: LoopdyTheme {
        LoopdyTheme.resolve(
            appearance: appearance,
            colorScheme: colorScheme,
            contrast: contrast
        )
    }
}
