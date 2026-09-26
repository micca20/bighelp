import SwiftUI
import Testing
@testable import Loopdy

@MainActor
struct ChatCanvasGeometryTests {
    @Test func shortChatSpaceDoesNotRequireOverscrollRepair() {
        guard #available(iOS 18.0, *) else { return }
        let geometry = ScrollGeometry(
            contentOffset: .zero,
            contentSize: CGSize(width: 402, height: 100),
            contentInsets: EdgeInsets(),
            containerSize: CGSize(width: 402, height: 874)
        )
        let measurement = ChatTimelineScrollMeasurement(geometry)
        #expect(measurement.signedDistanceFromBottom < 0)
        #expect(!measurement.isOverscrolledPastBottom)
    }

    @Test func longChatTailInsideViewportStillRequiresOverscrollRepair() {
        guard #available(iOS 18.0, *) else { return }
        let geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 2422 + 200),
            contentSize: CGSize(width: 402, height: 3126),
            contentInsets: EdgeInsets(top: 130, leading: 0, bottom: 170, trailing: 0),
            containerSize: CGSize(width: 402, height: 874)
        )
        let measurement = ChatTimelineScrollMeasurement(geometry)
        #expect(measurement.isOverscrolledPastBottom)
        #expect(ChatBottomAnchorVisibility.isVisible(
            signedDistanceFromBottom: measurement.signedDistanceFromBottom,
            viewportHeight: measurement.viewportHeight
        ))
        #expect(!ChatTimelineBottomPinning.requiresCorrection(
            signedDistanceFromBottom: measurement.signedDistanceFromBottom,
            shouldFollowNewContent: true,
            isUserInitiated: true
        ))
    }

    @Test(arguments: [0.0, 0.6666666667, 1.0, 30.0])
    func distinguishesRoundingFromAnObscuredTail(distance: Double) {
        guard #available(iOS 18.0, *) else { return }
        let geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 2422 - distance),
            contentSize: CGSize(width: 402, height: 3126),
            contentInsets: EdgeInsets(top: 130, leading: 0, bottom: 170, trailing: 0),
            containerSize: CGSize(width: 402, height: 874)
        )
        let measurement = ChatTimelineScrollMeasurement(geometry)
        let expected: CGFloat = distance <= 1 ? 0 : CGFloat(distance)
        #expect(abs(measurement.signedDistanceFromBottom - expected) < 0.001)
        #expect(ChatBottomAnchorVisibility.isVisible(
            signedDistanceFromBottom: measurement.signedDistanceFromBottom,
            viewportHeight: measurement.viewportHeight
        ) == (distance <= 1))
    }

    @Test func floatingChromeIsNotVisibleTranscriptSpace() {
        guard #available(iOS 18.0, *) else { return }
        let geometry = ScrollGeometry(
            contentOffset: CGPoint(x: 0, y: 2422),
            contentSize: CGSize(width: 402, height: 3126),
            contentInsets: EdgeInsets(top: 130, leading: 0, bottom: 170, trailing: 0),
            containerSize: CGSize(width: 402, height: 874)
        )
        let measurement = ChatTimelineScrollMeasurement(geometry)
        #expect(measurement.signedDistanceFromBottom == 0)
        #expect(measurement.viewportHeight == 574)
    }

    @Test func floatingChromeBackdropCoversOnlyHeaderAndComposer() {
        let regions = ChatFloatingChromeBackdropLayout.regions(
            in: CGSize(width: 1_024, height: 768),
            headerHeight: 84,
            composerHeight: 132
        )

        #expect(regions == [
            CGRect(x: 0, y: 0, width: 1_024, height: 84),
            CGRect(x: 0, y: 636, width: 1_024, height: 132),
        ])
        #expect(!regions.contains { $0.contains(CGPoint(x: 512, y: 384)) })
    }
}
