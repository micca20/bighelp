import SwiftUI

@MainActor
final class ChatTimelineTaskOwnership {
    struct Token: Equatable, Sendable {
        fileprivate let generation: UInt64
        fileprivate let conversationID: String
    }

    private var generation: UInt64 = 0

    func claim(conversationID: String) -> Token {
        generation &+= 1
        return Token(generation: generation, conversationID: conversationID)
    }

    func invalidate() {
        generation &+= 1
    }

    func owns(_ token: Token, conversationID: String) -> Bool {
        token.generation == generation && token.conversationID == conversationID
    }

    func remainsOwned(
        _ token: Token,
        conversationID: String,
        after delay: Duration
    ) async -> Bool {
        do {
            try await Task.sleep(for: delay)
        } catch {
            return false
        }
        return !Task.isCancelled && owns(token, conversationID: conversationID)
    }
}

@available(iOS 18.0, *)
struct ChatTimelineScrollMeasurement: Equatable {
    let signedDistanceFromBottom: CGFloat
    let viewportHeight: CGFloat
    let isOverscrolledPastBottom: Bool

    init(_ geometry: ScrollGeometry) {
        // Safe-area chrome is included in visibleRect, but obscures the transcript.
        let distance = geometry.contentSize.height
            - (geometry.visibleRect.maxY - geometry.contentInsets.bottom)
        // Lazy content extents round up while scrollTo rounds its target frame.
        // Treat the one-point rounding boundary as settled, not a new scroll.
        signedDistanceFromBottom = abs(distance) <= 1 ? 0 : distance
        viewportHeight = max(0, geometry.visibleRect.height
            - geometry.contentInsets.top - geometry.contentInsets.bottom)
        // Short chats legitimately leave space below their first rows. Only
        // repair an out-of-range tail after content fills the usable viewport.
        isOverscrolledPastBottom = distance < -1 && viewportHeight > 0
            && geometry.contentSize.height >= viewportHeight
    }
}

struct ChatTimelineUserIntent: Equatable, Sendable {
    private(set) var isDragging = false
    private var hasCompletedDragAwaitingGeometry = false

    var isGeometryUserInitiated: Bool {
        isDragging || hasCompletedDragAwaitingGeometry
    }

    mutating func beginDrag() {
        isDragging = true
        hasCompletedDragAwaitingGeometry = false
    }

    mutating func endDrag() {
        isDragging = false
        hasCompletedDragAwaitingGeometry = true
    }

    @discardableResult
    mutating func consumeCompletedDrag() -> Bool {
        guard !isDragging, hasCompletedDragAwaitingGeometry else { return false }
        hasCompletedDragAwaitingGeometry = false
        return true
    }

    mutating func reset() {
        isDragging = false
        hasCompletedDragAwaitingGeometry = false
    }
}

struct ChatReturnToLatestState: Equatable, Sendable {
    private(set) var isVisible = false
    /// Return intent does not establish that the bottom anchor was reached.
    private(set) var isReturning = false
    /// The most recent anchor observation, recorded even while a return is in
    /// flight so an abandoned or incomplete return can restore honest state
    /// instead of leaving the control hidden over an off-screen tail.
    private(set) var lastKnownBottomAnchorVisible = true

    mutating func beginReturn() {
        isReturning = true
        isVisible = !lastKnownBottomAnchorVisible
    }

    /// Finishing the bounded attempts is not evidence of successful scrolling.
    mutating func completeReturn() {
        guard isReturning else { return }
        isReturning = false
        isVisible = !lastKnownBottomAnchorVisible
    }

    /// Abandons a return because the reader took the timeline back. The control
    /// is restored from the last honest observation instead of being trusted.
    mutating func cancelReturn() {
        guard isReturning else { return }
        isReturning = false
        isVisible = !lastKnownBottomAnchorVisible
    }

    mutating func update(isBottomAnchorVisible: Bool) {
        lastKnownBottomAnchorVisible = isBottomAnchorVisible
        if isBottomAnchorVisible {
            isReturning = false
        }
        isVisible = !isBottomAnchorVisible
    }

    mutating func reset() {
        isVisible = false
        isReturning = false
        lastKnownBottomAnchorVisible = true
    }
}

enum ChatCanvasLayout {
    static let composerInsetSpacing = LoopdyTokens.space4
}

/// Geometry compatibility for the timeline inset contract. UI V3 no longer
/// renders surfaces for these regions; only bounded controls own glass.
enum ChatFloatingChromeBackdropLayout {
    static func regions(
        in size: CGSize,
        headerHeight: CGFloat,
        composerHeight: CGFloat
    ) -> [CGRect] {
        guard size.width > 0, size.height > 0 else { return [] }
        let header = min(max(headerHeight, 0), size.height)
        let composer = min(max(composerHeight, 0), size.height - header)
        var regions: [CGRect] = []
        if header > 0 {
            regions.append(CGRect(x: 0, y: 0, width: size.width, height: header))
        }
        if composer > 0 {
            regions.append(CGRect(
                x: 0,
                y: size.height - composer,
                width: size.width,
                height: composer
            ))
        }
        return regions
    }
}

enum ChatTimelineScrollReason: Equatable, Sendable {
    case initialPosition
    case automaticContentMutation
    case returnToLatest
}

enum ChatTimelineScrollAnimationPolicy {
    static func shouldAnimate(
        reason: ChatTimelineScrollReason,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion else { return false }
        return reason == .returnToLatest
    }
}

enum ChatTimelineBottomPinning {
    /// Ignore sub-point geometry churn from scroll-view rounding, but repair
    /// every meaningful idle layout change while the reader still owns the
    /// live tail.
    static let correctionThreshold: CGFloat = 0.5

    static func requiresCorrection(
        signedDistanceFromBottom: CGFloat,
        shouldFollowNewContent: Bool,
        isUserInitiated: Bool
    ) -> Bool {
        guard shouldFollowNewContent,
              !isUserInitiated,
              signedDistanceFromBottom.isFinite else { return false }
        return abs(signedDistanceFromBottom) > correctionThreshold
    }
}

enum ChatBottomAnchorVisibility {
    static let anchorHeight: CGFloat = 1
    // Breathing room between the latest message and the composer, which the
    // timeline already clears by its measured height.
    static let contentBottomPadding: CGFloat = 20
    static let intersectionThreshold: CGFloat = 0.5

    /// Project the final one-point anchor into the finite viewport. The same
    /// intersection rule applies whether the tail is below or above it.
    static func isVisible(
        signedDistanceFromBottom: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        guard signedDistanceFromBottom.isFinite else { return false }
        return isVisible(
            anchorBottomY: viewportHeight + signedDistanceFromBottom,
            viewportHeight: viewportHeight
        )
    }

    static func isVisible(anchorBottomY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard anchorBottomY.isFinite,
              viewportHeight.isFinite,
              viewportHeight > 0 else { return false }
        let requiredIntersection = anchorHeight * intersectionThreshold
        let intersection = min(anchorBottomY, viewportHeight)
            - max(anchorBottomY - anchorHeight, 0)
        return intersection >= requiredIntersection
    }
}
