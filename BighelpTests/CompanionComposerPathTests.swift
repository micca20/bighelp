import CoreGraphics
import Testing
@testable import Bighelp

struct CompanionComposerPathTests {
    private var geometry: CompanionComposerPathGeometry {
        .init(canvasBounds: CGRect(x: 0, y: 0, width: 760, height: 220),
              inputFrame: CGRect(x: 20, y: 140, width: 720, height: 70),
              contextRingFrame: CGRect(x: 700, y: 90, width: 44, height: 44),
              railViewport: CGRect(x: 30, y: 80, width: 560, height: 44),
              railLedges: [CGRect(x: 60, y: 80, width: 100, height: 44), CGRect(x: 250, y: 80, width: 120, height: 44), CGRect(x: 900, y: 80, width: 120, height: 44)], itemSide: 72)
    }

    @Test func restIsLeftOfContextAndOffModeNeverTravels() {
        let frame = geometry
        let rest = CompanionComposerPathSampler.restPosition(in: frame)
        #expect(rest.x + frame.itemSide / 2 + CompanionComposerPathSampler.restGap == frame.contextRingFrame!.minX)
        #expect(rest.y + frame.itemSide / 2 == frame.contextRingFrame!.maxY)
        for time in [0.0, 2, 5, 9, 100] {
            let sample = CompanionComposerPathSampler.sample(elapsed: time, in: frame, isAdventurous: false)
            #expect(sample.position == rest)
            #expect(sample.phase == .rest)
        }
    }

    @Test func adventureUsesActualVisibleRailTopsAndAllMotionPhases() {
        let frame = geometry
        let path = CompanionComposerPathSampler.authoredWaypoints(in: frame)
        #expect(Set(path.map(\.phase)) == Set(CompanionComposerMotionPhase.allCases))
        let climbs = path.filter { $0.phase == .climb }
        #expect(climbs.first?.position == CGPoint(x: 110, y: 44))
        #expect(!path.contains { $0.position.x > frame.canvasBounds.maxX })
        var xs: [CGFloat] = []
        for tick in 0..<240 {
            let sample = CompanionComposerPathSampler.sample(elapsed: Double(tick) / 20, in: frame)
            #expect(sample.position.x.isFinite && sample.position.y.isFinite)
            #expect(sample.position.x >= frame.itemSide / 2)
            #expect(sample.position.x <= frame.canvasBounds.maxX - frame.itemSide / 2)
            xs.append(sample.position.x)
        }
        #expect((xs.max() ?? 0) - (xs.min() ?? 0) > 600)
    }

    @Test func removedRailsAndChangedWidthUseOnlyCurrentGeometry() {
        var changed = geometry
        changed.railLedges = []
        changed.contextRingFrame = nil
        changed.canvasBounds.size.width = 390
        changed.inputFrame = CGRect(x: 12, y: 140, width: 366, height: 60)
        let path = CompanionComposerPathSampler.authoredWaypoints(in: changed)
        #expect(!path.contains { $0.phase == .climb })
        #expect(path.allSatisfy { $0.position.x <= 390 - 36 })
        #expect(CompanionComposerPathGeometry.surfaceItemSide(sizeScale: .nan, canvasWidth: 390).isFinite)
    }
}
