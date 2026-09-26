import CoreGraphics
import Foundation
import Testing
@testable import Bighelp

struct CompanionPhysicsTests {
    let bounds = CGRect(x: 10, y: 20, width: 360, height: 500)

    @Test func flingUsesFingerVelocityAndStaysContainedUntilSettled() {
        var body = CompanionPhysics(position: CGPoint(x: 100, y: 100), size: CGSize(width: 80, height: 80))
        body.startDrag(at: CGPoint(x: 100, y: 100), time: 0, bounds: bounds)
        body.moveDrag(to: CGPoint(x: 180, y: 100), time: 0.08, bounds: bounds)
        body.endDrag(at: CGPoint(x: 200, y: 100), time: 0.1, bounds: bounds)
        #expect(body.velocity.dx > 500)
        for _ in 0..<1800 {
            body.step(dt: 1.0 / 60, bounds: bounds)
            let frame = CGRect(x: body.position.x - 40, y: body.position.y - 40, width: 80, height: 80)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(frame))
        }
        #expect(body.isSettled)
        #expect(body.velocity == .zero)
    }

    @Test func holdingStillBeforeReleaseDoesNotReplayOldFling() {
        var body = CompanionPhysics(position: CGPoint(x: 100, y: 100), size: CGSize(width: 80, height: 80))
        body.startDrag(at: CGPoint(x: 100, y: 100), time: 0, bounds: bounds)
        body.moveDrag(to: CGPoint(x: 180, y: 100), time: 0.08, bounds: bounds)
        body.endDrag(time: 2, bounds: bounds)
        #expect(body.velocity == .zero)
    }

    @Test func nonfiniteInputCannotEscapeTheCanvas() {
        var body = CompanionPhysics(position: CGPoint(x: CGFloat.nan, y: CGFloat.infinity),
                                    velocity: .init(dx: CGFloat.infinity, dy: CGFloat.nan),
                                    size: CGSize(width: 80, height: 80))
        body.step(dt: .infinity, bounds: bounds)
        #expect(body.position.x.isFinite)
        #expect(body.position.y.isFinite)
        #expect(bounds.contains(body.position))
    }
}
