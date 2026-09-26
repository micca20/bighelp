import CoreGraphics
import Foundation

struct CompanionSurfaceInsets: Equatable, Sendable {
    var top: CGFloat = 0
    var leading: CGFloat = 0
    var bottom: CGFloat = 0
    var trailing: CGFloat = 0

    func bounds(in canvas: CGSize) -> CGRect {
        let width = max(0, canvas.width.isFinite ? canvas.width : 0)
        let height = max(0, canvas.height.isFinite ? canvas.height : 0)
        let x = min(max(0, leading), width)
        let y = min(max(0, top), height)
        return CGRect(x: x, y: y,
                      width: max(0, width - x - max(0, trailing)),
                      height: max(0, height - y - max(0, bottom)))
    }
}
