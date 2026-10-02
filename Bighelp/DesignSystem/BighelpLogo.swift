import SwiftUI
import UIKit

struct BighelpLogo: View {
    enum Presentation {
        case full
        case mark
    }

    let presentation: Presentation
    let height: CGFloat

    init(presentation: Presentation = .full, height: CGFloat = 32) {
        self.presentation = presentation
        self.height = height
    }

    var body: some View {
        Group {
            switch presentation {
            case .full:
                EmberLockup(markSize: height)
            case .mark:
                EmberMark(size: height)
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EmberBrand.appName)
        .accessibilityIdentifier("loopdy.brand-logo")
    }
}

private enum BrandMeasurements {
    static let markToWordmarkHeight: CGFloat = 176.0 / 186.0
    static let gapToHeight: CGFloat = 63.0 / 186.0
}
